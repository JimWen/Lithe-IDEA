import Foundation
import LitheCoreContracts

struct UnavailableBuiltinLanguageFeatureCore: BuiltinLanguageFeatureCore {
    var isBuiltinLanguageFeatureAvailable: Bool { false }

    func builtinLanguageCompletions(
        fileURL _: URL,
        text _: String,
        position _: LanguageServerPosition
    ) -> [LanguageServerCompletionItem]? { nil }

    func builtinLanguageHover(
        fileURL _: URL,
        text _: String,
        position _: LanguageServerPosition
    ) -> LanguageServerHover? { nil }

    func builtinLanguageNavigation(
        method _: String,
        fileURL _: URL,
        text _: String,
        position _: LanguageServerPosition
    ) -> [LanguageServerLocation]? { nil }
}

package enum LanguageFeature: Hashable, Sendable {
    case completion
    case hover
    case signatureHelp
    case navigation(method: String)
}

package struct LanguageFeatureProviderPriority: RawRepresentable, Comparable, Hashable, Sendable {
    package let rawValue: Int

    package init(rawValue: Int) {
        self.rawValue = rawValue
    }

    package static let builtin = Self(rawValue: 0)
    package static let projectSymbols = Self(rawValue: 100)
    package static let languageServer = Self(rawValue: 200)

    package static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

package struct LanguageFeatureRequestContext: Sendable {
    package let fileURL: URL
    package let text: String
    package let position: LanguageServerPosition
    package let languageID: String?
    package let workspaceURL: URL?
    package let openBuffers: [String: String]

    package init(
        fileURL: URL,
        text: String,
        position: LanguageServerPosition,
        languageID: String? = nil,
        workspaceURL: URL? = nil,
        openBuffers: [String: String] = [:]
    ) {
        self.fileURL = fileURL.standardizedFileURL
        self.text = text
        self.position = position
        self.languageID = languageID
        self.workspaceURL = workspaceURL?.standardizedFileURL
        self.openBuffers = openBuffers
    }
}

@MainActor
package protocol LanguageFeatureProvider: AnyObject {
    var id: String { get }
    var priority: LanguageFeatureProviderPriority { get }

    func supports(_ feature: LanguageFeature, in context: LanguageFeatureRequestContext) -> Bool
    func completions(
        in context: LanguageFeatureRequestContext,
        completion: @escaping (Result<[LanguageServerCompletionItem], Error>) -> Void
    ) throws
    func hover(
        in context: LanguageFeatureRequestContext,
        completion: @escaping (Result<LanguageServerHover?, Error>) -> Void
    ) throws
    func signatureHelp(
        in context: LanguageFeatureRequestContext,
        completion: @escaping (Result<LanguageServerSignatureHelp?, Error>) -> Void
    ) throws
    func navigate(
        method: String,
        in context: LanguageFeatureRequestContext,
        completion: @escaping (Result<[LanguageServerLocation], Error>) -> Void
    ) throws
}

package extension LanguageFeatureProvider {
    func signatureHelp(
        in _: LanguageFeatureRequestContext,
        completion: @escaping (Result<LanguageServerSignatureHelp?, Error>) -> Void
    ) throws {
        completion(.success(nil))
    }
}

@MainActor
package final class BuiltinLanguageFeatureProvider: LanguageFeatureProvider {
    package let id = "builtin"
    package let priority: LanguageFeatureProviderPriority = .builtin

    private let core: any BuiltinLanguageFeatureCore

    package init(core: any BuiltinLanguageFeatureCore) {
        self.core = core
    }

    package convenience init() {
        self.init(core: UnavailableBuiltinLanguageFeatureCore())
    }

    package func supports(_ feature: LanguageFeature, in context: LanguageFeatureRequestContext) -> Bool {
        switch feature {
        case .completion:
            return core.isBuiltinLanguageFeatureAvailable || Self.keywordLanguage(for: context) != nil
        case .hover, .signatureHelp:
            return core.isBuiltinLanguageFeatureAvailable
        case .navigation(let method):
            // Interface/trait implementation discovery requires Precision LSP.
            return core.isBuiltinLanguageFeatureAvailable && method != "textDocument/implementation"
        }
    }

    package func completions(
        in context: LanguageFeatureRequestContext,
        completion: @escaping (Result<[LanguageServerCompletionItem], Error>) -> Void
    ) throws {
        let snippets = Self.snippetCompletions(in: context)
        let types = Self.builtinTypeCompletions(in: context)
        let keywords = Self.keywordCompletions(in: context)
        guard core.isBuiltinLanguageFeatureAvailable else {
            var seenLabels = Set<String>()
            let merged = (snippets + types + keywords).filter { seenLabels.insert($0.label).inserted }
            completion(.success(merged))
            return
        }
        let core = self.core
        Task { @MainActor in
            let symbols = await Task.detached(priority: .userInitiated) {
                core.builtinLanguageCompletions(
                    fileURL: context.fileURL,
                    text: context.text,
                    position: context.position,
                    workspaceURL: context.workspaceURL,
                    openBuffers: context.openBuffers.isEmpty ? nil : context.openBuffers
                ) ?? []
            }.value
            var seenLabels = Set<String>()
            let merged = (symbols + snippets + types + keywords).filter { seenLabels.insert($0.label).inserted }
            completion(.success(merged))
        }
    }

    package func hover(
        in context: LanguageFeatureRequestContext,
        completion: @escaping (Result<LanguageServerHover?, Error>) -> Void
    ) throws {
        guard core.isBuiltinLanguageFeatureAvailable else {
            completion(.success(nil))
            return
        }
        let core = self.core
        Task { @MainActor in
            let hover = await Task.detached(priority: .userInitiated) {
                core.builtinLanguageHover(
                    fileURL: context.fileURL,
                    text: context.text,
                    position: context.position,
                    workspaceURL: context.workspaceURL,
                    openBuffers: context.openBuffers.isEmpty ? nil : context.openBuffers
                )
            }.value
            completion(.success(hover))
        }
    }

    package func signatureHelp(
        in context: LanguageFeatureRequestContext,
        completion: @escaping (Result<LanguageServerSignatureHelp?, Error>) -> Void
    ) throws {
        guard core.isBuiltinLanguageFeatureAvailable else {
            completion(.success(nil))
            return
        }
        let core = self.core
        Task { @MainActor in
            let help = await Task.detached(priority: .userInitiated) {
                core.builtinLanguageSignatureHelp(
                    fileURL: context.fileURL,
                    text: context.text,
                    position: context.position,
                    workspaceURL: context.workspaceURL,
                    openBuffers: context.openBuffers.isEmpty ? nil : context.openBuffers
                )
            }.value
            completion(.success(help))
        }
    }

    package func navigate(
        method: String,
        in context: LanguageFeatureRequestContext,
        completion: @escaping (Result<[LanguageServerLocation], Error>) -> Void
    ) throws {
        guard core.isBuiltinLanguageFeatureAvailable,
              method != "textDocument/implementation" else {
            completion(.success([]))
            return
        }
        let core = self.core
        Task { @MainActor in
            let locations = await Task.detached(priority: .userInitiated) {
                core.builtinLanguageNavigation(
                    method: method,
                    fileURL: context.fileURL,
                    text: context.text,
                    position: context.position,
                    workspaceURL: context.workspaceURL,
                    openBuffers: context.openBuffers.isEmpty ? nil : context.openBuffers
                ) ?? []
            }.value
            completion(.success(locations))
        }
    }
}

@MainActor
package final class LanguageServerFeatureProvider: LanguageFeatureProvider {
    package let id: String
    package let priority: LanguageFeatureProviderPriority = .languageServer

    private let session: any LanguageServerSession
    private(set) var features: LanguageServerFeatureSet

    package init(
        providerID: String,
        session: any LanguageServerSession,
        features: LanguageServerFeatureSet = []
    ) {
        id = "lsp:\(providerID)"
        self.session = session
        self.features = features
    }

    package func updateFeatures(_ features: LanguageServerFeatureSet) {
        self.features = features
    }

    package func supports(_ feature: LanguageFeature, in _: LanguageFeatureRequestContext) -> Bool {
        guard session.isRunning else { return false }
        switch feature {
        case .completion:
            return features.contains(.completion)
        case .hover:
            return features.contains(.hover)
        case .signatureHelp:
            return features.contains(.signatureHelp)
        case .navigation(let method):
            return features.contains(Self.navigationFeature(for: method))
        }
    }

    package func completions(
        in context: LanguageFeatureRequestContext,
        completion: @escaping (Result<[LanguageServerCompletionItem], Error>) -> Void
    ) throws {
        let identity = session.sessionIdentity
        try session.completions(
            fileURL: context.fileURL,
            position: context.position,
            completion: { result in
                completion(result.map { values in values.map { value in
                    var value = value
                    value.originSessionIdentity = identity
                    return value
                } })
            }
        )
    }

    package func hover(
        in context: LanguageFeatureRequestContext,
        completion: @escaping (Result<LanguageServerHover?, Error>) -> Void
    ) throws {
        try session.hover(
            fileURL: context.fileURL,
            position: context.position,
            completion: completion
        )
    }

    package func signatureHelp(
        in context: LanguageFeatureRequestContext,
        completion: @escaping (Result<LanguageServerSignatureHelp?, Error>) -> Void
    ) throws {
        try session.signatureHelp(
            fileURL: context.fileURL,
            position: context.position,
            completion: completion
        )
    }

    package func navigate(
        method: String,
        in context: LanguageFeatureRequestContext,
        completion: @escaping (Result<[LanguageServerLocation], Error>) -> Void
    ) throws {
        try session.navigate(
            method: method,
            fileURL: context.fileURL,
            position: context.position,
            completion: completion
        )
    }

    private static func navigationFeature(for method: String) -> LanguageServerFeatureSet {
        switch method {
        case "textDocument/references": .references
        case "textDocument/implementation": .implementation
        default: .definition
        }
    }
}

private extension BuiltinLanguageFeatureProvider {
    struct SnippetTemplate {
        let label: String
        let detail: String
        let body: String
    }

    static func keywordLanguage(for context: LanguageFeatureRequestContext) -> LanguageSyntaxProfile? {
        guard let profile = LanguageSyntaxProfileRegistry.shared.profile(
            forLanguageID: context.languageID,
            fileURL: context.fileURL
        ), !profile.completionKeywords.isEmpty else {
            return nil
        }
        return profile
    }

    static func editRangeAndPrefix(
        in context: LanguageFeatureRequestContext
    ) -> (prefix: String, editRange: LanguageServerRange) {
        let prefix = identifierPrefix(in: context.text, at: context.position)
        let startColumn = max(0, context.position.utf16Column - prefix.utf16.count)
        let editRange = LanguageServerRange(
            start: LanguageServerPosition(line: context.position.line, utf16Column: startColumn),
            end: context.position
        )
        return (prefix, editRange)
    }

    static func snippetCompletions(
        in context: LanguageFeatureRequestContext
    ) -> [LanguageServerCompletionItem] {
        let ext = context.fileURL.pathExtension.lowercased()
        let templates: [SnippetTemplate]
        switch ext {
        case "go":
            templates = [
                SnippetTemplate(label: "iferr", detail: "if err != nil", body: "if err != nil {\n\treturn ${1:err}\n}$0"),
                SnippetTemplate(label: "tfunc", detail: "Go unit test", body: "func Test${1:Name}(t *testing.T) {\n\t$0\n}"),
                SnippetTemplate(label: "bfunc", detail: "Go benchmark", body: "func Benchmark${1:Name}(b *testing.B) {\n\tfor i := 0; i < b.N; i++ {\n\t\t$0\n\t}\n}"),
                SnippetTemplate(label: "funcm", detail: "Go method", body: "func (${1:s} *${2:Type}) ${3:Name}(${4:}) ${5:error} {\n\t$0\n}"),
            ]
        case "rs":
            templates = [
                SnippetTemplate(label: "fnm", detail: "Rust function", body: "fn ${1:name}(${2:}) -> ${3:()} {\n    $0\n}"),
                SnippetTemplate(label: "tmod", detail: "Rust #[cfg(test)] mod", body: "#[cfg(test)]\nmod tests {\n    use super::*;\n\n    #[test]\n    fn ${1:it_works}() {\n        $0\n    }\n}"),
                SnippetTemplate(label: "testfn", detail: "Rust #[test] fn", body: "#[test]\nfn ${1:test_case}() {\n    $0\n}"),
                SnippetTemplate(label: "matchb", detail: "Rust match block", body: "match ${1:value} {\n    ${2:_} => $0,\n}"),
            ]
        case "py", "pyi", "pyw":
            templates = [
                SnippetTemplate(label: "ifmain", detail: "Python main guard", body: "if __name__ == \"__main__\":\n    ${1:main()}$0"),
                SnippetTemplate(label: "defm", detail: "Python function", body: "def ${1:name}(${2:}) -> ${3:None}:\n    $0"),
                SnippetTemplate(label: "classm", detail: "Python class", body: "class ${1:Name}:\n    def __init__(self${2:}) -> None:\n        $0"),
                SnippetTemplate(label: "testpy", detail: "Pytest test function", body: "def test_${1:behavior}() -> None:\n    $0"),
            ]
        default:
            templates = []
        }
        guard !templates.isEmpty else { return [] }
        let (prefix, editRange) = editRangeAndPrefix(in: context)
        let prefixLower = prefix.lowercased()
        return templates
            .filter { prefix.isEmpty || $0.label.lowercased().hasPrefix(prefixLower) }
            .map { template in
                LanguageServerCompletionItem(
                    label: template.label,
                    detail: template.detail,
                    documentation: nil,
                    insertText: template.body,
                    sortText: "zx_snippet_\(template.label)",
                    filterText: template.label,
                    kind: 15,
                    textEdit: LanguageServerTextEdit(range: editRange, newText: template.body),
                    additionalTextEdits: [],
                    data: nil,
                    insertTextFormat: 2
                )
            }
    }

    static func builtinTypeCompletions(
        in context: LanguageFeatureRequestContext
    ) -> [LanguageServerCompletionItem] {
        guard let language = keywordLanguage(for: context),
              !language.builtinTypes.isEmpty else { return [] }
        let (prefix, editRange) = editRangeAndPrefix(in: context)
        let prefixLower = prefix.lowercased()
        return language.builtinTypes
            .filter { prefix.isEmpty || $0.lowercased().hasPrefix(prefixLower) }
            .sorted()
            .map { typeName in
                LanguageServerCompletionItem(
                    label: typeName,
                    detail: "\(language.displayName) type",
                    documentation: nil,
                    insertText: typeName,
                    sortText: "zy_type_\(typeName)",
                    filterText: typeName,
                    kind: 25,
                    textEdit: LanguageServerTextEdit(range: editRange, newText: typeName),
                    additionalTextEdits: [],
                    data: nil
                )
            }
    }

    static func keywordCompletions(
        in context: LanguageFeatureRequestContext
    ) -> [LanguageServerCompletionItem] {
        guard let language = keywordLanguage(for: context) else { return [] }
        let (prefix, editRange) = editRangeAndPrefix(in: context)
        let prefixLower = prefix.lowercased()

        return language.completionKeywords
            .filter { prefix.isEmpty || $0.lowercased().hasPrefix(prefixLower) }
            .sorted()
            .map { keyword in
                LanguageServerCompletionItem(
                    label: keyword,
                    detail: "\(language.displayName) keyword",
                    documentation: nil,
                    insertText: keyword,
                    sortText: "zz_keyword_\(keyword)",
                    filterText: keyword,
                    kind: 14,
                    textEdit: LanguageServerTextEdit(range: editRange, newText: keyword),
                    additionalTextEdits: [],
                    data: nil
                )
            }
    }

    static func identifierPrefix(in text: String, at position: LanguageServerPosition) -> String {
        guard position.line >= 0, position.utf16Column >= 0 else { return "" }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard position.line < lines.count else { return "" }

        let line = lines[position.line]
        let utf16 = line.utf16
        guard position.utf16Column <= utf16.count else { return "" }
        let utf16Index = utf16.index(utf16.startIndex, offsetBy: position.utf16Column)
        guard let cursor = String.Index(utf16Index, within: line) else { return "" }

        var start = cursor
        while start > line.startIndex {
            let previous = line.index(before: start)
            guard isIdentifierCharacter(line[previous]) else { break }
            start = previous
        }
        return String(line[start..<cursor])
    }

    static func isIdentifierCharacter(_ character: Character) -> Bool {
        character == "_" || character == "$" || character.isLetter || character.isNumber
    }
}
