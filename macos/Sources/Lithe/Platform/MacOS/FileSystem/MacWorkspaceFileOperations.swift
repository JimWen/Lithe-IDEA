import Foundation

struct MacWorkspaceFileOperations: WorkspaceFileOperations {
    func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func isDirectory(at url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    func createFile(at url: URL) throws {
        try Data().write(to: url, options: .withoutOverwriting)
    }

    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: withIntermediateDirectories
        )
    }

    func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
    }

    func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    func trashItem(at url: URL) throws {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
    }

    func writeText(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func readText(from url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }
}

/// Native file port for the shared edit transaction. It validates the captured
/// bytes and file identity again immediately before each atomic replacement.
struct MacWorkspaceTextEditFileOperations: WorkspaceTextEditFileOperations {
    func capture(_ paths: [String], at workspaceURL: URL) async throws -> [WorkspaceTextEditSnapshot] {
        try paths.sorted().map { path in
            let url = try targetURL(path, in: workspaceURL)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileResourceIdentifierKey, .fileSizeKey, .contentModificationDateKey])
            guard values.isRegularFile == true else { throw CocoaError(.fileReadUnsupportedScheme) }
            let text = try String(contentsOf: url, encoding: .utf8)
            return WorkspaceTextEditSnapshot(path: path, text: text, identity: identity(values))
        }
    }

    func replace(_ edit: WorkspaceTextEdit, expected snapshot: WorkspaceTextEditSnapshot, at workspaceURL: URL) async throws {
        let url = try targetURL(edit.path, in: workspaceURL)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileResourceIdentifierKey, .fileSizeKey, .contentModificationDateKey])
        guard values.isRegularFile == true,
              identity(values) == snapshot.identity,
              snapshot.text.utf8.elementsEqual(edit.sourceText.utf8),
              String(data: try Data(contentsOf: url), encoding: .utf8)?.utf8.elementsEqual(edit.sourceText.utf8) == true else {
            throw NSError(domain: "WorkspaceTextEdit", code: 2, userInfo: [NSLocalizedDescriptionKey: "Workspace file changed before commit"])
        }
        let temporaryURL = url.deletingLastPathComponent().appendingPathComponent(".lithe-edit-\(UUID().uuidString)")
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        try Data(edit.replacementText.utf8).write(to: temporaryURL, options: .completeFileProtectionUnlessOpen)
        do {
            if let permissions = attributes?[.posixPermissions] as? NSNumber {
                try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporaryURL.path)
            }
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporaryURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    func restore(_ snapshot: WorkspaceTextEditSnapshot, at workspaceURL: URL) async throws {
        let url = try targetURL(snapshot.path, in: workspaceURL)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileResourceIdentifierKey, .fileSizeKey, .contentModificationDateKey])
        guard values.isRegularFile == true, identity(values) == snapshot.identity else {
            throw NSError(domain: "WorkspaceTextEdit", code: 3, userInfo: [NSLocalizedDescriptionKey: "Workspace file changed before restore"])
        }
        try Data(snapshot.text.utf8).write(to: url, options: .atomic)
    }

    private func targetURL(_ path: String, in workspaceURL: URL) throws -> URL {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let url = workspaceURL.appendingPathComponent(path).standardizedFileURL
        guard url.path == workspaceURL.standardizedFileURL.path || url.path.hasPrefix(workspaceURL.standardizedFileURL.path + "/") else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        var cursor = workspaceURL.standardizedFileURL
        for component in path.split(separator: "/") {
            cursor.appendPathComponent(String(component))
            if try cursor.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                throw NSError(domain: "WorkspaceTextEdit", code: 4, userInfo: [NSLocalizedDescriptionKey: "Symbolic link targets are not supported"])
            }
        }
        return url
    }

    private func identity(_ values: URLResourceValues) -> String {
        "\(String(describing: values.fileResourceIdentifier)):\(values.fileSize ?? -1):\(values.contentModificationDate?.timeIntervalSince1970 ?? -1)"
    }
}
