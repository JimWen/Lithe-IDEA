import Foundation
import LitheModuleAPI

package struct LanguageToolingCapability: OptionSet, Hashable, Sendable {
    package let rawValue: Int
    package init(rawValue: Int) { self.rawValue = rawValue }

    package static let run = Self(rawValue: 1 << 0)
    package static let languageServer = Self(rawValue: 1 << 1)
    package static let debugAdapter = Self(rawValue: 1 << 2)
    package static let formatting = Self(rawValue: 1 << 3)
    package static let testing = Self(rawValue: 1 << 4)

    package static func named(_ name: String) -> Self? {
        switch name {
        case "run": .run
        case "languageServer": .languageServer
        case "debugAdapter": .debugAdapter
        case "formatting": .formatting
        case "testing": .testing
        default: nil
        }
    }

    package static func names(_ names: [String]) -> Self {
        names.reduce(into: Self()) { capabilities, name in
            if let capability = Self.named(name) {
                capabilities.insert(capability)
            }
        }
    }
}

package struct LanguageServerFeatureSet: OptionSet, Hashable, Sendable {
    package let rawValue: Int
    package init(rawValue: Int) { self.rawValue = rawValue }

    package static let definition = Self(rawValue: 1 << 0)
    package static let references = Self(rawValue: 1 << 1)
    package static let implementation = Self(rawValue: 1 << 2)
    package static let hover = Self(rawValue: 1 << 3)
    package static let completion = Self(rawValue: 1 << 4)
    package static let rename = Self(rawValue: 1 << 5)
    package static let formatting = Self(rawValue: 1 << 6)
    package static let codeActions = Self(rawValue: 1 << 7)
    package static let completionResolve = Self(rawValue: 1 << 8)
    package static let codeActionResolve = Self(rawValue: 1 << 9)
    package static let executeCommand = Self(rawValue: 1 << 10)
    package static let prepareRename = Self(rawValue: 1 << 11)
    package static let inlayHints = Self(rawValue: 1 << 12)
    package static let signatureHelp = Self(rawValue: 1 << 13)
    package static let documentHighlight = Self(rawValue: 1 << 14)
    package static let documentSymbol = Self(rawValue: 1 << 15)
    package static let semanticTokens = Self(rawValue: 1 << 16)

    package static let standardEditing: Self = [
        .definition, .references, .implementation, .hover, .completion,
        .rename, .formatting, .codeActions, .completionResolve,
        .codeActionResolve, .executeCommand
    ]
}

package enum ToolingActivationPolicy: String, Codable, Hashable, Sendable {
    case onDemand
    case always
}

/// Controls whether Lithe operates in zero-LSP Lightweight Mode by default or
/// starts language servers automatically for precision semantic features.
package enum LanguageIntelligenceMode: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    /// Default fast mode backed by Rust Core indexing, symbols, folding, and syntax profiles.
    case lightweight
    /// Opt-in precision mode backed by external language servers (e.g. gopls, rust-analyzer, basedpyright).
    case lsp

    package var id: String { rawValue }
}

package struct LanguageServerLaunchDescriptor: Hashable, Sendable {
    package let executableNames: [String]
    package let arguments: [String]
    package let validationArguments: [String]
    package let environment: [String: String]
    package let initializationOptions: ToolingJSONValue?

    package init(
        executableNames: [String],
        arguments: [String] = [],
        validationArguments: [String] = [],
        environment: [String: String] = [:],
        initializationOptions: ToolingJSONValue? = nil
    ) {
        self.executableNames = executableNames
        self.arguments = arguments
        self.validationArguments = validationArguments
        self.environment = environment
        self.initializationOptions = initializationOptions
    }
}

package struct LanguageServerInstallationDescriptor: Hashable, Sendable {
    package let homebrewFormula: String?
    package let officialDownloadURL: URL?

    package init(homebrewFormula: String?, officialDownloadURL: URL?) {
        self.homebrewFormula = homebrewFormula
        self.officialDownloadURL = officialDownloadURL
    }
}

package struct LanguageProviderDescriptor: Identifiable, Hashable, Sendable {
    package let id: String
    package let displayName: String
    package let fileExtensions: Set<String>
    package let fileNames: Set<String>
    package let fileNamePrefixes: Set<String>
    package let capabilities: LanguageToolingCapability
    package let activationPolicy: ToolingActivationPolicy
    package let languageIdentifier: String?
    package let languageIdentifiersByExtension: [String: String]
    package let languageIdentifiersByFileName: [String: String]
    package let languageServerLaunch: LanguageServerLaunchDescriptor?
    package let languageServerInstallation: LanguageServerInstallationDescriptor?

    package init(
        id: String,
        displayName: String,
        fileExtensions: Set<String>,
        fileNames: Set<String> = [],
        fileNamePrefixes: Set<String> = [],
        capabilities: LanguageToolingCapability,
        activationPolicy: ToolingActivationPolicy,
        languageIdentifier: String? = nil,
        languageIdentifiersByExtension: [String: String] = [:],
        languageIdentifiersByFileName: [String: String] = [:],
        languageServerLaunch: LanguageServerLaunchDescriptor? = nil,
        languageServerInstallation: LanguageServerInstallationDescriptor? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.fileExtensions = Set(fileExtensions.map { $0.lowercased() })
        self.fileNames = Set(fileNames.map { $0.lowercased() })
        self.fileNamePrefixes = Set(fileNamePrefixes.map { $0.lowercased() })
        self.capabilities = capabilities
        self.activationPolicy = activationPolicy
        self.languageIdentifier = languageIdentifier
        self.languageIdentifiersByExtension = Dictionary(
            uniqueKeysWithValues: languageIdentifiersByExtension.map {
                ($0.key.lowercased(), $0.value)
            }
        )
        self.languageIdentifiersByFileName = Dictionary(
            uniqueKeysWithValues: languageIdentifiersByFileName.map {
                ($0.key.lowercased(), $0.value)
            }
        )
        self.languageServerLaunch = languageServerLaunch
        self.languageServerInstallation = languageServerInstallation
    }

    package func handles(fileURL: URL) -> Bool {
        let fileName = fileURL.lastPathComponent.lowercased()
        return fileExtensions.contains(fileURL.pathExtension.lowercased())
            || fileNames.contains(fileName)
            || fileNamePrefixes.contains { fileName.hasPrefix($0) }
    }

    package func languageIdentifier(for fileURL: URL) -> String {
        let extensionName = fileURL.pathExtension.lowercased()
        let fileName = fileURL.lastPathComponent.lowercased()
        return languageIdentifiersByFileName[fileName]
            ?? languageIdentifiersByExtension[extensionName]
            ?? languageIdentifier
            ?? id
    }
}

package struct LanguageProviderCatalog: Sendable {
    package let descriptors: [LanguageProviderDescriptor]

    package init(descriptors: [LanguageProviderDescriptor]) {
        self.descriptors = descriptors
    }

    /// Minimal fallback used only when the Rust core is not linked. The full
    /// market language catalog is registered by Rust's dedicated LSP config.
    package static let compatibilityFallback = LanguageProviderCatalog(descriptors: [
        LanguageProviderDescriptor(
            id: "java", displayName: "Java", fileExtensions: ["java"],
            capabilities: [.run, .languageServer, .debugAdapter, .formatting, .testing],
            activationPolicy: .onDemand
        ),
        LanguageProviderDescriptor(
            id: "go", displayName: "Go", fileExtensions: ["go"],
            capabilities: [.run, .languageServer, .debugAdapter, .formatting, .testing],
            activationPolicy: .onDemand
        ),
        LanguageProviderDescriptor(
            id: "python", displayName: "Python", fileExtensions: ["py", "pyw"],
            capabilities: [.run, .languageServer, .debugAdapter, .formatting, .testing],
            activationPolicy: .onDemand
        ),
        LanguageProviderDescriptor(
            id: "node", displayName: "Node.js", fileExtensions: ["js", "jsx", "ts", "tsx", "mjs", "cjs"],
            capabilities: [.run, .languageServer, .debugAdapter, .formatting, .testing],
            activationPolicy: .onDemand,
            languageIdentifier: "javascript",
            languageIdentifiersByExtension: [
                "ts": "typescript",
                "tsx": "typescriptreact",
                "jsx": "javascriptreact"
            ]
        ),
        LanguageProviderDescriptor(
            id: "rust", displayName: "Rust", fileExtensions: ["rs"],
            capabilities: [.run, .languageServer, .debugAdapter, .formatting, .testing],
            activationPolicy: .onDemand
        ),
    ])

    package func provider(for fileURL: URL) -> LanguageProviderDescriptor? {
        descriptors.first { $0.handles(fileURL: fileURL) }
    }
}

package extension LanguageProviderCatalog {
    var debugProviders: [DebugProviderDescriptor] {
        descriptors.compactMap { descriptor in
            guard descriptor.capabilities.contains(.debugAdapter) else { return nil }
            return DebugProviderDescriptor(
                id: descriptor.id,
                displayName: descriptor.displayName,
                fileExtensions: descriptor.fileExtensions,
                fileNames: descriptor.fileNames,
                fileNamePrefixes: descriptor.fileNamePrefixes
            )
        }
    }
}

public struct LanguageServerPosition: Codable, Equatable, Sendable {
    public let line: Int
    public let utf16Column: Int

    public init(line: Int, utf16Column: Int) {
        self.line = line
        self.utf16Column = utf16Column
    }
}

public struct LanguageServerRange: Codable, Equatable, Sendable {
    public let start: LanguageServerPosition
    public let end: LanguageServerPosition

    public init(start: LanguageServerPosition, end: LanguageServerPosition) {
        self.start = start
        self.end = end
    }
}

package struct LanguageServerDiagnosticRelatedInformation: Equatable, Sendable {
    package let fileURL: URL
    package let range: LanguageServerRange
    package let message: String

    package init(fileURL: URL, range: LanguageServerRange, message: String) {
        self.fileURL = fileURL
        self.range = range
        self.message = message
    }
}

package struct LanguageServerDiagnostic: Equatable, Sendable {
    package let range: LanguageServerRange
    package let severity: Int?
    package let message: String
    package let source: String?
    package let code: String?
    package let tags: [Int]
    package let relatedInformation: [LanguageServerDiagnosticRelatedInformation]

    package init(
        range: LanguageServerRange,
        severity: Int?,
        message: String,
        source: String?,
        code: String?,
        tags: [Int] = [],
        relatedInformation: [LanguageServerDiagnosticRelatedInformation] = []
    ) {
        self.range = range
        self.severity = severity
        self.message = message
        self.source = source
        self.code = code
        self.tags = tags
        self.relatedInformation = relatedInformation
    }
}

package struct LanguageServerLocation: Equatable, Sendable {
    package let url: URL
    package let range: LanguageServerRange
    package let isReadOnly: Bool
    package let displayPath: String?

    package init(
        url: URL,
        range: LanguageServerRange,
        isReadOnly: Bool = false,
        displayPath: String? = nil
    ) {
        self.url = url
        self.range = range
        self.isReadOnly = isReadOnly
        self.displayPath = displayPath
    }
}

package struct LanguageServerHover: Equatable, Sendable {
    package let contents: String
    package let isMarkdown: Bool
    package let range: LanguageServerRange?

    package init(contents: String, isMarkdown: Bool, range: LanguageServerRange?) {
        self.contents = contents
        self.isMarkdown = isMarkdown
        self.range = range
    }
}

package struct LanguageServerCompletionItem: Identifiable, Equatable, Sendable {
    /// Host-local provenance; never serialized into an LSP request.
    package var requestContextID: UUID? = nil
    /// Set only by the LSP provider; local candidates never require its session.
    package var originSessionIdentity: String? = nil
    package let label: String
    package let detail: String?
    package let documentation: String?
    package let insertText: String
    /// LSP `InsertTextFormat` (`1` = plain text, `2` = snippet).
    package let insertTextFormat: Int?
    /// Indicates that the server prefers preselecting this item when shown.
    package let preselect: Bool
    package let sortText: String?
    package let filterText: String?
    package let kind: Int?
    package let textEdit: LanguageServerTextEdit?
    package let additionalTextEdits: [LanguageServerTextEdit]
    package let data: ToolingJSONValue?

    package var isSnippet: Bool {
        insertTextFormat == 2
    }

    package init(
        label: String,
        detail: String?,
        documentation: String?,
        insertText: String,
        sortText: String?,
        filterText: String?,
        kind: Int?,
        textEdit: LanguageServerTextEdit?,
        additionalTextEdits: [LanguageServerTextEdit],
        data: ToolingJSONValue?,
        insertTextFormat: Int? = nil,
        preselect: Bool = false
    ) {
        self.label = label
        self.detail = detail
        self.documentation = documentation
        self.insertText = insertText
        self.insertTextFormat = insertTextFormat
        self.preselect = preselect
        self.sortText = sortText
        self.filterText = filterText
        self.kind = kind
        self.textEdit = textEdit
        self.additionalTextEdits = additionalTextEdits
        self.data = data
    }

    package var id: String {
        let rangeKey: String
        if let range = textEdit?.range {
            rangeKey = "\(range.start.line):\(range.start.utf16Column)-\(range.end.line):\(range.end.utf16Column)"
        } else {
            rangeKey = ""
        }
        return [
            originSessionIdentity ?? "local",
            label,
            detail ?? "",
            insertText,
            sortText ?? "",
            rangeKey,
        ].joined(separator: "\u{1F}")
    }
}

package struct LanguageServerInlayHint: Equatable, Sendable {
    package enum Kind: Int, Equatable, Sendable {
        case type = 1
        case parameter = 2
    }

    package let position: LanguageServerPosition
    package let label: String
    package let kind: Kind?
    package let tooltip: String?
    package let paddingLeft: Bool
    package let paddingRight: Bool

    package init(
        position: LanguageServerPosition,
        label: String,
        kind: Kind? = nil,
        tooltip: String? = nil,
        paddingLeft: Bool = false,
        paddingRight: Bool = false
    ) {
        self.position = position
        self.label = label
        self.kind = kind
        self.tooltip = tooltip
        self.paddingLeft = paddingLeft
        self.paddingRight = paddingRight
    }
}

package struct LanguageServerParameterInformation: Equatable, Sendable {
    package let label: String
    package let labelStart: Int?
    package let labelEnd: Int?
    package let documentation: String?

    package init(
        label: String,
        labelStart: Int? = nil,
        labelEnd: Int? = nil,
        documentation: String? = nil
    ) {
        self.label = label
        self.labelStart = labelStart
        self.labelEnd = labelEnd
        self.documentation = documentation
    }
}

package struct LanguageServerSignatureInformation: Equatable, Sendable {
    package let label: String
    package let documentation: String?
    package let parameters: [LanguageServerParameterInformation]
    package let activeParameter: Int?

    package init(
        label: String,
        documentation: String? = nil,
        parameters: [LanguageServerParameterInformation] = [],
        activeParameter: Int? = nil
    ) {
        self.label = label
        self.documentation = documentation
        self.parameters = parameters
        self.activeParameter = activeParameter
    }
}

package struct LanguageServerSignatureHelp: Equatable, Sendable {
    package let signatures: [LanguageServerSignatureInformation]
    package let activeSignature: Int?
    package let activeParameter: Int?

    package init(
        signatures: [LanguageServerSignatureInformation],
        activeSignature: Int? = nil,
        activeParameter: Int? = nil
    ) {
        self.signatures = signatures
        self.activeSignature = activeSignature
        self.activeParameter = activeParameter
    }

    package var currentSignature: LanguageServerSignatureInformation? {
        guard !signatures.isEmpty else { return nil }
        let index = min(max(0, activeSignature ?? 0), signatures.count - 1)
        return signatures[index]
    }

    package var effectiveActiveParameter: Int? {
        guard let signature = currentSignature, !signature.parameters.isEmpty else { return nil }
        let raw = signature.activeParameter ?? activeParameter ?? 0
        guard raw >= 0 && raw < signature.parameters.count else { return nil }
        return raw
    }
}

package struct LanguageServerDocumentHighlight: Equatable, Sendable {
    package enum Kind: Int, Equatable, Sendable {
        case text = 1
        case read = 2
        case write = 3
    }

    package let range: LanguageServerRange
    package let kind: Kind

    package init(range: LanguageServerRange, kind: Kind = .text) {
        self.range = range
        self.kind = kind
    }
}

package struct LanguageServerDocumentSymbol: Identifiable, Equatable, Sendable {
    package let name: String
    package let detail: String?
    package let kind: Int
    package let range: LanguageServerRange
    package let selectionRange: LanguageServerRange
    package let children: [LanguageServerDocumentSymbol]

    package var id: String {
        "\(name):\(kind):\(selectionRange.start.line):\(selectionRange.start.utf16Column):\(range.end.line)"
    }

    package init(
        name: String,
        detail: String? = nil,
        kind: Int,
        range: LanguageServerRange,
        selectionRange: LanguageServerRange,
        children: [LanguageServerDocumentSymbol] = []
    ) {
        self.name = name
        self.detail = detail
        self.kind = kind
        self.range = range
        self.selectionRange = selectionRange
        self.children = children
    }

    /// Returns the deepest enclosing symbol chain containing the given zero-based position.
    package static func enclosingPath(
        in symbols: [LanguageServerDocumentSymbol],
        line: Int,
        utf16Column: Int
    ) -> [LanguageServerDocumentSymbol] {
        let target = LanguageServerPosition(line: line, utf16Column: utf16Column)
        for symbol in symbols {
            guard contains(range: symbol.range, position: target) else { continue }
            let childPath = enclosingPath(in: symbol.children, line: line, utf16Column: utf16Column)
            return [symbol] + childPath
        }
        // Offline flat symbols have single-line ranges; fall back to the nearest preceding symbol.
        if let preceding = symbols.last(where: { $0.selectionRange.start.line <= line && $0.range.start.line == $0.range.end.line }) {
            return [preceding]
        }
        return []
    }

    private static func contains(range: LanguageServerRange, position: LanguageServerPosition) -> Bool {
        if position.line < range.start.line || position.line > range.end.line { return false }
        if position.line == range.start.line && position.utf16Column < range.start.utf16Column { return false }
        if position.line == range.end.line && position.utf16Column > range.end.utf16Column { return false }
        return true
    }
}

package struct LanguageServerSemanticToken: Equatable, Sendable {
    package let line: Int
    package let utf16Column: Int
    package let length: Int
    package let tokenType: String
    package let tokenModifiers: [String]

    package init(
        line: Int,
        utf16Column: Int,
        length: Int,
        tokenType: String,
        tokenModifiers: [String] = []
    ) {
        self.line = line
        self.utf16Column = utf16Column
        self.length = length
        self.tokenType = tokenType
        self.tokenModifiers = tokenModifiers
    }
}

package struct LanguageServerCommand: Equatable, Sendable {
    package let title: String
    package let command: String
    package let arguments: [ToolingJSONValue]

    package init(title: String, command: String, arguments: [ToolingJSONValue]) {
        self.title = title
        self.command = command
        self.arguments = arguments
    }
}

package enum LanguageServerLogLevel: String, Sendable {
    case info
    case warning
    case error
}

/// What the editor wants from a language server, named by intent rather than by
/// the LSP method that satisfies it. The core maps these to methods and owns the
/// request IDs, so the UI never names a protocol method or reads a raw response.
package struct LanguageServerPrepareRenameResult: Equatable, Sendable {
    package let range: LanguageServerRange?
    package let placeholder: String?
    package let defaultBehavior: Bool

    package init(
        range: LanguageServerRange?,
        placeholder: String?,
        defaultBehavior: Bool
    ) {
        self.range = range
        self.placeholder = placeholder
        self.defaultBehavior = defaultBehavior
    }
}

package enum LanguageServerOperation: String, Equatable, Sendable {
    case completion
    case hover
    case definition
    case declaration
    case typeDefinition
    case references
    case implementation
    case prepareRename
    case rename
    case formatting
    case codeActions
    case resolveCompletion
    case resolveCodeAction
    case executeCommand
    case inlayHints
    case signatureHelp
    case documentHighlight
    case documentSymbols
    case semanticTokensFull
    case foldingRanges
    case codeLens
    /// Resolving a server-owned source that has no file on disk, such as a
    /// decompiled class behind a `jdt://` URI.
    case virtualDocument
}

package struct LanguageServerSessionFailure: Equatable, Sendable {
    package let code: String?
    package let stage: String?
    package let exitCode: Int32?
    package let message: String?

    package init(
        code: String? = nil,
        stage: String? = nil,
        exitCode: Int32? = nil,
        message: String? = nil
    ) {
        self.code = code
        self.stage = stage
        self.exitCode = exitCode
        self.message = message
    }

    package var isTimedOut: Bool {
        code == "timed_out" || code == "initializeTimeout" || code == "serviceReadyTimeout"
    }
}

package struct LanguageServerSessionStartError: LocalizedError, Sendable {
    package let failure: LanguageServerSessionFailure

    package init(failure: LanguageServerSessionFailure) {
        self.failure = failure
    }

    package var errorDescription: String? {
        failure.message ?? "Language server failed to start."
    }
}

package enum LanguageServerSessionState: Equatable, Sendable {
    case startingProcess
    case initializing
    case ready
    case stopping
    case stopped
    case failed(LanguageServerSessionFailure)
}

package struct LanguageServerInfo: Equatable, Sendable {
    package let name: String
    package let version: String?

    package init(name: String, version: String?) {
        self.name = name
        self.version = version
    }
}

package struct LanguageServerLogEntry: Identifiable, Equatable, Sendable {
    package let id: UUID
    package let timestamp: Date
    package let providerID: String
    package let operationID: String?
    package let level: LanguageServerLogLevel
    package let message: String
    package let detail: String?

    package init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        providerID: String,
        operationID: String? = nil,
        level: LanguageServerLogLevel,
        message: String,
        detail: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.providerID = providerID
        self.operationID = operationID
        self.level = level
        self.message = message
        self.detail = detail
    }
}

package struct LanguageServerTextEdit: Codable, Equatable, Sendable {
    package let range: LanguageServerRange
    package let newText: String
    package let annotationID: String?

    package init(range: LanguageServerRange, newText: String, annotationID: String? = nil) {
        self.range = range
        self.newText = newText
        self.annotationID = annotationID
    }

    private enum CodingKeys: String, CodingKey {
        case range, newText
        case annotationID = "annotationId"
    }
}

package struct LanguageServerCodeAction: Identifiable, Equatable, Sendable {
    /// Host-local provenance retained across menu selection and resolve.
    package var requestContextID: UUID? = nil
    package let title: String
    package let kind: String?
    package let isPreferred: Bool
    package let edit: LanguageServerWorkspaceEdit?
    package let command: LanguageServerCommand?
    package let data: ToolingJSONValue?

    package init(
        title: String,
        kind: String?,
        isPreferred: Bool,
        edit: LanguageServerWorkspaceEdit?,
        command: LanguageServerCommand?,
        data: ToolingJSONValue?
    ) {
        self.title = title
        self.kind = kind
        self.isPreferred = isPreferred
        self.edit = edit
        self.command = command
        self.data = data
    }

    package var id: String { [title, kind ?? ""].joined(separator: "\u{1F}") }
}

@MainActor
package protocol LanguageServerSession: AnyObject {
    var isRunning: Bool { get }
    var sessionIdentity: String? { get }
    func synchronizedDocumentSnapshot(for fileURL: URL) -> LanguageServerSynchronizedDocumentSnapshot?
    /// Packaged Java Test runner, if this JDT LS session was launched with one.
    var javaTestRunnerURL: URL? { get }
    var onDiagnostics: ((URL, [LanguageServerDiagnostic]) -> Void)? { get set }
    var onLog: ((LanguageServerLogLevel, String, String?, String?) -> Void)? { get set }
    var onStateChange: ((LanguageServerSessionState) -> Void)? { get set }
    var features: LanguageServerFeatureSet { get }
    var onFeaturesChange: ((LanguageServerFeatureSet) -> Void)? { get set }
    var serverInfo: LanguageServerInfo? { get }
    var onServerInfoChange: ((LanguageServerInfo?) -> Void)? { get set }
    /// Start the language server for the given workspace root.
    /// - Parameter workspaceFingerprint: An opaque digest of the workspace's
    ///   build-system structure. When non-nil, JDT LS uses a per-fingerprint
    ///   state directory so structural changes (add/remove module, edit root
    ///   build.gradle) never reuse a stale project model.
    func start(rootURL: URL, workspaceFingerprint: String?) throws
    func synchronize(fileURL: URL, text: String, languageID: String) throws
    func notifyWorkspaceFilesChanged(_ changes: [LanguageServerWorkspaceFileChange]) throws
    func closeDocument(_ fileURL: URL)
    func completions(
        fileURL: URL,
        position: LanguageServerPosition,
        completion: @escaping (Result<[LanguageServerCompletionItem], Error>) -> Void
    ) throws
    func hover(
        fileURL: URL,
        position: LanguageServerPosition,
        completion: @escaping (Result<LanguageServerHover?, Error>) -> Void
    ) throws
    func navigate(
        method: String,
        fileURL: URL,
        position: LanguageServerPosition,
        completion: @escaping (Result<[LanguageServerLocation], Error>) -> Void
    ) throws
    func prepareRename(
        fileURL: URL,
        position: LanguageServerPosition,
        completion: @escaping (Result<LanguageServerPrepareRenameResult?, Error>) -> Void
    ) throws
    func rename(
        fileURL: URL,
        position: LanguageServerPosition,
        newName: String,
        completion: @escaping (Result<LanguageServerWorkspaceEdit, Error>) -> Void
    ) throws
    func format(
        fileURL: URL,
        completion: @escaping (Result<[LanguageServerTextEdit], Error>) -> Void
    ) throws
    func codeActions(
        fileURL: URL,
        range: LanguageServerRange,
        diagnostics: [LanguageServerDiagnostic],
        completion: @escaping (Result<[LanguageServerCodeAction], Error>) -> Void
    ) throws
    func resolveCompletion(
        _ item: LanguageServerCompletionItem,
        fileURL: URL,
        completion: @escaping (Result<LanguageServerCompletionItem, Error>) -> Void
    ) throws
    func resolveCodeAction(
        _ action: LanguageServerCodeAction,
        fileURL: URL,
        completion: @escaping (Result<LanguageServerCodeAction, Error>) -> Void
    ) throws
    func execute(
        _ command: LanguageServerCommand,
        fileURL: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) throws
    func executeReturningValue(
        _ command: LanguageServerCommand,
        fileURL: URL,
        completion: @escaping (Result<ToolingJSONValue, Error>) -> Void
    ) throws
    func resolveVirtualDocument(
        uri: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) throws
    func javaNavigationMarkers(
        fileURL: URL,
        completion: @escaping (Result<[JavaNavigationMarker], Error>) -> Void
    ) throws
    func resolveJavaNavigation(
        fileURL: URL,
        marker: JavaNavigationMarker,
        completion: @escaping (Result<[LanguageServerLocation], Error>) -> Void
    ) throws
    func inlayHints(
        fileURL: URL,
        range: LanguageServerRange,
        completion: @escaping (Result<[LanguageServerInlayHint], Error>) -> Void
    ) throws
    func signatureHelp(
        fileURL: URL,
        position: LanguageServerPosition,
        completion: @escaping (Result<LanguageServerSignatureHelp?, Error>) -> Void
    ) throws
    func documentHighlight(
        fileURL: URL,
        position: LanguageServerPosition,
        completion: @escaping (Result<[LanguageServerDocumentHighlight], Error>) -> Void
    ) throws
    func documentSymbols(
        fileURL: URL,
        completion: @escaping (Result<[LanguageServerDocumentSymbol], Error>) -> Void
    ) throws
    func semanticTokens(
        fileURL: URL,
        completion: @escaping (Result<[LanguageServerSemanticToken], Error>) -> Void
    ) throws
    func stop()
}

package extension LanguageServerSession {
    // Sessions that do not expose synchronized source identity cannot supply
    // versioned workspace edits to the guarded host application path.
    var sessionIdentity: String? { nil }
    func synchronizedDocumentSnapshot(for fileURL: URL) -> LanguageServerSynchronizedDocumentSnapshot? { nil }
}

package extension LanguageServerSession {
    var features: LanguageServerFeatureSet { [] }
    var onFeaturesChange: ((LanguageServerFeatureSet) -> Void)? {
        get { nil }
        set {}
    }
    var onLog: ((LanguageServerLogLevel, String, String?, String?) -> Void)? {
        get { nil }
        set {}
    }
    var onStateChange: ((LanguageServerSessionState) -> Void)? {
        get { nil }
        set {}
    }
    func executeReturningValue(
        _ command: LanguageServerCommand,
        fileURL: URL,
        completion: @escaping (Result<ToolingJSONValue, Error>) -> Void
    ) throws {
        try execute(command, fileURL: fileURL) { result in
            completion(result.map { .null })
        }
    }
    var serverInfo: LanguageServerInfo? { nil }
    var onServerInfoChange: ((LanguageServerInfo?) -> Void)? {
        get { nil }
        set {}
    }
    func closeDocument(_: URL) {}
    func notifyWorkspaceFilesChanged(_: [LanguageServerWorkspaceFileChange]) throws {}
    func javaNavigationMarkers(
        fileURL _: URL,
        completion: @escaping (Result<[JavaNavigationMarker], Error>) -> Void
    ) throws {
        completion(.failure(LanguageServerFeatureUnavailable.javaNavigation))
    }
    func resolveJavaNavigation(
        fileURL _: URL,
        marker _: JavaNavigationMarker,
        completion: @escaping (Result<[LanguageServerLocation], Error>) -> Void
    ) throws {
        completion(.failure(LanguageServerFeatureUnavailable.javaNavigation))
    }
    func prepareRename(
        fileURL _: URL,
        position _: LanguageServerPosition,
        completion: @escaping (Result<LanguageServerPrepareRenameResult?, Error>) -> Void
    ) throws {
        completion(.failure(LanguageServerFeatureUnavailable.prepareRename))
    }
    func inlayHints(
        fileURL _: URL,
        range _: LanguageServerRange,
        completion: @escaping (Result<[LanguageServerInlayHint], Error>) -> Void
    ) throws {
        completion(.failure(LanguageServerFeatureUnavailable.inlayHints))
    }
    func signatureHelp(
        fileURL _: URL,
        position _: LanguageServerPosition,
        completion: @escaping (Result<LanguageServerSignatureHelp?, Error>) -> Void
    ) throws {
        completion(.failure(LanguageServerFeatureUnavailable.signatureHelp))
    }
    func documentHighlight(
        fileURL _: URL,
        position _: LanguageServerPosition,
        completion: @escaping (Result<[LanguageServerDocumentHighlight], Error>) -> Void
    ) throws {
        completion(.failure(LanguageServerFeatureUnavailable.documentHighlight))
    }
    func documentSymbols(
        fileURL _: URL,
        completion: @escaping (Result<[LanguageServerDocumentSymbol], Error>) -> Void
    ) throws {
        completion(.failure(LanguageServerFeatureUnavailable.documentSymbols))
    }
    func semanticTokens(
        fileURL _: URL,
        completion: @escaping (Result<[LanguageServerSemanticToken], Error>) -> Void
    ) throws {
        completion(.failure(LanguageServerFeatureUnavailable.semanticTokens))
    }
}

private enum LanguageServerFeatureUnavailable: LocalizedError {
    case javaNavigation
    case prepareRename
    case inlayHints
    case signatureHelp
    case documentHighlight
    case documentSymbols
    case semanticTokens

    var errorDescription: String? {
        switch self {
        case .javaNavigation:
            "Java navigation is not supported by this language server."
        case .prepareRename:
            "Prepare rename is not supported by this language server."
        case .inlayHints:
            "Inlay hints are not supported by this language server."
        case .signatureHelp:
            "Signature help is not supported by this language server."
        case .documentHighlight:
            "Document highlight is not supported by this language server."
        case .documentSymbols:
            "Document symbols are not supported by this language server."
        case .semanticTokens:
            "Semantic tokens are not supported by this language server."
        }
    }
}

@MainActor
package protocol LanguageProviderRuntime: AnyObject {
    var descriptor: LanguageProviderDescriptor { get }
    var supportsLanguageServerSession: Bool { get }
    var unavailableToolingMessage: String? { get }
    func makeLanguageServerSession() -> (any LanguageServerSession)?
}

@MainActor
package protocol LanguageProviderRuntimeFactory: AnyObject {
    func makeRuntime(for descriptor: LanguageProviderDescriptor) -> (any LanguageProviderRuntime)?
    func makeRuntime(
        for descriptor: LanguageProviderDescriptor,
        languageServerLaunch: LanguageServerLaunchDescriptor,
        ownerModuleID: ModuleID
    ) -> (any LanguageProviderRuntime)?
}

package extension LanguageProviderRuntimeFactory {
    func makeRuntime(
        for descriptor: LanguageProviderDescriptor,
        languageServerLaunch: LanguageServerLaunchDescriptor,
        ownerModuleID: ModuleID
    ) -> (any LanguageProviderRuntime)? {
        makeRuntime(for: descriptor)
    }
}

package extension LanguageProviderRuntime {
    var supportsLanguageServerSession: Bool { false }
    var unavailableToolingMessage: String? { nil }
    func makeLanguageServerSession() -> (any LanguageServerSession)? { nil }
}
