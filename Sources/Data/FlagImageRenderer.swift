/// 文件说明：FlagImageRenderer，将国旗 emoji 或服务器名首字母渲染为图片 Data。
import Foundation
import UIKit

/// FlagImageRenderer：
/// 提供静态方法，将国旗 emoji / 服务器名首字母渲染为指定尺寸的图片数据（PNG），
/// 用于通知头像、服务器列表图标等需要真实图片的场景。
enum FlagImageRenderer {

    /// 渲染结果缓存，key = "serverID-size"，避免每次访问都重新渲染。
    private static let cache: NSCache<NSString, NSData> = {
        let c = NSCache<NSString, NSData>()
        c.countLimit = 50
        return c
    }()

    /// 将国旗 emoji 渲染为 PNG Data。
    static func renderFlagEmoji(_ emoji: String, size: CGFloat) -> Data? {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        let image = renderer.image { ctx in
            let rect = CGRect(origin: .zero, size: CGSize(width: size, height: size))
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .center
            let fontSize = size * 0.7
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize),
                .paragraphStyle: paragraphStyle,
            ]
            let textSize = (emoji as NSString).size(withAttributes: attrs)
            let textRect = CGRect(
                x: (rect.width - textSize.width) / 2,
                y: (rect.height - textSize.height) / 2,
                width: textSize.width,
                height: textSize.height
            )
            (emoji as NSString).draw(in: textRect, withAttributes: attrs)
        }
        return image.pngData()
    }

    /// 从 countryCode 渲染国旗图片。
    static func renderFlag(countryCode: String, size: CGFloat) -> Data? {
        let emoji = flagEmoji(from: countryCode)
        guard emoji != "❓" else { return nil }
        return renderFlagEmoji(emoji, size: size)
    }

    /// 当无国旗可用时，用服务器名首字母 + 彩色背景生成默认图标。
    static func defaultServerIcon(name: String, size: CGFloat) -> Data? {
        let initial = name.first.map { String($0).uppercased() } ?? "?"
        let hue = CGFloat(stableHash(name) % 360) / 360.0
        let bgColor = UIColor(hue: hue, saturation: 0.5, brightness: 0.85, alpha: 1.0)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        let image = renderer.image { ctx in
            let rect = CGRect(origin: .zero, size: CGSize(width: size, height: size))
            bgColor.setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: size * 0.2).fill()
            let fontSize = size * 0.45
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: fontSize),
                .foregroundColor: UIColor.white,
            ]
            let textSize = (initial as NSString).size(withAttributes: attrs)
            let textRect = CGRect(
                x: (rect.width - textSize.width) / 2,
                y: (rect.height - textSize.height) / 2,
                width: textSize.width,
                height: textSize.height
            )
            (initial as NSString).draw(in: textRect, withAttributes: attrs)
        }
        return image.pngData()
    }

    /// 获取服务器的图标数据：自定义 > 国旗 > 首字母默认图标。
    /// 非自定义图标会缓存渲染结果，避免每次访问重新渲染。
    static func resolveServerIconData(server: Server, size: CGFloat = 80) -> Data? {
        if let iconData = server.iconData {
            return iconData
        }
        let cacheKey = cacheKey(for: server, size: size)
        if let cached = cache.object(forKey: cacheKey) {
            return cached as Data
        }
        let rendered: Data?
        if let code = server.countryCode, !code.isEmpty {
            rendered = renderFlag(countryCode: code, size: size)
        } else {
            rendered = defaultServerIcon(name: server.name, size: size)
        }
        if let rendered {
            cache.setObject(rendered as NSData, forKey: cacheKey)
        }
        return rendered
    }

    // MARK: - Private

    /// 确定性哈希（djb2），跨进程/重启稳定，保证同名服务器颜色不变。
    private static func stableHash(_ string: String) -> UInt {
        var hash: UInt = 5381
        for byte in string.utf8 {
            hash = ((hash &<< 5) &+ hash) &+ UInt(byte)
        }
        return hash
    }

    private static func cacheKey(for server: Server, size: CGFloat) -> NSString {
        let variant: String
        if let code = server.countryCode?.uppercased(), !code.isEmpty {
            variant = "flag:\(code)"
        } else {
            variant = "default:\(server.name)"
        }
        return "\(server.id.uuidString)-\(variant)-\(Int(size))" as NSString
    }

    private static func flagEmoji(from countryCode: String) -> String {
        guard countryCode.count == 2 else { return "❓" }
        let base: UInt32 = 127397
        let scalars = countryCode.uppercased().unicodeScalars.compactMap { UnicodeScalar(base + $0.value) }
        guard scalars.count == 2 else { return "❓" }
        return String(scalars.map { Character($0) })
    }
}
