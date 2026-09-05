import Foundation

protocol JavaOperations: Sendable {
    func javaWorkspacePolicy(
        at rootURL: URL,
        files: [URL],
        changedFiles: [URL]
    ) -> JavaWorkspacePolicyResult?
    func codeVision(
        at rootURL: URL,
        targetPath: String,
        paths: [String]
    ) -> [JavaCodeVisionValue]
    func className(source: String, simpleName: String) -> String?
    func sourceDefinition(
        source: String,
        declarationName: String,
        memberName: String?
    ) -> (line: Int, utf16Column: Int)?
    func scanRunConfigurations(
        at rootURL: URL,
        files: [URL]
    ) -> [JavaRunConfiguration]
    func structure(
        source: String,
        declarationSources: [String]
    ) -> JavaStructureResult?
}

extension JavaOperations {

    func javaWorkspacePolicy(
        at _: URL,
        files _: [URL],
        changedFiles _: [URL] = []
    ) -> JavaWorkspacePolicyResult? { nil }

}

enum JavaWorkspaceChangeKind: String, Sendable {
    case ignored
    case source
    case buildConfiguration
    case other
}

struct JavaWorkspacePolicyResult: Sendable {
    struct Change: Sendable {
        let url: URL
        let kind: JavaWorkspaceChangeKind
    }

    let shouldStart: Bool
    let representativeJavaURL: URL?
    let changes: [Change]
}

struct JavaStructureResult: Sendable {
    let foldRegions: [JavaFoldRegion]
    let syntaxHighlights: [JavaSyntaxHighlight]
}

struct JavaSyntaxHighlight: Sendable, Equatable {
    let range: NSRange
    let role: String
}

struct JavaCodeVisionValue: Sendable {
    let line: Int
    let utf16Column: Int
    let symbol: String
    let usageCount: Int
}

struct RustJavaOperations: JavaOperations, Sendable {
    let core: RustCoreBridge
    func javaWorkspacePolicy(
        at rootURL: URL,
        files: [URL],
        changedFiles: [URL] = []
    ) -> JavaWorkspacePolicyResult? {
        let root = rootURL.standardizedFileURL
        let workspacePaths = files.compactMap { workspaceRelativePath(for: $0, root: root) }
        let changedPaths = changedFiles.compactMap { workspaceRelativePath(for: $0, root: root) }
        guard let payload = core.javaWorkspacePolicy(
            workspacePaths: workspacePaths,
            changedPaths: changedPaths
        ) else { return nil }
        return JavaWorkspacePolicyResult(
            shouldStart: payload.shouldStart,
            representativeJavaURL: payload.representativeJavaPath.map {
                root.appendingPathComponent($0).standardizedFileURL
            },
            changes: payload.changes.compactMap { change in
                guard let kind = JavaWorkspaceChangeKind(rawValue: change.kind) else { return nil }
                return JavaWorkspacePolicyResult.Change(
                    url: root.appendingPathComponent(change.path).standardizedFileURL,
                    kind: kind
                )
            }
        )
    }




    func codeVision(
        at rootURL: URL,
        targetPath: String,
        paths: [String]
    ) -> [JavaCodeVisionValue] {
        core.javaCodeVision(at: rootURL, targetPath: targetPath, paths: paths)?.hints.map {
            JavaCodeVisionValue(
                line: $0.line,
                utf16Column: $0.utf16Column,
                symbol: $0.symbol,
                usageCount: $0.usageCount
            )
        } ?? []
    }

    func className(source: String, simpleName: String) -> String? {
        core.javaClassName(source: source, simpleName: simpleName)?.className
    }

    func sourceDefinition(
        source: String,
        declarationName: String,
        memberName: String?
    ) -> (line: Int, utf16Column: Int)? {
        guard let value = core.javaSourceDefinition(
            source: source,
            declarationName: declarationName,
            memberName: memberName
        ) else { return nil }
        return (value.line, value.utf16Column)
    }


    func scanRunConfigurations(
        at rootURL: URL,
        files: [URL]
    ) -> [JavaRunConfiguration] {
        let root = rootURL.standardizedFileURL
        let paths = files.compactMap {
            workspaceRelativePath(for: $0, root: root)
        }
        guard let payload = core.scanJavaRunConfigurations(
            at: root,
            paths: paths,
            modulePaths: []
        ) else { return [] }

        return payload.configurations.compactMap { value in
            guard let kind = JavaRunConfigurationKind(rawValue: value.kind) else { return nil }
            return JavaRunConfiguration(
                id: value.id,
                name: value.name,
                kind: kind,
                modulePath: value.modulePath,
                mainClass: value.mainClass
            )
        }
    }


    private func workspaceRelativePath(for url: URL, root: URL) -> String? {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    func structure(
        source: String,
        declarationSources: [String]
    ) -> JavaStructureResult? {
        guard let payload = core.javaStructure(
            source: source,
            declarationSources: declarationSources
        ) else { return nil }
        return JavaStructureResult(
            foldRegions: payload.makeFoldRegions(),
            syntaxHighlights: payload.makeSyntaxHighlights()
        )
    }

}
