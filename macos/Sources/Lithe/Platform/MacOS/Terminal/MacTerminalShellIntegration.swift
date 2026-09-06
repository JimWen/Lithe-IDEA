import Foundation
import LitheTerminalModule

/// Fixed scripts receive paths only through environment values, never through
/// shell source interpolation or terminal input. The original snapshot is kept
/// separate from this per-process environment.
enum MacTerminalShellIntegration {
    static let oscCode = 6973
    static let acknowledgmentTimeout: TimeInterval = 5
    static let maximumPayloadBytes = 160
    enum Shell { case zsh, bash }

    static func shell(for launch: TerminalProcessLaunch) -> Shell? {
        let name = URL(fileURLWithPath: launch.executablePath).lastPathComponent
        guard name == "zsh" || name == "bash", launch.arguments.allSatisfy({ argument in
            if argument == "--login" { return true }
            return argument.hasPrefix("-") && argument.count > 1
                && argument.dropFirst().allSatisfy { $0 == "i" || $0 == "l" }
        }) else { return nil }
        return name == "zsh" ? .zsh : .bash
    }

    static var directory: URL? {
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent("Lithe_Lithe.bundle"),
                          Bundle.main.bundleURL.appendingPathComponent("Lithe_Lithe.bundle")]
        let bundle = candidates.compactMap { $0.flatMap(Bundle.init(url:)) }.first ?? Bundle.module
        return bundle.resourceURL?.appendingPathComponent("TerminalShellIntegration", isDirectory: true)
    }

    static func prepare(_ launch: TerminalShellLaunch, path: String, nonce: String,
                        resources: URL?) -> (process: TerminalProcessLaunch, environment: [String: String])? {
        guard let shell = shell(for: launch.process), let resources,
              ["exec.sh", "activate.sh", "bash.sh", "zsh/.zshenv", "zsh/.zprofile", "zsh/.zshrc", "zsh/.zlogin"]
                .allSatisfy({ FileManager.default.isReadableFile(atPath: resources.appendingPathComponent($0).path) }) else { return nil }
        var environment = launch.environment
        // Clear values inherited from another terminal integration generation.
        for key in environment.keys where key.hasPrefix("LITHE_VENV_") { environment[key] = nil }
        environment["LITHE_VENV_PATH"] = path
        environment["LITHE_VENV_NONCE"] = nonce
        environment["LITHE_VENV_OSC"] = String(oscCode)
        environment["LITHE_VENV_RESOURCES"] = resources.path
        switch shell {
        case .zsh:
            environment["LITHE_VENV_ZDOTDIR_SET"] = environment["ZDOTDIR"] == nil ? "0" : "1"
            environment["LITHE_VENV_ZDOTDIR"] = environment["ZDOTDIR"] ?? ""
            environment["ZDOTDIR"] = resources.appendingPathComponent("zsh").path
        case .bash:
            environment["LITHE_VENV_PROMPT_SET"] = environment["PROMPT_COMMAND"] == nil ? "0" : "1"
            environment["LITHE_VENV_PROMPT"] = environment["PROMPT_COMMAND"] ?? ""
            let previous = environment["PROMPT_COMMAND"].map { $0.isEmpty ? "" : $0 + "\n" } ?? ""
            let prompt = previous + #"builtin source "$LITHE_VENV_RESOURCES/bash.sh""#
            environment["PROMPT_COMMAND"] = prompt
            environment["LITHE_VENV_EXPECTED_PROMPT"] = prompt
        }
        return (.init(title: launch.process.title, executablePath: "/bin/sh",
                      arguments: [resources.appendingPathComponent("exec.sh").path,
                                  launch.process.executablePath] + launch.process.arguments,
                      workingDirectory: launch.process.workingDirectory), environment)
    }
}
