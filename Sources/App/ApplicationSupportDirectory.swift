/// 文件说明：ApplicationSupportDirectory，安全地准备 Application Support 目录。
import Foundation

/// ApplicationSupportDirectory：
/// 取搜索路径的第一项并创建目录。列表为空时直接返回，不强制解包。
enum ApplicationSupportDirectory {
    /// 确保目录存在。
    /// - Parameters:
    ///   - urls: 候选目录；nil 时向系统查询 Application Support。
    ///   - fileManager: 用于创建目录的文件管理器。
    static func ensureExists(
        urls: [URL]? = nil,
        fileManager: FileManager = .default
    ) {
        let resolved = urls ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        guard let directory = resolved.first else { return }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
