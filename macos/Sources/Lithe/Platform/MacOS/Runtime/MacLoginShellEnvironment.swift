import Darwin
import Foundation

/// Resolves safe developer toolchain and cache environment variables from the
/// user's interactive login shell and `go env` config file when Lithe is
/// launched from Finder/Dock/Spotlight without shell startup files.
///
/// The probe runs at most once per process on a background utility queue with a
/// bounded timeout and managed process-group cleanup, never blocking MainActor
/// and never running during automated test runs or terminal launches that
/// already inherit a shell environment.
final class MacLoginShellEnvironmentCache: @unchecked Sendable {
    static let shared = MacLoginShellEnvironmentCache()

    static let startMarker = "__LITHE_ENV_START__"
    static let endMarker = "__LITHE_ENV_END__"

    /// Toolchain, path, cache, and locale variables safe to inherit from a user
    /// login shell. Read-only metadata preparers still apply their own strict
    /// allowlists and override flags (`GOENV=off`, `GOPROXY=off`, etc.).
    static let allowedShellKeys: Set<String> = [
        "PATH",
        "GOPATH", "GOMODCACHE", "GOCACHE", "GOROOT", "GOBIN",
        "GOPROXY", "GOPRIVATE", "GONOSUMDB", "GONOPROXY",
        "CARGO_HOME", "RUSTUP_HOME", "RUSTUP_TOOLCHAIN",
        "VIRTUAL_ENV", "PYENV_ROOT", "NVM_DIR", "VOLTA_HOME",
        "LANG", "LC_ALL", "LC_CTYPE", "SSL_CERT_FILE", "SSL_CERT_DIR"
    ]

    /// Path-only keys read from `~/Library/Application Support/go/env` (`go env -w`).
    /// Proxy and flag keys are deliberately excluded so `go/env` never bypasses
    /// offline or read-only overrides.
    static let allowedGoEnvFileKeys: Set<String> = [
        "GOPATH", "GOMODCACHE", "GOCACHE", "GOROOT"
    ]

    private static let allowedShellNames: Set<String> = ["zsh", "bash", "sh"]
    private static let defaultTimeoutMilliseconds = 3_000

    private let lock = NSLock()
    private let probe: @Sendable () -> [String: String]
    private let shouldProbe: @Sendable () -> Bool
    private var started = false
    private var completed = false
    private var values: [String: String] = [:]
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(
        shouldProbe: @escaping @Sendable () -> Bool = { MacLoginShellEnvironmentCache.defaultShouldProbe() },
        probe: @escaping @Sendable () -> [String: String] = { MacLoginShellEnvironmentCache.defaultProbe() }
    ) {
        self.shouldProbe = shouldProbe
        self.probe = probe
    }

    func warmUpIfNeeded() {
        let needsStart = lock.withLock { () -> Bool in
            guard !started else { return false }
            started = true
            if !shouldProbe() {
                completed = true
                return false
            }
            return true
        }
        guard needsStart else { return }
        DispatchQueue.global(qos: .utility).async { [self] in
            let resolved = probe()
            let pendingWaiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                values = resolved
                completed = true
                let list = waiters
                waiters.removeAll()
                return list
            }
            for waiter in pendingWaiters {
                waiter.resume()
            }
        }
    }

    /// Non-blocking snapshot of whatever shell variables have resolved so far.
    func cachedEnvironment() -> [String: String] {
        warmUpIfNeeded()
        return lock.withLock { values }
    }

    /// Awaits completion of the one-shot bounded probe without blocking MainActor.
    func awaitReady() async {
        warmUpIfNeeded()
        await withCheckedContinuation { continuation in
            let alreadyDone = lock.withLock { () -> Bool in
                if completed { return true }
                waiters.append(continuation)
                return false
            }
            if alreadyDone {
                continuation.resume()
            }
        }
    }

    /// Parses NUL-delimited `KEY=VALUE` entries framed between `startMarker` and
    /// `endMarker`, discarding any interactive shell startup banners or MOTD.
    static func parseFramedEnvironment(_ output: String) -> [String: String] {
        let startToken = startMarker + "\0"
        let endToken = endMarker + "\0"
        guard let startRange = output.range(of: startToken),
              let endRange = output.range(of: endToken, range: startRange.upperBound..<output.endIndex) else {
            return [:]
        }
        let body = output[startRange.upperBound..<endRange.lowerBound]
        var result: [String: String] = [:]
        for entry in body.split(separator: "\0", omittingEmptySubsequences: true) {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[..<equals])
            let value = String(entry[entry.index(after: equals)...])
            guard allowedShellKeys.contains(key),
                  !value.isEmpty,
                  !value.contains("\0") else { continue }
            result[key] = value
        }
        return result
    }

    /// Reads safe Go path keys (`GOPATH`, `GOMODCACHE`, `GOCACHE`, `GOROOT`)
    /// from Go's user env file (`~/Library/Application Support/go/env`).
    static func parseGoEnvFile(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"),
                  let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            guard allowedGoEnvFileKeys.contains(key) else { continue }
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               ((value.hasPrefix("\"") && value.hasSuffix("\""))
                || (value.hasPrefix("'") && value.hasSuffix("'"))) {
                value = String(value.dropFirst().dropLast())
            }
            guard !value.isEmpty, !value.contains("\0") else { continue }
            result[key] = value
        }
        return result
    }

    static func goEnvFileURL(
        environment: [String: String],
        homeDirectoryURL: URL
    ) -> URL {
        if let explicit = environment["GOENV"],
           !explicit.isEmpty,
           explicit != "off" {
            return URL(fileURLWithPath: explicit).standardizedFileURL
        }
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg)
                .appendingPathComponent("go/env")
                .standardizedFileURL
        }
        return homeDirectoryURL
            .appendingPathComponent("Library/Application Support/go/env")
            .standardizedFileURL
    }

    private static func defaultShouldProbe() -> Bool {
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil
            || env["XCTestBundlePath"] != nil
            || env["LITHE_DISABLE_LOGIN_SHELL_ENV"] == "1" {
            return false
        }
        // Terminal-launched processes already inherit the user's shell exports.
        if env["SHLVL"] != nil {
            return false
        }
        return true
    }

    private static func defaultProbe() -> [String: String] {
        let shellPath = resolveLoginShellPath()
        let command = "printf '\(startMarker)\\0'; /usr/bin/env -0 2>/dev/null; printf '\(endMarker)\\0'"
        var requestEnv = ProcessInfo.processInfo.environment
        requestEnv["TERM"] = "dumb"
        let result = MacProcessRunner().run(ProcessRequest(
            operationID: "login-shell-env-\(UUID().uuidString)",
            executablePath: shellPath,
            arguments: ["-l", "-i", "-c", command],
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
            environment: requestEnv,
            timeoutMilliseconds: defaultTimeoutMilliseconds
        ))
        guard result.exitCode == 0 else { return [:] }
        return parseFramedEnvironment(result.output)
    }

    private static func resolveLoginShellPath() -> String {
        var candidates: [String] = []
        if let pw = getpwuid(getuid()), let shellCString = pw.pointee.pw_shell {
            candidates.append(String(cString: shellCString))
        }
        if let envShell = ProcessInfo.processInfo.environment["SHELL"], !envShell.isEmpty {
            candidates.append(envShell)
        }
        candidates.append("/bin/zsh")
        for candidate in candidates {
            let name = URL(fileURLWithPath: candidate).lastPathComponent
            if allowedShellNames.contains(name),
               FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return "/bin/zsh"
    }
}
