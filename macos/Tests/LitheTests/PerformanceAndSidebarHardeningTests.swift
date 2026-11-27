import Foundation
import LitheCoreContracts
import LitheGitModule
import Testing
@testable import Lithe

@Suite("Performance, Sidebar Icons, and Hardening Regressions")
@MainActor
struct PerformanceAndSidebarHardeningTests {
    @Test
    func allLeftSidebarAndTerminalIconsMapToBundledJetBrainsAlignedSVGs() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let iconsRoot = repoRoot.appendingPathComponent("macos/Resources/IDEAIcons", isDirectory: true)

        for destination in SidebarDestination.allCases {
            let assetPath = try #require(
                destination.ideaAssetPath,
                "SidebarDestination.\(destination.rawValue) must specify a JetBrains-aligned SVG asset"
            )
            let fileURL = iconsRoot.appendingPathComponent(assetPath)
            #expect(FileManager.default.fileExists(atPath: fileURL.path), "Missing SVG \(assetPath)")
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            #expect(content.contains("<svg"), "Invalid SVG content in \(assetPath)")
        }

        for extraAsset in ["toolwindows/toolWindowTerminal.svg", "vcs/branch.svg"] {
            let fileURL = iconsRoot.appendingPathComponent(extraAsset)
            #expect(FileManager.default.fileExists(atPath: fileURL.path), "Missing SVG \(extraAsset)")
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            #expect(content.contains("<svg"), "Invalid SVG content in \(extraAsset)")
        }

        // Verify vcs/branch.svg renders a branch topology (circles + path) rather than a text document.
        let branchSVG = try String(
            contentsOf: iconsRoot.appendingPathComponent("vcs/branch.svg"),
            encoding: .utf8
        )
        #expect(branchSVG.contains("<circle"))
        #expect(branchSVG.contains("<path"))
    }

    @Test
    func gitChangeSelectionClickedTargetMatchesByValueWhenStagedDeletionAndUntrackedSharePath() {
        let repo = URL(fileURLWithPath: "/tmp/repo")
        let stagedDeletion = GitChange(
            repositoryRoot: repo,
            path: ".env",
            originalPath: nil,
            indexStatus: "D",
            workTreeStatus: " "
        )
        let untrackedReplacement = GitChange(
            repositoryRoot: repo,
            path: ".env",
            originalPath: nil,
            indexStatus: "?",
            workTreeStatus: "?"
        )
        #expect(stagedDeletion.id == untrackedReplacement.id)

        let selection = GitChangeSelection()
        let targets = selection.actionTargets(
            in: [stagedDeletion, untrackedReplacement],
            clicked: stagedDeletion
        )
        #expect(targets == [stagedDeletion])
    }

    @Test
    func importedAIConfigurationsUseDistinctKeyIdentifiersPerSource() {
        let settings = AppSettings(store: HardeningTestKeyValueStore())

        let codexProfile = settings.importAIConfiguration(AIConfigurationSnapshot(
            source: .codex,
            providerName: "Codex",
            endpoint: "https://api.openai.com/v1",
            model: "gpt-5.4",
            apiProtocol: .responses,
            authentication: .bearer,
            reasoningEffort: nil,
            requiresAPIKey: true,
            apiKey: nil
        ))
        let claudeProfile = settings.importAIConfiguration(AIConfigurationSnapshot(
            source: .claude,
            providerName: "Claude",
            endpoint: "https://api.anthropic.com/v1",
            model: "sonnet",
            apiProtocol: .anthropicMessages,
            authentication: .apiKey,
            reasoningEffort: nil,
            requiresAPIKey: true,
            apiKey: nil
        ))

        #expect(codexProfile.apiKeyIdentifier == "lithe.codex.imported.apiKey")
        #expect(claudeProfile.apiKeyIdentifier == "lithe.claude.imported.apiKey")
        #expect(codexProfile.apiKeyIdentifier != claudeProfile.apiKeyIdentifier)
        #expect(settings.commitMessageAI.providers.count >= 2)
    }

    @Test
    func textEditApplicatorAppliesManyEditsAcrossLargeFileUsingLinearLineIndex() throws {
        let lines = (0..<1_500).map { "line_\($0) = value_\($0)" }
        let source = lines.joined(separator: "\n")
        let edits: [LanguageServerTextEdit] = stride(from: 0, to: 1_500, by: 3).map { line in
            let prefix = "line_\(line) = "
            let oldValue = "value_\(line)"
            return LanguageServerTextEdit(
                range: LanguageServerRange(
                    start: LanguageServerPosition(line: line, utf16Column: prefix.utf16.count),
                    end: LanguageServerPosition(line: line, utf16Column: (prefix + oldValue).utf16.count)
                ),
                newText: "updated_\(line)"
            )
        }

        let updated = try LanguageServerTextEditApplicator.apply(edits, to: source)
        #expect(updated.contains("line_0 = updated_0"))
        #expect(updated.contains("line_1 = value_1"))
        #expect(updated.contains("line_1497 = updated_1497"))
    }

    @Test
    func frameRateMonitorStopIsSafeAndIdempotent() {
        let monitor = FrameRateMonitor()
        monitor.stop()
        monitor.stop()
        #expect(monitor.framesPerSecond == 0)
    }
}

private final class HardeningTestKeyValueStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
