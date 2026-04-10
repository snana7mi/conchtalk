/// 文件说明：MMDBReader，纯 Swift 实现的 MaxMind DB (MMDB) 离线读取器，用于本地 IP 地理位置查询。
import Foundation

/// MMDBReader：
/// 解析 GeoLite2-Country.mmdb 等 MaxMind DB 格式文件，仅提取国家代码（ISO 3166-1 alpha-2）。
/// 纯本地查询，不发送任何网络请求。
nonisolated final class MMDBReader: Sendable {
    private let bytes: [UInt8]
    private let nodeCount: Int
    private let recordSize: Int
    private let ipVersion: Int
    private let searchTreeSize: Int
    private let dataSectionStart: Int

    /// 从 Bundle 资源初始化 MMDB 读取器。
    /// - Parameter url: .mmdb 文件路径。
    init?(url: URL) {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let bytes = [UInt8](data)
        self.bytes = bytes

        // 查找元数据标记：0xABCDEF + "MaxMind.com"
        let marker: [UInt8] = [0xAB, 0xCD, 0xEF] + Array("MaxMind.com".utf8)
        var metaStart = -1
        outer: for i in stride(from: bytes.count - marker.count, through: 0, by: -1) {
            for j in 0..<marker.count {
                if bytes[i + j] != marker[j] { continue outer }
            }
            metaStart = i + marker.count
            break
        }
        guard metaStart >= 0 else { return nil }

        // 解码元数据
        guard let (metaVal, _) = MMDBReader.decodeValue(bytes, at: metaStart, base: metaStart),
              case .map(let meta) = metaVal,
              case .uint(let nc) = meta["node_count"],
              case .uint(let rs) = meta["record_size"],
              case .uint(let iv) = meta["ip_version"] else { return nil }

        self.nodeCount = Int(nc)
        self.recordSize = Int(rs)
        self.ipVersion = Int(iv)
        self.searchTreeSize = nodeCount * (recordSize * 2 / 8)
        self.dataSectionStart = searchTreeSize + 16
    }

    // MARK: - Public API

    /// 查询 IPv4 地址对应的国家代码。
    /// - Parameter ip: IPv4 地址字符串（如 "1.2.3.4"）。
    /// - Returns: 两位国家代码（如 "US"），查询失败返回 nil。
    func countryCode(for ip: String) -> String? {
        let parts = ip.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return nil }

        var node = 0

        // IPv6 数据库中查 IPv4：规范要求先走 ::/96，即 96 个 0 bit，
        // 然后再继续遍历 IPv4 的 32 bit。
        // 参考 MaxMind DB 官方规范 “IPv4 addresses in an IPv6 tree”。
        if ipVersion == 6 {
            for _ in 0..<96 {
                guard node < nodeCount else { return nil }
                node = readRecord(node, right: false)
            }
        }

        // 逐 bit 遍历 IPv4 地址
        for byte in parts {
            for bit in stride(from: 7, through: 0, by: -1) {
                guard node < nodeCount else { break }
                let isRight = (byte >> bit) & 1 == 1
                node = readRecord(node, right: isRight)
            }
        }

        guard node > nodeCount else { return nil }

        // 解析数据段：绝对偏移 = searchTreeSize + (node - nodeCount)
        let dataOffset = searchTreeSize + (node - nodeCount)
        guard let (val, _) = MMDBReader.decodeValue(bytes, at: dataOffset, base: dataSectionStart),
              case .map(let root) = val else { return nil }

        // 兼容不同 MMDB 数据结构：
        // - db-ip: {"country_code": "US"}
        // - GeoLite2: {"country": {"iso_code": "US"}}
        if case .string(let code) = root["country_code"] {
            return code
        }
        if case .map(let country) = root["country"],
           case .string(let iso) = country["iso_code"] {
            return iso
        }
        return nil
    }

    // MARK: - Search Tree

    private func readRecord(_ nodeNumber: Int, right: Bool) -> Int {
        let nodeByteSize = recordSize * 2 / 8
        let base = nodeNumber * nodeByteSize

        switch recordSize {
        case 24:
            let offset = right ? base + 3 : base
            return int24(at: offset)
        case 28:
            let mid = Int(bytes[base + 3])
            if right {
                return (mid & 0x0F) << 24 | int24(at: base + 4)
            } else {
                return ((mid & 0xF0) >> 4) << 24 | int24(at: base)
            }
        case 32:
            let offset = right ? base + 4 : base
            return int32(at: offset)
        default:
            return 0
        }
    }

    private func int24(at i: Int) -> Int {
        Int(bytes[i]) << 16 | Int(bytes[i + 1]) << 8 | Int(bytes[i + 2])
    }

    private func int32(at i: Int) -> Int {
        Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16 | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
    }

    // MARK: - Data Decoder

    enum Value {
        case string(String)
        case uint(UInt64)
        case map([String: Value])
        case array([Value])
        case bool(Bool)
        case data(Data)
        case double(Double)
    }

    /// 解码 MMDB 数据段中的值。
    /// - Parameters:
    ///   - bytes: 完整文件字节。
    ///   - offset: 当前读取偏移。
    ///   - base: 数据段起始偏移（用于指针解析）。
    /// - Returns: 解码结果及下一个字节偏移。
    private static func decodeValue(_ bytes: [UInt8], at offset: Int, base: Int) -> (Value, Int)? {
        guard offset < bytes.count else { return nil }
        var pos = offset
        let ctrl = bytes[pos]
        var typeNum = Int(ctrl >> 5)
        var size = Int(ctrl & 0x1F)
        pos += 1

        // 指针类型
        if typeNum == 1 {
            return decodePointer(bytes, ctrl: ctrl, at: pos, base: base)
        }

        // 扩展类型
        if typeNum == 0 {
            guard pos < bytes.count else { return nil }
            typeNum = Int(bytes[pos]) + 7
            pos += 1
        }

        // 解码大小
        if typeNum != 1 {
            if size == 29 {
                size = 29 + Int(bytes[pos]); pos += 1
            } else if size == 30 {
                size = 285 + (Int(bytes[pos]) << 8 | Int(bytes[pos + 1])); pos += 2
            } else if size == 31 {
                size = 65821 + (Int(bytes[pos]) << 16 | Int(bytes[pos + 1]) << 8 | Int(bytes[pos + 2])); pos += 3
            }
        }

        switch typeNum {
        case 2: // UTF-8 string
            let end = pos + size
            let str = String(bytes: bytes[pos..<end], encoding: .utf8) ?? ""
            return (.string(str), end)

        case 3: // double
            return (.double(0), pos + 8)

        case 4: // bytes
            return (.data(Data(bytes[pos..<pos + size])), pos + size)

        case 5, 6: // uint16, uint32
            var val: UInt64 = 0
            for i in 0..<size { val = val << 8 | UInt64(bytes[pos + i]) }
            return (.uint(val), pos + size)

        case 7: // map
            var map: [String: Value] = [:]
            var cur = pos
            for _ in 0..<size {
                guard let (k, next1) = decodeValue(bytes, at: cur, base: base),
                      case .string(let key) = k,
                      let (v, next2) = decodeValue(bytes, at: next1, base: base) else { break }
                map[key] = v
                cur = next2
            }
            return (.map(map), cur)

        case 8: // int32 (extended 1)
            var val: UInt64 = 0
            for i in 0..<size { val = val << 8 | UInt64(bytes[pos + i]) }
            return (.uint(val), pos + size)

        case 9: // uint64 (extended 2)
            var val: UInt64 = 0
            for i in 0..<size { val = val << 8 | UInt64(bytes[pos + i]) }
            return (.uint(val), pos + size)

        case 11: // array (extended 4)
            var arr: [Value] = []
            var cur = pos
            for _ in 0..<size {
                guard let (v, next) = decodeValue(bytes, at: cur, base: base) else { break }
                arr.append(v)
                cur = next
            }
            return (.array(arr), cur)

        case 14: // boolean (extended 7)
            return (.bool(size != 0), pos)

        default:
            return (.string(""), pos + size)
        }
    }

    private static func decodePointer(_ bytes: [UInt8], ctrl: UInt8, at pos: Int, base: Int) -> (Value, Int)? {
        let sizeField = Int(ctrl & 0x1F)
        let ptrSize = (sizeField >> 3) & 0x03
        var nextPos = pos
        let pointer: Int

        switch ptrSize {
        case 0:
            pointer = ((sizeField & 0x07) << 8) | Int(bytes[nextPos])
            nextPos += 1
        case 1:
            pointer = (((sizeField & 0x07) << 16) | (Int(bytes[nextPos]) << 8) | Int(bytes[nextPos + 1])) + 2048
            nextPos += 2
        case 2:
            pointer = (((sizeField & 0x07) << 24) | (Int(bytes[nextPos]) << 16) | (Int(bytes[nextPos + 1]) << 8) | Int(bytes[nextPos + 2])) + 526336
            nextPos += 3
        case 3:
            pointer = (Int(bytes[nextPos]) << 24) | (Int(bytes[nextPos + 1]) << 16) | (Int(bytes[nextPos + 2]) << 8) | Int(bytes[nextPos + 3])
            nextPos += 4
        default:
            return nil
        }

        // 指针指向数据段内的偏移
        guard let (value, _) = decodeValue(bytes, at: base + pointer, base: base) else { return nil }
        // 返回解析后的值，但 nextOffset 是指针本身之后的位置（不是目标位置）
        return (value, nextPos)
    }
}
