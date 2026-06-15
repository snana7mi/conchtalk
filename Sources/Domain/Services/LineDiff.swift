/// 文件说明：LineDiff，纯函数行级 LCS Diff，产出 DiffLine 序列供审批卡片渲染。
import Foundation

/// DiffLine：一行 Diff 结果（上下文/新增/删除）。
nonisolated enum DiffLine: Sendable, Equatable {
    case context(String)
    case added(String)
    case removed(String)
}

/// LineDiff：经典 LCS 动态规划行级 Diff，纯、有界、无副作用。
nonisolated enum LineDiff {
    /// 比较 old / new 两组行，返回交错的 DiffLine 序列（删除在前、新增在后）。
    static func diff(old: [String], new: [String]) -> [DiffLine] {
        let n = old.count, m = new.count
        // LCS 长度表：(n+1) x (m+1)
        var lcs = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    if old[i] == new[j] {
                        lcs[i][j] = lcs[i + 1][j + 1] + 1
                    } else {
                        lcs[i][j] = max(lcs[i + 1][j], lcs[i][j + 1])
                    }
                }
            }
        }
        var result: [DiffLine] = []
        var i = 0, j = 0
        while i < n && j < m {
            if old[i] == new[j] {
                result.append(.context(old[i])); i += 1; j += 1
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                result.append(.removed(old[i])); i += 1
            } else {
                result.append(.added(new[j])); j += 1
            }
        }
        while i < n { result.append(.removed(old[i])); i += 1 }
        while j < m { result.append(.added(new[j])); j += 1 }
        return result
    }
}
