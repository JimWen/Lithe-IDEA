import Foundation
import LitheSearchModule

/// Search Everywhere 的 All 页把文件、类、符号混在一张列表里，需要一个共同的
/// 相关度标准来排序，否则只能按 kind 分段展示（IDEA 是混排的）。
///
/// 打分在 Swift 侧完成而不是 Rust 侧：`FileSearchResult` 已经带了 `symbolName`
/// 和 URL，算分不需要额外信息，也就不必改动 FFI 契约。
enum SearchRelevance {
    /// 匹配形态，分值差距拉大以保证形态优先于其他维度。
    private enum MatchForm: Int {
        case none = 0
        case substring = 100
        case initials = 200
        case prefix = 300
        case exact = 400
    }

    static func score(_ result: FileSearchResult, query: String, workspaceRoot: URL? = nil) -> Int {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return 0 }

        // 名字命中比路径命中更能说明用户意图，所以分别算分再取较优的一侧。
        let name = result.symbolName ?? result.url.lastPathComponent
        let nameScore = form(matching: name, query: needle).rawValue
        let pathScore = form(matching: result.url.path, query: needle).rawValue / 4

        guard nameScore > 0 || pathScore > 0 else { return 0 }

        return max(nameScore, pathScore) + kindBonus(result.kind) - depthPenalty(result.url, workspaceRoot: workspaceRoot)
    }

    private static func form(matching text: String, query: String) -> MatchForm {
        guard !text.isEmpty else { return .none }

        // 文件名带扩展名，比较时一并考虑去扩展名的形式，让 `DeviceHandler`
        // 精确命中 `DeviceHandler.java` 而不是降级成前缀匹配。
        let candidates = [text, (text as NSString).deletingPathExtension]

        for candidate in candidates {
            if candidate.compare(query, options: .caseInsensitive) == .orderedSame {
                return .exact
            }
        }
        for candidate in candidates where candidate.range(
            of: query,
            options: [.caseInsensitive, .anchored]
        ) != nil {
            return .prefix
        }
        if matchesInitials(of: text, query: query) {
            return .initials
        }
        if text.range(of: query, options: .caseInsensitive) != nil {
            return .substring
        }
        return .none
    }

    /// 驼峰缩写：`DH` / `dh` 命中 `DeviceHandler`，`UL` 命中 `URLLoader`。单遍线性扫描避免 O(L²) 索引。
    private static func matchesInitials(of text: String, query: String) -> Bool {
        let target = Array(query.lowercased())
        guard target.count >= 2 else { return false }
        var matched = 0
        var previous: Character?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let nextIndex = text.index(after: index)
            let next: Character? = nextIndex < text.endIndex ? text[nextIndex] : nil
            defer {
                previous = character
                index = nextIndex
            }
            guard character.isUppercase || character.isNumber else { continue }
            // 连续大写（如 `URLLoader`）仅在首字母或后接小写字母时作为新单词起点。
            if let previous, previous.isUppercase, !(next?.isLowercase ?? false) {
                continue
            }
            let lowered = character.lowercased()
            guard lowered.count == 1, lowered.first == target[matched] else { return false }
            matched += 1
            if matched == target.count { return true }
        }
        return false
    }

    /// 同形态下让"定义"优先于"引用"：类比裸符号更可能是用户要找的目标，
    /// 正文命中垫底（它在 Text 标签页才是主角）。
    private static func kindBonus(_ kind: SearchResultKind) -> Int {
        switch kind {
        case .type: return 12
        case .file: return 8
        case .symbol: return 4
        case .content: return 0
        }
    }

    /// 浅层文件通常更相关。相对于工作区根计算深度，避免绝对路径前缀把深度惩罚顶满。
    private static func depthPenalty(_ url: URL, workspaceRoot: URL?) -> Int {
        if let workspaceRoot {
            let rootPath = workspaceRoot.standardizedFileURL.path
            let filePath = url.standardizedFileURL.path
            let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            if filePath.hasPrefix(prefix) {
                let relative = filePath.dropFirst(prefix.count)
                return min(relative.split(separator: "/").count, 20)
            }
        }
        return min(url.pathComponents.count, 20)
    }
}
