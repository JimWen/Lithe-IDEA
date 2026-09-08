import Foundation
import LitheCoreContracts
import LitheExecutionModule
import Testing
@testable import Lithe

struct ProjectToolTaskPreparationTests {
    @Test func usesSelectedGoCompanionAndContainedDirectoryWithoutShell() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let task = try fixture.prepare(directory: "space package", executable: .companion("gofmt"))
        #expect(task.request.executablePath == fixture.bin.appendingPathComponent("gofmt").path)
        #expect(task.request.arguments == ["-l", "."])
        #expect(task.request.workingDirectory == fixture.root.appendingPathComponent("space package").path)
        try task.validate()
        // A normal directory content update does not replace its identity.
        try Data("package main".utf8).write(to: fixture.root.appendingPathComponent("space package/new.go"))
        try task.validate()
    }

    @Test func rejectsOutsideSymlinkAndDirectoryRetargetedAfterPreparation() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let link = fixture.root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.root.appendingPathComponent("space package"))
        let task = try fixture.prepare(directory: "linked")
        try task.validate()
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.bin)
        #expect(throws: (any Error).self) { try task.validate() }
        #expect(throws: (any Error).self) { try fixture.prepare(directory: "linked") }
    }

    @Test func rejectsToolReplacementAndScriptShimWithoutExecutingAnything() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let task = try fixture.prepare(directory: ".")
        try FileManager.default.removeItem(at: fixture.bin.appendingPathComponent("go"))
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: fixture.bin.appendingPathComponent("go"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.bin.appendingPathComponent("go").path)
        #expect(throws: (any Error).self) { try task.validate() }
        #expect(throws: (any Error).self) { try fixture.prepare(directory: ".") }
    }

    private struct Fixture {
        let container: URL
        let root: URL
        let bin: URL
        init() throws {
            container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
            root = container.appendingPathComponent("workspace")
            bin = container.appendingPathComponent("toolchain")
            do {
                try FileManager.default.createDirectory(at: root.appendingPathComponent("space package"), withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
                // Only the native preparer's header check runs, never a process.
                for name in ["go", "gofmt"] {
                    let url = bin.appendingPathComponent(name)
                    try Data([0xCF, 0xFA, 0xED, 0xFE]).write(to: url)
                    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
                }
            } catch {
                do { try FileManager.default.removeItem(at: container) }
                catch { Issue.record("Fixture cleanup failed: \(error)") }
                throw error
            }
        }
        func prepare(directory: String, executable: ProjectToolExecutable = .languageToolchain) throws -> PreparedProjectToolTask {
            try MacProjectToolTaskPreparer.prepare(owner: .init(workspaceURL: root, workspaceGeneration: 1, providerGeneration: 0),
                plan: .init(title: "Check Formatting", executable: executable, arguments: ["-l", "."],
                    workingDirectory: directory, diagnosticSource: "go-tool"), id: UUID(),
                candidates: [bin.appendingPathComponent("go")], environment: [:])
        }
        func cleanup() {
            do { try FileManager.default.removeItem(at: container) }
            catch { Issue.record("Fixture cleanup failed: \(error)") }
        }
    }
}
