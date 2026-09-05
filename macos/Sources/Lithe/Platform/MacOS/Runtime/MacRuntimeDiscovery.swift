import Foundation

enum MacRuntimeDiscovery {
    static func discover(environment: [String: String]) -> RuntimeDiscoveryResult {
        let javaRuntimes = discoverJavaHomes(environment: environment)
            .compactMap(probeJavaHome)
            .sorted { lhs, rhs in
                lhs.version.localizedStandardCompare(rhs.version) == .orderedDescending
            }
        return RuntimeDiscoveryResult(javaRuntimes: javaRuntimes)
    }



    static func validJavaHome(_ path: String) -> URL? {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        return FileManager.default.isExecutableFile(atPath: url.appendingPathComponent("bin/java").path)
            ? url
            : nil
    }

    private static func discoverJavaHomes(environment: [String: String]) -> [URL] {
        var paths: [String: URL] = [:]
        func add(_ path: String?) {
            guard let path,
                  let home = validJavaHome(path) else { return }
            let identity = home.resolvingSymlinksInPath().path
            if paths[identity] == nil {
                paths[identity] = home
            }
        }

        add(environment["JAVA_HOME"])
        for path in javaHomeOutput() {
            add(path)
        }

        for root in [
            "/Library/Java/JavaVirtualMachines",
            NSHomeDirectory() + "/Library/Java/JavaVirtualMachines"
        ] {
            for entry in directoryNames(at: root) {
                add(root + "/" + entry + "/Contents/Home")
            }
        }

        for root in ["/opt/homebrew/opt", "/usr/local/opt"] {
            for entry in directoryNames(at: root) where entry.hasPrefix("openjdk") {
                add(root + "/" + entry + "/libexec/openjdk.jdk/Contents/Home")
            }
        }

        return paths.values.sorted { $0.path < $1.path }
    }


    static func probeJavaHome(_ home: URL) -> JavaRuntimeCandidate? {
        let output = commandOutput(
            executable: home.appendingPathComponent("bin/java"),
            arguments: ["-version"]
        )
        guard let version = firstCapture(pattern: #"version\s+\"([^\"]+)\""#, in: output) else {
            return nil
        }
        let vendor = output
            .split(separator: "\n")
            .map(String.init)
            .first(where: { $0.contains("Runtime Environment") || $0.contains("VM") })?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return JavaRuntimeCandidate(homePath: home.path, version: version, vendor: vendor)
    }


    private static func javaHomeOutput() -> [String] {
        let output = commandOutput(
            executable: URL(fileURLWithPath: "/usr/libexec/java_home"),
            arguments: ["-V"]
        )
        return output
            .split(separator: "\n")
            .compactMap { line in
                firstCapture(pattern: #"(\/[^\s]+\/Contents\/Home)"#, in: String(line))
            }
    }

    private static func directoryNames(at path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }

    private static func commandOutput(executable: URL, arguments: [String]) -> String {
        MacProcessRunner().run(ProcessRequest(
            executablePath: executable.path,
            arguments: arguments,
            timeoutMilliseconds: 5_000
        )).output
    }

    private static func firstCapture(pattern: String, in input: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: input,
                  range: NSRange(input.startIndex..<input.endIndex, in: input)
              ),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: input) else { return nil }
        return String(input[range])
    }
}
