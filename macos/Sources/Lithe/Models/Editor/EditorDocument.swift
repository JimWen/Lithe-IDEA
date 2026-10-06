import Combine
import Foundation
import LitheCoreContracts

@MainActor
final class EditorDocument: ObservableObject, Identifiable, @unchecked Sendable {
    struct MutationLease: Hashable, Sendable { fileprivate let id: UUID }
    enum DocumentError: LocalizedError {
        case readOnly
        case externalConflict
        case mutationInProgress

        var errorDescription: String? {
            switch self {
            case .mutationInProgress:
                "A workspace edit is in progress. Try again after it finishes."
            case .readOnly:
                "This document is read-only"
            case .externalConflict:
                "The file changed on disk. Choose Keep Editor Version or Load Disk Version before saving."
            }
        }
    }

    let id = UUID()
    private(set) var url: URL
    /// Invalidates asynchronous reads even after a rename away and back.
    private(set) var locationRevision: UInt64 = 0
    private let isProductReadOnly: Bool
    @Published private(set) var isReadOnly: Bool
    let displayPath: String?
    /// Preview subscribers receive live edits without invalidating the editor hierarchy.
    let textDidChange = PassthroughSubject<Void, Never>()
    private var storedText: String
    var text: String {
        get { storedText }
        set {
            guard !hasMutationLease else { return }
            guard !storedText.utf8.elementsEqual(newValue.utf8) else { return }
            pendingLanguageServerBaseText = nil
            nativeHistoryGeneration &+= 1
            replaceText(newValue, publish: true)
        }
    }
    @Published private(set) var savedText: String
    private var pendingLanguageServerBaseText: String?
    private(set) var nativeHistoryGeneration: UInt64 = 0
    private(set) var lifecycleState: DocumentLifecycleState
    private(set) var lastKnownModificationDate: Date?
    private var activeMutationLease: MutationLease?
    private(set) var acknowledgedDiskContent: String?
    private(set) var hasAcknowledgedDiskContent = false
    private(set) var externalDiskContent: String?
    private(set) var hasObservedDiskConflict = false
    var expectedDiskContent: String? { hasAcknowledgedDiskContent ? acknowledgedDiskContent : savedText }
    var externalFileMissing: Bool { hasObservedDiskConflict && externalDiskContent == nil }

    func observeDiskConflict(_ content: String?) {
        objectWillChange.send()
        externalDiskContent = content
        hasObservedDiskConflict = true
    }

    func acknowledgeObservedDiskContent() {
        guard hasObservedDiskConflict else { return }
        acknowledgedDiskContent = externalDiskContent
        hasAcknowledgedDiskContent = true
        hasObservedDiskConflict = false
    }


    init(
        url: URL,
        text: String,
        modificationDate: Date?,
        isReadOnly: Bool = false,
        isFileWritable: Bool = true,
        displayPath: String? = nil
    ) {
        self.url = url
        self.isProductReadOnly = isReadOnly
        self.isReadOnly = isReadOnly || !isFileWritable
        self.displayPath = displayPath
        self.storedText = text
        self.savedText = text
        self.lifecycleState = .clean(revision: 0)
        self.lastKnownModificationDate = modificationDate
    }

    func updateFileSystemWritable(_ isWritable: Bool) {
        let next = isProductReadOnly || !isWritable
        guard isReadOnly != next else { return }
        isReadOnly = next
    }

    var displayName: String {
        displayPath?.split(separator: "/").last.map(String.init) ?? url.lastPathComponent
    }

    var isDirty: Bool { lifecycleState.hasUnpersistedText }
    var hasExternalConflict: Bool { lifecycleState.status == .conflict }

    /// Reserves this buffer for a coordinated multi-file edit. Callers must
    /// release the exact token; a second lease is rejected deterministically.
    func acquireMutationLease() -> MutationLease? {
        // A native write owns its captured bytes until completion. Workspace
        // transactions must not overlap that write or its disk reconciliation.
        guard !isReadOnly, activeMutationLease == nil, lifecycleState.status != .saving else { return nil }
        let lease = MutationLease(id: UUID())
        activeMutationLease = lease
        return lease
    }

    func releaseMutationLease(_ lease: MutationLease) {
        guard activeMutationLease == lease else { return }
        activeMutationLease = nil
    }

    var hasMutationLease: Bool { activeMutationLease != nil }

    func commitMutationText(_ text: String, lease: MutationLease) {
        guard activeMutationLease == lease else { return }
        pendingLanguageServerBaseText = nil
        replaceText(text, publish: true)
    }

    /// Replays one validated native editor history entry directly into the
    /// live buffer. A save already in flight owns its captured snapshot, so a
    /// synchronous Undo/Redo may advance the current revision without taking
    /// the multi-file mutation lease or changing the native-history generation.
    @discardableResult
    func applyNativeHistoryText(_ text: String) -> Bool {
        guard !isReadOnly, !hasMutationLease else { return false }
        pendingLanguageServerBaseText = nil
        replaceText(text, publish: true)
        return true
    }

    /// Keep the live NSTextView buffer in sync without waking SwiftUI on every
    /// already-dirty keystroke. The first edit still publishes so the tab dirty
    /// mark can appear.
    func applyLiveEditorText(_ newText: String) {
        guard !isReadOnly, !hasMutationLease else { return }
        pendingLanguageServerBaseText = nil
        applyLiveEditorSnapshot(newText)
    }

    private func applyLiveEditorSnapshot(_ newText: String) {
        let remainsUnpersisted = lifecycleState.status == .saving
            || lifecycleState.status == .conflict
            || !newText.utf8.elementsEqual(savedText.utf8)
        replaceText(newText, publish: isDirty != remainsUnpersisted)
    }

    /// Applies the editor's latest change without asking the NSTextView for a
    /// full document snapshot. The editor and document model stay in lockstep
    /// through the same UTF-16 range used by NSTextView.
    @discardableResult
    func applyLiveEditorEdit(replacedRange: NSRange, replacement: String) -> Bool {
        guard !isReadOnly, !hasMutationLease else { return false }
        let source = storedText as NSString
        guard replacedRange.location != NSNotFound,
              replacedRange.location >= 0,
              replacedRange.length >= 0,
              replacedRange.location <= source.length,
              replacedRange.length <= source.length - replacedRange.location else {
            return false
        }
        guard Range(replacedRange, in: storedText) != nil else { return false }
        if pendingLanguageServerBaseText == nil { pendingLanguageServerBaseText = storedText }
        let nextText = source.replacingCharacters(in: replacedRange, with: replacement)
        applyLiveEditorSnapshot(nextText)
        return true
    }

    /// The Rust batch contract uses ranges in one pre-change snapshot. Merge
    /// sequential keystrokes into one replacement, rather than forwarding
    /// coordinates from several different document revisions.
    func takePendingLanguageServerChanges() -> [LanguageServerDocumentChange] {
        guard let base = pendingLanguageServerBaseText else { return [] }
        pendingLanguageServerBaseText = nil
        let source = base as NSString
        let target = storedText as NSString
        var start = 0
        let commonLength = min(source.length, target.length)
        while start < commonLength, source.character(at: start) == target.character(at: start) {
            start += 1
        }
        if start == source.length && start == target.length { return [] }
        // A shared UTF-16 prefix/suffix may end inside an emoji surrogate pair.
        if start > 0, (0xD800...0xDBFF).contains(source.character(at: start - 1)) { start -= 1 }
        var suffix = 0
        while suffix < source.length - start, suffix < target.length - start,
              source.character(at: source.length - suffix - 1) == target.character(at: target.length - suffix - 1) {
            suffix += 1
        }
        if suffix > 0, (0xDC00...0xDFFF).contains(source.character(at: source.length - suffix)) { suffix -= 1 }
        return [LanguageServerDocumentChange(
            start: Self.position(at: start, in: source),
            end: Self.position(at: source.length - suffix, in: source),
            text: target.substring(with: NSRange(location: start, length: target.length - suffix - start))
        )]
    }

    private static func position(
        at offset: Int,
        in source: NSString
    ) -> LanguageServerDocumentPosition {
        let safeOffset = min(max(offset, 0), source.length)
        var line = 0
        var lineStart = 0
        var index = 0
        // LSP counts CR, LF and CRLF as line separators, including native CRLF documents.
        while index < safeOffset {
            let unit = source.character(at: index)
            index += 1
            if unit == 13 {
                if index < safeOffset, source.character(at: index) == 10 { index += 1 }
                line += 1
                lineStart = index
            } else if unit == 10 {
                line += 1
                lineStart = index
            }
        }
        return LanguageServerDocumentPosition(line: line, utf16Column: safeOffset - lineStart)
    }

    private func replaceText(_ newText: String, publish: Bool) {
        // Canonically equivalent Unicode strings can still be different file
        // bytes. Document revision and dirty state must track the actual buffer.
        guard !storedText.utf8.elementsEqual(newText.utf8) else { return }
        let nextRevision = lifecycleState.revision + 1
        let nextLifecycle: DocumentLifecycleState
        switch lifecycleState.status {
        case .saving, .conflict:
            nextLifecycle = DocumentLifecycleState(
                status: lifecycleState.status,
                revision: nextRevision,
                savedRevision: lifecycleState.savedRevision,
                saveRevision: lifecycleState.saveRevision,
                operationId: lifecycleState.operationId
            )
        case .clean, .dirty:
            if newText.utf8.elementsEqual(savedText.utf8) {
                nextLifecycle = .clean(revision: nextRevision)
            } else {
                nextLifecycle = .dirty(
                    revision: nextRevision,
                    savedRevision: lifecycleState.savedRevision ?? lifecycleState.revision
                )
            }
        }
        if publish {
            objectWillChange.send()
        }
        storedText = newText
        lifecycleState = nextLifecycle
        textDidChange.send()
    }

    func save() throws {
        guard !hasMutationLease, lifecycleState.status != .saving else { throw DocumentError.mutationInProgress }
        guard !hasExternalConflict else { throw DocumentError.externalConflict }
        guard !isReadOnly else { throw DocumentError.readOnly }
        try text.write(to: url, atomically: true, encoding: .utf8)
        markSavedWithoutWriting()
    }

    func reloadFromDisk() throws {
        guard !hasMutationLease else { throw DocumentError.mutationInProgress }
        let contents = try String(contentsOf: url, encoding: .utf8)
        replaceWithDiskContent(contents)
    }

    func replaceWithDiskContent(_ contents: String) {
        guard !hasMutationLease else { return }
        pendingLanguageServerBaseText = nil
        nativeHistoryGeneration &+= 1
        storedText = contents
        savedText = contents
        hasAcknowledgedDiskContent = false
        hasObservedDiskConflict = false
        lifecycleState = .clean(revision: lifecycleState.revision + 1)
        lastKnownModificationDate = Self.modificationDate(for: url)
        textDidChange.send()
    }

    func keepEditorVersion() {
        acknowledgeExternalModification()
        lifecycleState = .dirty(
            revision: lifecycleState.revision,
            savedRevision: lifecycleState.savedRevision ?? 0
        )
        objectWillChange.send()
    }

    func acknowledgeExternalModification() {
        lastKnownModificationDate = Self.modificationDate(for: url)
    }

    func hasPossibleExternalChange() -> Bool {
        let currentDate = Self.modificationDate(for: url)
        return currentDate != lastKnownModificationDate
    }

    func applyLifecycleState(_ state: DocumentLifecycleState) {
        let statusChanged = lifecycleState.status != state.status
        if statusChanged {
            objectWillChange.send()
        }
        lifecycleState = state
    }

    func markSavedWithoutWriting(state: DocumentLifecycleState? = nil, savedContent: String? = nil) {
        savedText = savedContent ?? text
        hasAcknowledgedDiskContent = false
        hasObservedDiskConflict = false
        lifecycleState = state ?? .clean(revision: lifecycleState.revision)
        lastKnownModificationDate = Self.modificationDate(for: url)
    }

    func relocate(to newURL: URL) {
        pendingLanguageServerBaseText = nil
        objectWillChange.send()
        if url != newURL.standardizedFileURL { locationRevision &+= 1 }
        url = newURL.standardizedFileURL
        lastKnownModificationDate = Self.modificationDate(for: newURL)
    }

    static func modificationDate(for url: URL) -> Date? {
        // URL caches resource values. Reusing the open document's URL after an
        // atomic replacement must query the current file, not its cached mtime.
        var currentURL = url
        currentURL.removeCachedResourceValue(forKey: .contentModificationDateKey)
        return try? currentURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
