import Foundation

public enum TerminalShellSelection: String, Codable, CaseIterable, Sendable {
    case system, zsh, bash, custom
}

public enum TerminalWorkingDirectory: String, Codable, CaseIterable, Sendable {
    case currentProject, currentFile, firstProject, home, custom
}

/// User preferences only. The inherited process environment is never persisted.
public struct TerminalShellConfiguration: Codable, Equatable, Sendable {
    public static let maximumArguments = 128
    public static let maximumEnvironmentVariables = 128
    public static let maximumTextBytes = 256 * 1_024

    public var shell: TerminalShellSelection = .system
    public var customProgram = ""
    public var arguments: [String] = []
    public var loginShell = true
    public var workingDirectory: TerminalWorkingDirectory = .currentProject
    public var customDirectory = ""
    public var environment: [TerminalEnvironmentChange] = []

    public init() {}

    private enum CodingKeys: CodingKey {
        case shell, customProgram, arguments, loginShell, workingDirectory, customDirectory, environment
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        shell = try values.decodeIfPresent(TerminalShellSelection.self, forKey: .shell) ?? .system
        customProgram = try values.decodeIfPresent(String.self, forKey: .customProgram) ?? ""
        arguments = try values.decodeIfPresent([String].self, forKey: .arguments) ?? []
        loginShell = try values.decodeIfPresent(Bool.self, forKey: .loginShell) ?? true
        workingDirectory = try values.decodeIfPresent(TerminalWorkingDirectory.self, forKey: .workingDirectory) ?? .currentProject
        customDirectory = try values.decodeIfPresent(String.self, forKey: .customDirectory) ?? ""
        environment = try values.decodeIfPresent([TerminalEnvironmentChange].self, forKey: .environment) ?? []
    }

    public var specifiedShellPath: String? {
        switch shell {
        case .system: nil
        case .zsh: "/bin/zsh"
        case .bash: "/bin/bash"
        case .custom: customProgram
        }
    }

    /// Validation never includes argument or environment contents in its errors.
    public func validate() throws {
        if shell == .custom && customProgram.isEmpty { throw TerminalConfigurationError.missingProgram }
        if workingDirectory == .custom && customDirectory.isEmpty { throw TerminalConfigurationError.missingDirectory }
        guard arguments.count <= Self.maximumArguments,
              environment.count <= Self.maximumEnvironmentVariables else {
            throw TerminalConfigurationError.tooManyEntries
        }
        let text = [customProgram, customDirectory] + arguments
            + environment.flatMap { [$0.name, $0.value ?? ""] }
        guard !text.contains(where: { $0.utf8.contains(0) }) else { throw TerminalConfigurationError.nullCharacter }
        guard text.reduce(0, { $0 + $1.utf8.count }) <= Self.maximumTextBytes else {
            throw TerminalConfigurationError.tooMuchText
        }
        var names = Set<String>()
        for variable in environment {
            guard Self.isEnvironmentName(variable.name) else { throw TerminalConfigurationError.invalidEnvironmentName }
            guard names.insert(variable.name).inserted else { throw TerminalConfigurationError.duplicateEnvironmentName }
        }
    }

    public var validationMessage: String? {
        do { try validate(); return nil }
        catch { return error.localizedDescription }
    }

    /// Pure planning; the platform validates and resolves native file targets.
    public func launchPlan(
        context: TerminalLaunchContext,
        systemShell: String,
        homeDirectory: URL,
        inheritedEnvironment: [String: String]
    ) throws -> TerminalShellLaunch {
        try validate()
        let directory: URL
        switch workingDirectory {
        case .currentFile:
            directory = context.currentFileURL?.deletingLastPathComponent()
                ?? context.projectURL ?? context.firstProjectURL ?? homeDirectory
        case .currentProject:
            directory = context.projectURL ?? context.firstProjectURL ?? homeDirectory
        case .firstProject:
            directory = context.firstProjectURL ?? context.projectURL ?? homeDirectory
        case .home:
            directory = homeDirectory
        case .custom:
            directory = Self.resolveDirectory(customDirectory, relativeTo: context.projectURL ?? context.firstProjectURL ?? homeDirectory, home: homeDirectory)
        }
        var program = specifiedShellPath ?? systemShell
        if program == "~" { program = homeDirectory.path }
        else if program.hasPrefix("~/") {
            program = homeDirectory.appendingPathComponent(String(program.dropFirst(2))).path
        }
        guard !program.isEmpty, !program.utf8.contains(0) else { throw TerminalConfigurationError.missingProgram }
        var argv = arguments
        // A trailing login flag could become a script or `-c` argument.
        if loginShell && argv.first != "-l" && argv.first != "--login" { argv.insert("-l", at: 0) }
        var values = inheritedEnvironment
        values["TERM"] = "xterm-256color"
        values["COLORTERM"] = "truecolor"
        values["TERM_PROGRAM"] = "Lithe"
        for change in environment { values[change.name] = change.value }
        return TerminalShellLaunch(
            process: TerminalProcessLaunch(title: nil, executablePath: program, arguments: argv, workingDirectory: directory.standardizedFileURL.path),
            environment: values
        )
    }

    private static func resolveDirectory(_ path: String, relativeTo root: URL, home: URL) -> URL {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home.appendingPathComponent(String(path.dropFirst(2)), isDirectory: true) }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path, isDirectory: true) }
        return root.appendingPathComponent(path, isDirectory: true)
    }

    private static func isEnvironmentName(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        func isLetter(_ byte: UInt8) -> Bool { (65...90).contains(byte) || (97...122).contains(byte) || byte == 95 }
        guard let first = bytes.first, isLetter(first) else { return false }
        return bytes.dropFirst().allSatisfy { isLetter($0) || (48...57).contains($0) }
    }
}

public struct TerminalLaunchContext: Equatable, Sendable {
    public let projectURL: URL?
    public let firstProjectURL: URL?
    public let currentFileURL: URL?

    public init(projectURL: URL?, firstProjectURL: URL? = nil, currentFileURL: URL? = nil) {
        self.projectURL = projectURL
        self.firstProjectURL = firstProjectURL
        self.currentFileURL = currentFileURL?.isFileURL == true ? currentFileURL : nil
    }
}

/// Memory-only launch snapshot, including the environment inherited at creation.
public struct TerminalShellLaunch: Equatable, Sendable {
    public let process: TerminalProcessLaunch
    public let environment: [String: String]

    public init(process: TerminalProcessLaunch, environment: [String: String]) {
        self.process = process
        self.environment = environment
    }
}

public enum TerminalConfigurationError: LocalizedError, Sendable {
    case missingProgram, missingDirectory, invalidEnvironmentName, duplicateEnvironmentName
    case nullCharacter, tooManyEntries, tooMuchText

    public var errorDescription: String? {
        switch self {
        case .missingProgram: "Choose a terminal shell program."
        case .missingDirectory: "Choose a terminal working directory."
        case .invalidEnvironmentName: "Environment names must start with a letter or underscore and contain only letters, digits and underscores."
        case .duplicateEnvironmentName: "Each terminal environment name must be unique."
        case .nullCharacter: "Terminal settings cannot contain a NUL character."
        case .tooManyEntries: "Terminal settings allow at most 128 arguments and 128 environment variables."
        case .tooMuchText: "Terminal settings exceed the 256 KiB text limit."
        }
    }
}
