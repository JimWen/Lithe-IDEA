import Foundation
import LitheCoreContracts
import LitheLanguageIntelligenceModule

struct LanguageEditRequestContext {
    let id = UUID()
    let workspace: WorkspaceIdentity
    let generation: UInt64
    let requestURL: URL
    let buffers: [URL: WorkspaceTextEditBufferSnapshot]
    let session: LanguageEditingSessionToken?
    let synchronized: [URL: LanguageServerSynchronizedDocumentSnapshot]

    var withoutSession: Self {
        Self(workspace: workspace, generation: generation, requestURL: requestURL, buffers: buffers, session: nil, synchronized: [:])
    }
}

@MainActor
extension AppModel {
    /// Keep the old workspace's file access alive until guarded compensation
    /// finishes. Only the latest requested project transition is resumed.
    func deferProjectChangeUntilLanguageEditCompletes(_ action: @escaping @MainActor () -> Void) -> Bool {
        let controller = services.workspaceTextEditUndoController
        guard languageEditTask != nil || controller.isApplying else { return false }
        acceptsLanguageEdits = false
        languageEditGeneration &+= 1
        languageEditContexts.removeAll()
        pendingLanguageEditProjectChange = action
        controller.cancelCurrentOperation()
        if let task = languageEditTask {
            task.cancel()
        } else {
            // Disk Undo/Redo belongs to the existing controller. Retain one
            // host join so project replacement cannot release access early.
            languageEditTask = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.finishLanguageEditOperation() }
                _ = await controller.waitForCurrentOperation()
            }
        }
        return true
    }

    private func finishLanguageEditOperation() {
        languageEditTask = nil
        let projectChange = pendingLanguageEditProjectChange
        pendingLanguageEditProjectChange = nil
        projectChange?()
    }

    private func captureLanguageEditContext(requireSession: Bool) throws -> LanguageEditRequestContext {
        guard acceptsLanguageEdits, let document = activeDocument, let root = workspaceURL else { throw LanguageWorkspaceEditPlanner.Failure.staleSource }
        let token = try languageToolingSessionsIfActive?.prepareEditingSession(fileURL: document.url, text: document.text, rootURL: root)
        if requireSession, token == nil { throw LanguageWorkspaceEditPlanner.Failure.staleSource }
        var synchronized: [URL: LanguageServerSynchronizedDocumentSnapshot] = [:]
        if let token, let manager = languageToolingSessionsIfActive {
            let session = try manager.editingSession(matching: token)
            for open in openDocuments {
                let url = open.url.standardizedFileURL
                if let accepted = session.synchronizedDocumentSnapshot(for: url) {
                    // Ready flush can advance an initializing document's zero
                    // version. Ask Core again using its accepted bytes, never
                    // guess a version or accept an unsynchronized dirty buffer.
                    if accepted.version == 0 {
                        try manager.synchronizeEditingDocument(fileURL: url, text: accepted.sourceText, in: token)
                    }
                    synchronized[url] = session.synchronizedDocumentSnapshot(for: url)
                    if url == document.url.standardizedFileURL,
                       let accepted = synchronized[url], accepted.sessionIdentity == token.identity {
                        document.acknowledgeLanguageServerSnapshot(accepted.sourceText)
                    }
                }
            }
        }
        return LanguageEditRequestContext(
            workspace: WorkspaceIdentity(url: root.standardizedFileURL, generation: workspaceFeature.workspaceGeneration),
            generation: languageEditGeneration,
            requestURL: document.url.standardizedFileURL,
            buffers: Dictionary(uniqueKeysWithValues: openDocuments.map { ($0.url.standardizedFileURL, WorkspaceTextEditBufferSnapshot($0)) }),
            session: token, synchronized: synchronized)
    }

    private func storeLanguageEditContext(_ context: LanguageEditRequestContext) -> UUID {
        storeLanguageEditContexts([context])
        return context.id
    }

    private func storeLanguageEditContexts(_ contexts: [LanguageEditRequestContext]) {
        // Menus share one immutable request snapshot, regardless of item count.
        // An evicted request is rejected rather than rebound to current text.
        if languageEditContexts.count + contexts.count > 16 { languageEditContexts.removeAll() }
        for context in contexts { languageEditContexts[context.id] = context }
    }

    private func isCurrentLanguageEditContext(_ context: LanguageEditRequestContext,
                                              buffers: [URL: WorkspaceTextEditBufferSnapshot]? = nil) -> Bool {
        guard acceptsLanguageEdits, languageEditGeneration == context.generation,
              workspaceURL?.standardizedFileURL == context.workspace.url,
              workspaceFeature.workspaceGeneration == context.workspace.generation else { return false }
        if let session = context.session,
           languageToolingSessionsIfActive?.isCurrentEditingSession(session) != true { return false }
        if buffers == nil, let token = context.session {
            guard let session = try? languageToolingSessionsIfActive?.editingSession(matching: token) else { return false }
            for (url, captured) in context.synchronized {
                guard let current = session.synchronizedDocumentSnapshot(for: url),
                      current.sessionIdentity == captured.sessionIdentity, current.version == captured.version,
                      current.sourceText.utf8.elementsEqual(captured.sourceText.utf8) else { return false }
            }
        }
        let expected = buffers ?? context.buffers
        return expected.allSatisfy { url, snapshot in
            openDocuments.first(where: { $0.url.standardizedFileURL == url }).map(snapshot.matches) == true
        }
    }

    private func originalLanguageSession(_ context: LanguageEditRequestContext) throws -> any LanguageServerSession {
        guard isCurrentLanguageEditContext(context), let token = context.session,
              let manager = languageToolingSessionsIfActive else { throw LanguageWorkspaceEditPlanner.Failure.staleSource }
        return try manager.editingSession(matching: token)
    }

    func requestLanguageCompletions(line: Int, utf16Column: Int,
                                    completion: @escaping ([LanguageServerCompletionItem]) -> Void) {
        guard let document = activeDocument, let root = workspaceURL,
              let manager = languageToolingSessionsIfActive,
              manager.features(for: document.url).contains(.completion) else { completion([]); return }
        do {
            let context = try captureLanguageEditContext(requireSession: false)
            try manager.completions(fileURL: document.url, text: document.text,
                position: .init(line: max(0, line), utf16Column: max(0, utf16Column)), rootURL: root) { [weak self] result in
                guard let self, self.isCurrentLanguageEditContext(context.withoutSession) else { completion([]); return }
                switch result {
                case .success(let values):
                    let local = context.withoutSession
                    let server = context.session != nil && self.isCurrentLanguageEditContext(context) ? context : nil
                    self.storeLanguageEditContexts([local] + (server.map { [$0] } ?? []))
                    let localID = local.id
                    let serverID = server?.id
                    completion(values.compactMap { item in
                        var item = item
                        if let origin = item.originSessionIdentity {
                            guard origin == context.session?.identity, let serverID else { return nil }
                            item.requestContextID = serverID
                        } else { item.requestContextID = localID }
                        return item
                    })
                case .failure(let error):
                    if !(error is CancellationError) { self.showNotification(error.localizedDescription) }
                    completion([])
                }
            }
        } catch { showNotification(error.localizedDescription); completion([]) }
    }

    func requestLanguageRename(line: Int, utf16Column: Int, newName: String) {
        guard let document = activeDocument,
              languageToolingSessionsIfActive?.features(for: document.url).contains(.rename) == true else { return }
        do {
            let context = try captureLanguageEditContext(requireSession: true)
            try originalLanguageSession(context).rename(fileURL: context.requestURL,
                position: .init(line: max(0, line), utf16Column: max(0, utf16Column)), newName: newName) { [weak self] result in
                switch result {
                case .success(let edit): self?.beginLanguageWorkspaceEdit(edit, context: context)
                case .failure(let error): self?.showNotification(error.localizedDescription)
                }
            }
        } catch { showNotification(error.localizedDescription) }
    }

    func requestLanguageFormatting() {
        guard let document = activeDocument,
              languageToolingSessionsIfActive?.features(for: document.url).contains(.formatting) == true else { return }
        do {
            let context = try captureLanguageEditContext(requireSession: true)
            try originalLanguageSession(context).format(fileURL: context.requestURL) { [weak self] result in
                switch result {
                case .success(let edits): self?.beginLanguageWorkspaceEdit(.init(operations: [
                    .edit(.init(uri: context.requestURL.absoluteString, edits: edits))]), context: context)
                case .failure(let error): self?.showNotification(error.localizedDescription)
                }
            }
        } catch { showNotification(error.localizedDescription) }
    }

    func requestLanguageCodeActions(line: Int, utf16Column: Int,
                                    completion: @escaping ([LanguageServerCodeAction]) -> Void) {
        guard let document = activeDocument,
              languageToolingSessionsIfActive?.features(for: document.url).contains(.codeActions) == true else { completion([]); return }
        do {
            let context = try captureLanguageEditContext(requireSession: true)
            let position = LanguageServerPosition(line: max(0, line), utf16Column: max(0, utf16Column))
            try originalLanguageSession(context).codeActions(fileURL: context.requestURL,
                range: .init(start: position, end: position), diagnostics: languageDiagnostics[context.requestURL] ?? []) { [weak self] result in
                guard let self, self.isCurrentLanguageEditContext(context) else { completion([]); return }
                switch result {
                case .success(let actions):
                    let id = self.storeLanguageEditContext(context)
                    completion(actions.map { action in var action = action; action.requestContextID = id; return action })
                case .failure(let error): self.showNotification(error.localizedDescription); completion([])
                }
            }
        } catch { showNotification(error.localizedDescription); completion([]) }
    }

    func applyLanguageCodeAction(_ action: LanguageServerCodeAction) {
        guard let id = action.requestContextID,
              let context = languageEditContexts.removeValue(forKey: id), isCurrentLanguageEditContext(context) else {
            showNotification(LanguageWorkspaceEditPlanner.Failure.staleSource.localizedDescription); return
        }
        do {
            let session = try originalLanguageSession(context)
            if action.data != nil, session.features.contains(.codeActionResolve) {
                try session.resolveCodeAction(action, fileURL: context.requestURL) { [weak self] result in
                    switch result {
                    case .success(let resolved): self?.beginLanguageWorkspaceEdit(resolved.edit ?? .init(), context: context, command: resolved.command)
                    case .failure(let error): self?.showNotification(error.localizedDescription)
                    }
                }
            } else { beginLanguageWorkspaceEdit(action.edit ?? .init(), context: context, command: action.command) }
        } catch { showNotification(error.localizedDescription) }
    }

    private func beginLanguageWorkspaceEdit(_ edit: LanguageServerWorkspaceEdit, context: LanguageEditRequestContext,
                                           command: LanguageServerCommand? = nil) {
        guard isCurrentLanguageEditContext(context) else {
            showNotification(LanguageWorkspaceEditPlanner.Failure.staleSource.localizedDescription); return
        }
        guard languageEditTask == nil else {
            showNotification("A language edit is still in progress. Try again after it finishes."); return
        }
        languageEditTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishLanguageEditOperation() }
            var didApply = false
            do {
                let edits = try await self.planLanguageWorkspaceEdit(edit, context: context)
                var committedBuffers: [URL: WorkspaceTextEditBufferSnapshot] = [:]
                let result = await self.services.workspaceTextEditUndoController.apply(edits, at: context.workspace.url,
                    expectedBuffers: context.buffers, validate: { [weak self] in
                        self?.isCurrentLanguageEditContext(context) == true
                    }, didCommit: { snapshots in
                        committedBuffers = snapshots.filter { context.buffers[$0.key] != nil }
                    })
                guard result.state == .applied else {
                    if result.state == .recoveryRequired {
                        self.showNotification("The language edit could not be rolled back. Review: " + result.recoveryPaths.joined(separator: ", "), severity: .error)
                    } else { self.showNotification("The language edit was not applied. Files or the request context changed.") }
                    return
                }
                didApply = !result.changedPaths.isEmpty
                if let token = context.session, self.languageToolingSessionsIfActive?.isCurrentEditingSession(token) == true {
                    let closed = result.changedPaths.filter { context.buffers[context.workspace.url.appendingPathComponent($0).standardizedFileURL] == nil }
                    try self.languageToolingSessionsIfActive?.editingSession(matching: token).notifyWorkspaceFilesChanged(
                        closed.map { .init(fileURL: context.workspace.url.appendingPathComponent($0), kind: .changed) })
                }
                guard let command else { return }
                guard !Task.isCancelled, committedBuffers.count == context.buffers.count,
                      self.isCurrentLanguageEditContext(context, buffers: committedBuffers),
                      let token = context.session, let manager = self.languageToolingSessionsIfActive else {
                    self.showNotification(didApply
                        ? "The edit was applied; its follow-up command was cancelled because the context changed."
                        : "The command was cancelled because the context changed."); return
                }
                for (url, snapshot) in committedBuffers {
                    if context.synchronized[url] != nil {
                        try manager.synchronizeEditingDocument(fileURL: url, text: snapshot.text, in: token)
                    }
                }
                let failurePrefix = didApply ? "The edit was applied; the follow-up command failed: " : "The command failed: "
                try manager.editingSession(matching: token).execute(command, fileURL: context.requestURL) { [weak self] result in
                    if case .failure(let error) = result { self?.showNotification(failurePrefix + error.localizedDescription) }
                }
            } catch {
                self.showNotification(error.localizedDescription, severity: .error,
                                      title: didApply ? "Edit applied; follow-up failed" : "Could not apply language edit")
            }
        }
    }

    private func planLanguageWorkspaceEdit(_ edit: LanguageServerWorkspaceEdit, context: LanguageEditRequestContext) async throws -> [WorkspaceTextEdit] {
        guard isCurrentLanguageEditContext(context), !Task.isCancelled else { throw LanguageWorkspaceEditPlanner.Failure.staleSource }
        let operations = try LanguageWorkspaceEditPlanner.textOperations(edit, rootURL: context.workspace.url)
        var sources: [URL: LanguageWorkspaceEditPlanner.Source] = [:]
        var closed: [String] = []
        let root = context.workspace.url.path + "/"
        for (url, _) in operations where sources[url] == nil {
            let path = String(url.path.dropFirst(root.count))
            if let buffer = context.buffers[url] {
                sources[url] = .init(path: path, text: buffer.text, diskIdentity: "", isOpen: true, synchronized: context.synchronized[url])
            } else {
                guard !openDocuments.contains(where: { $0.url.standardizedFileURL == url }) else { throw LanguageWorkspaceEditPlanner.Failure.staleSource }
                if let token = context.session,
                   try languageToolingSessionsIfActive?.editingSession(matching: token).synchronizedDocumentSnapshot(for: url) != nil {
                    throw LanguageWorkspaceEditPlanner.Failure.staleSource
                }
                if !closed.contains(path) { closed.append(path) }
            }
        }
        if !closed.isEmpty {
            let captured = try await services.workspaceTextEditFileOperations.capture(closed, at: context.workspace.url)
            guard Set(captured.map(\.path)) == Set(closed), captured.count == closed.count else { throw LanguageWorkspaceEditPlanner.Failure.invalidTarget }
            for snapshot in captured {
                sources[context.workspace.url.appendingPathComponent(snapshot.path).standardizedFileURL] = .init(
                    path: snapshot.path, text: snapshot.text, diskIdentity: snapshot.identity, isOpen: false, synchronized: nil)
            }
        }
        guard isCurrentLanguageEditContext(context), !Task.isCancelled else { throw LanguageWorkspaceEditPlanner.Failure.staleSource }
        return try LanguageWorkspaceEditPlanner.plan(edit, rootURL: context.workspace.url, sources: sources, sessionIdentity: context.session?.identity)
    }

    func applyLanguageCompletion(_ item: LanguageServerCompletionItem, fallbackRange: LanguageServerRange,
                                 beforeSelection: NSRange? = nil,
                                 canApply: @escaping @MainActor () -> Bool = { true },
                                 restoreSelection: @escaping @MainActor (NSRange) -> Void = { _ in }) {
        do {
            let context: LanguageEditRequestContext
            if let id = item.requestContextID {
                guard let captured = languageEditContexts.removeValue(forKey: id) else { throw LanguageWorkspaceEditPlanner.Failure.staleSource }
                context = captured
            } else {
                // Local callers may supply a direct unversioned completion.
                guard item.data == nil, item.originSessionIdentity == nil, let root = workspaceURL,
                      let document = activeDocument else { throw LanguageWorkspaceEditPlanner.Failure.staleSource }
                context = LanguageEditRequestContext(
                    workspace: .init(url: root.standardizedFileURL, generation: workspaceFeature.workspaceGeneration),
                    generation: languageEditGeneration,
                    requestURL: document.url.standardizedFileURL,
                    buffers: Dictionary(uniqueKeysWithValues: openDocuments.map { ($0.url.standardizedFileURL, WorkspaceTextEditBufferSnapshot($0)) }),
                    session: nil, synchronized: [:])
            }
            guard canApply(), isCurrentLanguageEditContext(context), activeDocument?.url.standardizedFileURL == context.requestURL else {
                throw LanguageWorkspaceEditPlanner.Failure.staleSource
            }
            let apply: (LanguageServerCompletionItem) -> Void = { [weak self] resolved in
                self?.performLanguageCompletion(resolved, fallbackRange: fallbackRange, context: context,
                    beforeSelection: beforeSelection, canApply: canApply, restoreSelection: restoreSelection)
            }
            if item.data != nil, context.session != nil,
               try originalLanguageSession(context).features.contains(.completionResolve) {
                try originalLanguageSession(context).resolveCompletion(item, fileURL: context.requestURL) { [weak self] result in
                    switch result {
                    case .success(let resolved): apply(resolved)
                    case .failure(let error): self?.showNotification(error.localizedDescription)
                    }
                }
            } else { apply(item) }
        } catch { showNotification(error.localizedDescription) }
    }

    private func performLanguageCompletion(_ item: LanguageServerCompletionItem, fallbackRange: LanguageServerRange,
                                           context: LanguageEditRequestContext, beforeSelection: NSRange?,
                                           canApply: @MainActor () -> Bool, restoreSelection: @escaping @MainActor (NSRange) -> Void) {
        do {
            guard canApply(), isCurrentLanguageEditContext(context), activeDocument?.url.standardizedFileURL == context.requestURL,
                  let buffer = context.buffers[context.requestURL] else { throw LanguageWorkspaceEditPlanner.Failure.staleSource }
            let source = item.textEdit ?? .init(range: fallbackRange, newText: item.insertText)
            let primary = LanguageServerTextEdit(range: source.range, newText: LanguageServerSnippet.plainText(source.newText), annotationID: source.annotationID)
            let edits = [primary] + item.additionalTextEdits
            let root = context.workspace.url.path + "/"
            let plan = try LanguageWorkspaceEditPlanner.plan(.init(operations: [.edit(.init(uri: context.requestURL.absoluteString, edits: edits))]),
                rootURL: context.workspace.url, sources: [context.requestURL: .init(
                    path: String(context.requestURL.path.dropFirst(root.count)), text: buffer.text, diskIdentity: "", isOpen: true,
                    synchronized: context.synchronized[context.requestURL])], sessionIdentity: context.session?.identity)
            let range = try LanguageServerTextEditApplicator.range(primary.range, in: buffer.text)
            var caret = range.location + primary.newText.utf16.count
            for additional in item.additionalTextEdits {
                let other = try LanguageServerTextEditApplicator.range(additional.range, in: buffer.text)
                if other.location < range.location { caret += additional.newText.utf16.count - other.length }
            }
            let result = services.workspaceTextEditUndoController.applyOpenDocumentEdits(plan, at: context.workspace.url,
                expectedBuffers: context.buffers, selection: .init(before: beforeSelection ?? range,
                    after: NSRange(location: caret, length: 0), restore: restoreSelection))
            guard result.state == .applied else { throw LanguageWorkspaceEditPlanner.Failure.staleSource }
        } catch { showNotification(error.localizedDescription, severity: .error, title: "Could not apply completion") }
    }
}
