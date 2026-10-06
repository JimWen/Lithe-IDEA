import Foundation

/// Source identity frozen before an asynchronous edit request. Text equality
/// alone cannot detect a change followed by Undo, relocation, or reopening.
struct WorkspaceTextEditBufferSnapshot: Sendable {
    let documentID: UUID
    let url: URL
    let locationRevision: UInt64
    let revision: UInt64
    let nativeHistoryGeneration: UInt64
    let text: String

    @MainActor init(_ document: EditorDocument) {
        documentID = document.id
        url = document.url.standardizedFileURL
        locationRevision = document.locationRevision
        revision = document.lifecycleState.revision
        nativeHistoryGeneration = document.nativeHistoryGeneration
        text = document.text
    }

    @MainActor func matches(_ document: EditorDocument) -> Bool {
        documentID == document.id && url == document.url.standardizedFileURL
            && locationRevision == document.locationRevision && revision == document.lifecycleState.revision
            && text.utf8.elementsEqual(document.text.utf8)
    }

    @MainActor func matchesHistory(_ document: EditorDocument) -> Bool {
        documentID == document.id && url == document.url.standardizedFileURL
            && locationRevision == document.locationRevision && nativeHistoryGeneration == document.nativeHistoryGeneration
    }
}
