import Foundation
import Testing
@testable import Lithe

@Suite("Workbench rendering safety")
struct WorkbenchRenderingSafetyTests {
    @Test
    func dockedToolPreservesEditorSpaceAtMinimumWindowWidth() {
        // The old overlay hid Run controls. At the 980-point minimum, reserve
        // both 40-point activity bars and 640 points for the tree/editor.
        #expect(WorkbenchLayoutMetrics.dockedToolWidth(availableWidth: 980, preferredWidth: 380) == 260)
        #expect(WorkbenchLayoutMetrics.dockedToolWidth(availableWidth: 1440, preferredWidth: 380) == 380)
        #expect(WorkbenchLayoutMetrics.dockedToolWidth(availableWidth: 980, preferredWidth: 9999) == 260)
        #expect(WorkbenchLayoutMetrics.dockedToolWidth(availableWidth: 1440, preferredWidth: -1) == 240)
        #expect(WorkbenchLayoutMetrics.dockedToolWidth(availableWidth: 0, preferredWidth: 380) == 0)
    }

    @Test
    func workbenchDoesNotFlattenPlatformBackedViews() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let workbenchURL = repositoryRoot.appendingPathComponent(
            "Sources/Lithe/Views/Workbench/WorkbenchView.swift"
        )
        let source = try String(contentsOf: workbenchURL, encoding: .utf8)

        #expect(
            source.range(of: #"\.drawingGroup\b"#, options: .regularExpression) == nil,
            "WorkbenchView contains NSViewRepresentable content and must not be flattened with drawingGroup()."
        )
    }
}
