import Foundation
import LitheCoreContracts

/// Selects the source file that anchors a Debug launch without making the
/// selected Run configuration depend on whichever editor tab is currently open.
struct DebugLaunchSourceResolver {
    /// Chooses a project-backed Java target when the remembered Current File
    /// entry cannot represent a launchable Java application. IDEA keeps the
    /// editor shortcut useful in this situation instead of trying to compile
    /// an arbitrary controller, repository, or configuration class alone.
    func configurationForDebug(
        selected: RunConfiguration,
        activeDocumentText: String?,
        configurations: [RunConfiguration],
        activeDocumentURL: URL? = nil
    ) -> RunConfiguration {
        guard selected.usesCurrentEditorFile else {
            return selected
        }
        // Only redirect a non-main Java file to a project `.javaMain` target.
        // Non-Java files (Go, Rust, Python, Node) must keep `.currentFile` so
        // debugging launches their own language adapter instead of Java.
        if let ext = activeDocumentURL?.pathExtension.lowercased(),
           !ext.isEmpty, ext != "java" {
            return selected
        }
        if activeDocumentText.map(containsJavaMainMethod) == true {
            return selected
        }

        return configurations.first {
            !$0.usesCurrentEditorFile && $0.kind == .javaMain
                && $0.kind.capabilities.contains(.jdwpDebug)
        } ?? selected
    }

    func resolve(
        configuration: RunConfiguration,
        activeDocumentURL: URL?,
        projectFiles: [URL],
        workspaceURL: URL
    ) -> URL? {
        if configuration.usesCurrentEditorFile {
            return activeDocumentURL?.standardizedFileURL
        }

        switch configuration.kind.languageID {
        case "java":
            return resolveJava(
                configuration: configuration,
                activeDocumentURL: activeDocumentURL,
                projectFiles: projectFiles,
                workspaceURL: workspaceURL
            )
        case "go":
            return resolveLanguageSource(
                extensions: ["go"],
                preferredFileNames: ["main.go"],
                configuration: configuration,
                activeDocumentURL: activeDocumentURL,
                projectFiles: projectFiles,
                workspaceURL: workspaceURL
            )
        case "rust":
            return resolveLanguageSource(
                extensions: ["rs"],
                preferredFileNames: ["\(configuration.name).rs", "main.rs"],
                configuration: configuration,
                activeDocumentURL: activeDocumentURL,
                projectFiles: projectFiles,
                workspaceURL: workspaceURL
            )
        case "python":
            return resolveLanguageSource(
                extensions: ["py", "pyw"],
                preferredFileNames: [
                    configuration.name,
                    "\(configuration.name).py",
                    "main.py",
                    "app.py"
                ],
                configuration: configuration,
                activeDocumentURL: activeDocumentURL,
                projectFiles: projectFiles,
                workspaceURL: workspaceURL
            )
        case "node":
            return resolveLanguageSource(
                extensions: ["ts", "tsx", "js", "jsx", "mjs", "cjs"],
                preferredFileNames: ["index.ts", "index.js", "server.ts", "server.js", "main.ts", "main.js"],
                configuration: configuration,
                activeDocumentURL: activeDocumentURL,
                projectFiles: projectFiles,
                workspaceURL: workspaceURL
            )
        default:
            return nil
        }
    }

    private func resolveJava(
        configuration: RunConfiguration,
        activeDocumentURL: URL?,
        projectFiles: [URL],
        workspaceURL: URL
    ) -> URL? {
        let javaFiles = projectFiles
            .map(\.standardizedFileURL)
            .filter { $0.pathExtension.lowercased() == "java" }
            .sorted { $0.path < $1.path }
        guard !javaFiles.isEmpty else { return nil }

        let moduleFiles = filesInSelectedModule(
            javaFiles,
            modulePath: configuration.modulePath,
            workspaceURL: workspaceURL
        )
        let preferredFiles = moduleFiles.isEmpty ? javaFiles : moduleFiles

        if let sourceSuffix = sourceSuffix(for: configuration.mainClass),
           let exactMatch = preferredFiles.first(where: { $0.path.hasSuffix(sourceSuffix) })
                ?? javaFiles.first(where: { $0.path.hasSuffix(sourceSuffix) }) {
            return exactMatch
        }

        if let activeDocumentURL = activeDocumentURL?.standardizedFileURL,
           preferredFiles.contains(activeDocumentURL) {
            return activeDocumentURL
        }
        return preferredFiles.first
    }

    private func resolveLanguageSource(
        extensions: Set<String>,
        preferredFileNames: [String],
        configuration: RunConfiguration,
        activeDocumentURL: URL?,
        projectFiles: [URL],
        workspaceURL: URL
    ) -> URL? {
        let matchingFiles = projectFiles
            .map(\.standardizedFileURL)
            .filter { extensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.path < $1.path }
        if let active = activeDocumentURL?.standardizedFileURL,
           extensions.contains(active.pathExtension.lowercased()) {
            let scoped = filesInSelectedModule([active], modulePath: configuration.modulePath, workspaceURL: workspaceURL)
            if !scoped.isEmpty || matchingFiles.isEmpty {
                return active
            }
        }
        guard !matchingFiles.isEmpty else { return nil }
        let moduleFiles = filesInSelectedModule(
            matchingFiles,
            modulePath: configuration.modulePath,
            workspaceURL: workspaceURL
        )
        let preferredFiles = moduleFiles.isEmpty ? matchingFiles : moduleFiles
        for fileName in preferredFileNames {
            if let hit = preferredFiles.first(where: { $0.lastPathComponent == fileName }) {
                return hit
            }
        }
        return preferredFiles.first
    }

    private func filesInSelectedModule(
        _ files: [URL],
        modulePath: String?,
        workspaceURL: URL
    ) -> [URL] {
        guard let modulePath = modulePath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !modulePath.isEmpty,
              modulePath != "." else { return files }
        let moduleURL = workspaceURL
            .appendingPathComponent(modulePath, isDirectory: true)
            .standardizedFileURL
        let modulePrefix = moduleURL.path.hasSuffix("/") ? moduleURL.path : moduleURL.path + "/"
        return files.filter { $0.path.hasPrefix(modulePrefix) }
    }

    private func sourceSuffix(for mainClass: String?) -> String? {
        guard var mainClass = mainClass?.trimmingCharacters(in: .whitespacesAndNewlines),
              !mainClass.isEmpty else { return nil }
        if let moduleSeparator = mainClass.lastIndex(of: "/") {
            mainClass = String(mainClass[mainClass.index(after: moduleSeparator)...])
        }
        if let nestedClassSeparator = mainClass.firstIndex(of: "$") {
            mainClass = String(mainClass[..<nestedClassSeparator])
        }
        guard !mainClass.isEmpty else { return nil }
        return "/" + mainClass.replacingOccurrences(of: ".", with: "/") + ".java"
    }

    private func containsJavaMainMethod(_ source: String) -> Bool {
        source.range(
            of: #"(?m)\bstatic\s+(?:public\s+|protected\s+|private\s+)?void\s+main\s*\("#,
            options: .regularExpression
        ) != nil
    }
}
