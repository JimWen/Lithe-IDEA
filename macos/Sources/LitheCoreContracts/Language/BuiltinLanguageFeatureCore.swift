import Foundation

package protocol BuiltinLanguageFeatureCore: Sendable {
    var isBuiltinLanguageFeatureAvailable: Bool { get }
    func builtinLanguageCompletions(
        fileURL: URL,
        text: String,
        position: LanguageServerPosition
    ) -> [LanguageServerCompletionItem]?
    func builtinLanguageHover(
        fileURL: URL,
        text: String,
        position: LanguageServerPosition
    ) -> LanguageServerHover?
    func builtinLanguageNavigation(
        method: String,
        fileURL: URL,
        text: String,
        position: LanguageServerPosition
    ) -> [LanguageServerLocation]?

    func builtinLanguageCompletions(
        fileURL: URL,
        text: String,
        position: LanguageServerPosition,
        workspaceURL: URL?,
        openBuffers: [String: String]?
    ) -> [LanguageServerCompletionItem]?
    func builtinLanguageHover(
        fileURL: URL,
        text: String,
        position: LanguageServerPosition,
        workspaceURL: URL?,
        openBuffers: [String: String]?
    ) -> LanguageServerHover?
    func builtinLanguageSignatureHelp(
        fileURL: URL,
        text: String,
        position: LanguageServerPosition,
        workspaceURL: URL?,
        openBuffers: [String: String]?
    ) -> LanguageServerSignatureHelp?
    func builtinLanguageNavigation(
        method: String,
        fileURL: URL,
        text: String,
        position: LanguageServerPosition,
        workspaceURL: URL?,
        openBuffers: [String: String]?
    ) -> [LanguageServerLocation]?
}

package extension BuiltinLanguageFeatureCore {
    func builtinLanguageCompletions(
        fileURL: URL,
        text: String,
        position: LanguageServerPosition,
        workspaceURL _: URL?,
        openBuffers _: [String: String]?
    ) -> [LanguageServerCompletionItem]? {
        builtinLanguageCompletions(fileURL: fileURL, text: text, position: position)
    }

    func builtinLanguageHover(
        fileURL: URL,
        text: String,
        position: LanguageServerPosition,
        workspaceURL _: URL?,
        openBuffers _: [String: String]?
    ) -> LanguageServerHover? {
        builtinLanguageHover(fileURL: fileURL, text: text, position: position)
    }

    func builtinLanguageSignatureHelp(
        fileURL _: URL,
        text _: String,
        position _: LanguageServerPosition,
        workspaceURL _: URL?,
        openBuffers _: [String: String]?
    ) -> LanguageServerSignatureHelp? {
        nil
    }

    func builtinLanguageNavigation(
        method: String,
        fileURL: URL,
        text: String,
        position: LanguageServerPosition,
        workspaceURL _: URL?,
        openBuffers _: [String: String]?
    ) -> [LanguageServerLocation]? {
        builtinLanguageNavigation(method: method, fileURL: fileURL, text: text, position: position)
    }
}
