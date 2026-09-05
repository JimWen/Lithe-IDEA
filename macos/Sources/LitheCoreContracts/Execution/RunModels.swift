import Foundation

package struct RunSession: Identifiable, Hashable, Sendable {
    package let id: String
    package let configurationID: String
    package let title: String
    package var output: String
    package var isRunning: Bool
    package var exitCode: Int32?

    package init(
        id: String,
        configurationID: String,
        title: String,
        output: String,
        isRunning: Bool,
        exitCode: Int32? = nil
    ) {
        self.id = id
        self.configurationID = configurationID
        self.title = title
        self.output = output
        self.isRunning = isRunning
        self.exitCode = exitCode
    }
}

package struct RunPortConflict: Identifiable, Hashable, Sendable {
    package let port: Int
    package let configurationNames: [String]

    package init(port: Int, configurationNames: [String]) {
        self.port = port
        self.configurationNames = configurationNames
    }

    package var id: String { String(port) }

    package var title: String {
        "Port \(port) is used by " + configurationNames.joined(separator: ", ")
    }
}

package struct RunConfigurationCapabilities: OptionSet, Hashable, Sendable {
    package let rawValue: Int
    package init(rawValue: Int) { self.rawValue = rawValue }

    package static let workingDirectory = Self(rawValue: 1 << 0)
    package static let arguments = Self(rawValue: 1 << 1)
    package static let environment = Self(rawValue: 1 << 2)
    package static let javaRuntime = Self(rawValue: 1 << 3)
    package static let javaVMArguments = Self(rawValue: 1 << 4)
    package static let jdwpDebug = Self(rawValue: 1 << 6)

    package static let process: Self = [.workingDirectory, .arguments, .environment]
}

package enum RunConfigurationKind: Hashable, Identifiable, Sendable {
    case currentFile
    case javaMain
    /// Any provider this build has no first-class handling for. Carrying the
    /// raw provider keeps unknown ecosystems visible and runnable instead of
    /// silently dropping them at the decode boundary.
    case process(provider: String)


    package init?(rawValue: String) {
        switch rawValue {
        case "currentFile": self = .currentFile
        case "javaMain": self = .javaMain
        default: return nil
        }
    }

    package var id: String {
        switch self {
        case .currentFile: "currentFile"
        case .javaMain: "javaMain"
        case .process(let provider): provider
        }
    }

    package var providerID: String {
        switch self {
        case .currentFile, .javaMain: "java"
        case .process(let provider): provider.split(separator: ".").first.map(String.init) ?? provider
        }
    }

    package var capabilities: RunConfigurationCapabilities {
        switch self {
        case .currentFile, .javaMain:
            return [.workingDirectory, .arguments, .environment, .javaRuntime, .javaVMArguments, .jdwpDebug]
        case .process:
            return .process
        }
    }

    package var title: String {
        switch self {
        case .currentFile: "Current File"
        case .javaMain: "Java Application"
        case .process(let provider): Self.displayTitle(for: provider)
        }
    }

    package var systemImage: String {
        switch self {
        case .currentFile: "doc.text"
        case .javaMain: "cup.and.heat.waves"
        case .process(let provider): Self.symbol(for: provider)
        }
    }

    /// Providers are `namespace.name`. Falling back to a title-cased namespace
    /// means an ecosystem this build has never heard of still reads as a label
    /// rather than as a raw identifier.
    private static func displayTitle(for provider: String) -> String {
        let namespace = provider.split(separator: ".").first.map(String.init) ?? provider
        switch namespace {
        case "npm": return "Node"
        case "compose": return "Docker Compose"
        case "python": return "Python"
        case "go": return "Go"
        case "cargo": return "Rust"
        case "make": return "Make"
        case "just": return "Just"
        case "procfile": return "Procfile"
        default: return namespace.capitalized
        }
    }

    private static func symbol(for provider: String) -> String {
        switch provider.split(separator: ".").first.map(String.init) {
        case "compose": return "square.stack.3d.up"
        case "npm", "python", "go", "cargo": return "chevron.left.forwardslash.chevron.right"
        default: return "terminal"
        }
    }
}

package enum RunConfigurationExecution: String, CaseIterable, Hashable, Sendable {
    case application
    case service
    case task
    case group

    package static let displayOrder: [Self] = [.service, .application, .task, .group]

    package var sectionTitle: String {
        switch self {
        case .application: "Applications"
        case .service: "Services"
        case .task: "Tasks"
        case .group: "Groups"
        }
    }
}

package struct RunConfiguration: Identifiable, Hashable, Sendable {
    package static let currentFileID = "current-file"

    package let id: String
    package let name: String
    package let kind: RunConfigurationKind
    package let execution: RunConfigurationExecution
    package let modulePath: String?
    package let mainClass: String?

    package var usesCurrentEditorFile: Bool { kind == .currentFile }

    package init(
        id: String,
        name: String,
        kind: RunConfigurationKind,
        execution: RunConfigurationExecution? = nil,
        modulePath: String?,
        mainClass: String?
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.execution = execution ?? Self.defaultExecution(for: kind)
        self.modulePath = modulePath
        self.mainClass = mainClass
    }

    package var systemImage: String { kind.systemImage }

    /// Current File is a language-neutral entry. Java keeps its legacy JDK
    /// capability, while other Providers expose only the shared process
    /// fields in the configuration editor.
    package func effectiveCapabilities(
        for currentFileURL: URL?,
        catalog: LanguageProviderCatalog = .compatibilityFallback
    ) -> RunConfigurationCapabilities {
        guard kind == .currentFile else { return kind.capabilities }
        guard let currentFileURL,
              let descriptor = catalog.provider(for: currentFileURL) else {
            // An unknown extension is still a language-neutral Current File
            // entry. Showing JDK controls here would make an unsupported
            // language look like a Java project and leak provider assumptions
            // into the shared editor.
            return .process
        }
        guard descriptor.id == "java" else {
            return .process
        }
        return kind.capabilities
    }

    package static var currentFile: RunConfiguration {
        RunConfiguration(
            id: currentFileID,
            name: "Current File",
            kind: .currentFile,
            execution: .application,
            modulePath: nil,
            mainClass: nil
        )
    }

    private static func defaultExecution(
        for kind: RunConfigurationKind
    ) -> RunConfigurationExecution {
        switch kind {
        case .currentFile, .javaMain, .process: .application
        }
    }
}

// Temporary source compatibility at the Java-debug boundary. These aliases do
// not own behavior; the canonical models above are language neutral.
package typealias JavaRunSession = RunSession
package typealias JavaRunPortConflict = RunPortConflict
package typealias JavaRunConfigurationKind = RunConfigurationKind
package typealias JavaRunConfiguration = RunConfiguration
