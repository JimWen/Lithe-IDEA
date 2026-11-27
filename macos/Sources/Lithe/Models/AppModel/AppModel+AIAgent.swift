import Combine
import Foundation
import LitheAIAgentModule
import LitheCoreContracts
import LitheModuleAPI

@MainActor
extension AppModel {
    var aiAgentFeatureIfActive: AIAgentFeatureModel? {
        aiAgentCapability?.feature
    }

    var isAIAgentAvailable: Bool {
        workspaceURL != nil
            && rightSidebarContributions.contains { $0.id == "ai.agent" }
    }

    var isAIAgentToolWindowSelected: Bool {
        isAIAgentVisible && isAIAgentAvailable
    }

    func toggleAIAgent() {
        guard isAIAgentAvailable else { return }
        isAIAgentVisible.toggle()
        if isAIAgentVisible {
            isGoVisible = false
            isCargoVisible = false
            Task { [weak self] in
                await self?.activateAIAgentModule()
            }
        }
    }

    func openNewAIAgentThread() {
        guard isAIAgentAvailable else { return }
        isAIAgentVisible = true
        isGoVisible = false
        isCargoVisible = false
        Task { [weak self] in
            guard let self, let feature = await self.activateAIAgentModule() else { return }
            _ = feature.createThread()
        }
    }

    @discardableResult
    func activateAIAgentModule() async -> AIAgentFeatureModel? {
        await awaitModuleRuntimeShutdown()
        if let feature = aiAgentFeatureIfActive {
            if let workspacePath = workspaceURL?.standardizedFileURL.path {
                feature.loadWorkspace(at: workspacePath)
            }
            return feature
        }
        guard !isAIAgentActivating else { return nil }
        isAIAgentActivating = true
        aiAgentActivationError = nil
        defer {
            isAIAgentActivating = false
            scheduleObjectWillChangeRelay()
        }
        do {
            await services.projectRuntimeService.prepareEnvironmentIfNeeded()
            let value = try await services.moduleRuntime.activateCapability(.aiAgentWorkspace)
            guard let capability = value as? LitheAIAgentModule.AIAgentCapability else {
                aiAgentActivationError = "AI Agent module is unavailable."
                return nil
            }
            let host = services.aiAgentWorkspaceHostBuilder.makeHost(callbacks: makeAIAgentHostCallbacks())
            aiAgentWorkspaceHostStorage = host
            capability.bind(host: host)
            cacheModuleCapability(capability, id: .aiAgentWorkspace, moduleID: .aiAgent)
            observeModuleFeature(.aiAgent, observation: capability.feature.objectWillChange.sink { [weak self] _ in
                self?.scheduleObjectWillChangeRelay()
            })
            if let workspacePath = workspaceURL?.standardizedFileURL.path {
                capability.feature.loadWorkspace(at: workspacePath)
            }
            return capability.feature
        } catch {
            aiAgentActivationError = error.localizedDescription
            showNotification(error.localizedDescription)
            return nil
        }
    }

    func invalidateAIAgentWorkspace() {
        aiAgentFeatureIfActive?.resetWorkspace()
        aiAgentActivationError = nil
        isAIAgentVisible = false
    }

    func handleAIAgentModuleEvent(_ event: ModuleEvent) {
        guard event.source == .aiAgent else { return }
        let retired = event.name == "module.sleeping" || event.name == "module.shutdown"
        let unavailable = event.name == ModuleEvent.stateChangedName
            && moduleSnapshots.first(where: { $0.manifest.id == .aiAgent })?.state == .disabled
        guard retired || unavailable else { return }
        aiAgentWorkspaceHostStorage = nil
        isAIAgentVisible = false
        aiAgentActivationError = nil
    }

    func attachActiveEditorContextToAgent() {
        guard let feature = aiAgentFeatureIfActive,
              let attachment = makeActiveEditorAttachment(rootPath: feature.selectedThread?.effectiveRootPath) else { return }
        feature.addAttachment(attachment)
    }

    func askAIAgentFromEditor(presetPrompt: String? = nil) {
        guard isAIAgentAvailable else { return }
        isAIAgentVisible = true
        isGoVisible = false
        isCargoVisible = false
        let attachment = makeActiveEditorAttachment(rootPath: aiAgentFeatureIfActive?.selectedThread?.effectiveRootPath)
        Task { [weak self] in
            guard let self, let feature = await self.activateAIAgentModule() else { return }
            if let attachment {
                feature.addAttachment(attachment)
            }
            if let presetPrompt, !presetPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                feature.sendPrompt(presetPrompt, attachments: feature.attachedContexts)
                feature.attachedContexts = []
            }
        }
    }

    private func makeActiveEditorAttachment(rootPath: String?) -> AIAgentContextAttachment? {
        guard let document = activeDocument,
              let workspaceURL else { return nil }
        let effectiveRoot = rootPath ?? workspaceURL.standardizedFileURL.path
        let rootURL = URL(fileURLWithPath: effectiveRoot, isDirectory: true).standardizedFileURL
        guard let relativePath = workspaceRelativePath(for: document.url, root: rootURL)
            ?? workspaceRelativePath(for: document.url, root: workspaceURL) else { return nil }
        let selectedText = editorSelectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selectedText.isEmpty {
            let line = (editorCaret?.line ?? 0) + 1
            let lineCount = max(1, selectedText.split(separator: "\n", omittingEmptySubsequences: false).count)
            return AIAgentContextAttachment(
                kind: .selection(
                    relativePath: relativePath,
                    startLine: line,
                    endLine: line + lineCount - 1,
                    snippet: String(selectedText.prefix(8000))
                )
            )
        }
        return AIAgentContextAttachment(kind: .file(relativePath: relativePath))
    }

    func openAIAgentDiffInEditor(relativePath: String, rootPath: String) {
        guard let workspaceURL else { return }
        let rootNormalized = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL.path
        if rootNormalized == workspaceURL.standardizedFileURL.path,
           let change = gitChanges.first(where: { $0.path == relativePath }) {
            selectChange(change)
            return
        }
        let targetURL = URL(fileURLWithPath: rootPath, isDirectory: true)
            .appendingPathComponent(relativePath)
            .standardizedFileURL
        openFile(targetURL)
    }

    private func makeAIAgentHostCallbacks() -> AIAgentHostCallbacks {
        AIAgentHostCallbacks(
            workspacePath: { [weak self] in self?.workspaceURL?.standardizedFileURL.path },
            agentSettings: { [weak self] in self?.settings.aiAgent ?? .default },
            commitMessageAISettings: { [weak self] in self?.settings.commitMessageAI ?? .default },
            readOpenDocumentText: { [weak self] url in
                let target = url.standardizedFileURL
                return self?.openDocuments.first(where: { $0.url.standardizedFileURL == target })?.text
            },
            dirtyOpenDocumentSnapshots: { [weak self] rootURL in
                guard let self else { return [] }
                let canonicalRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
                return self.openDocuments.compactMap { doc in
                    guard doc.isDirty else { return nil }
                    let docURL = doc.url.resolvingSymlinksInPath().standardizedFileURL
                    guard let relPath = self.workspaceRelativePath(for: docURL, root: canonicalRoot) else {
                        return nil
                    }
                    return (relativePath: relPath, text: doc.text)
                }
            },
            applyWorkspaceTextEdit: { [weak self] relativePath, expectedSourceText, replacementText, workspaceURL, persistToDisk in
                guard let self else { return false }
                let targetURL = workspaceURL.appendingPathComponent(relativePath).standardizedFileURL
                let previousOpenText = self.openDocuments
                    .first(where: { $0.url.standardizedFileURL == targetURL })?.text
                var didApplyEdit = false
                if expectedSourceText != replacementText {
                    let edit = WorkspaceTextEdit(
                        path: relativePath,
                        sourceText: expectedSourceText,
                        replacementText: replacementText,
                        sourceIdentity: ""
                    )
                    let result = await self.services.workspaceTextEditUndoController.apply(
                        [edit],
                        at: workspaceURL
                    )
                    guard result.state == .applied else { return false }
                    didApplyEdit = true
                }
                if persistToDisk,
                   let openDoc = self.openDocuments.first(where: { $0.url.standardizedFileURL == targetURL }) {
                    let diskBytes = try? Data(contentsOf: targetURL)
                    if openDoc.isDirty || diskBytes != Data(replacementText.utf8) {
                        do {
                            let saved = try await self.saveDocument(openDoc)
                            if !saved {
                                if didApplyEdit, let previousOpenText {
                                    _ = await self.services.workspaceTextEditUndoController.apply(
                                        [WorkspaceTextEdit(
                                            path: relativePath,
                                            sourceText: replacementText,
                                            replacementText: previousOpenText,
                                            sourceIdentity: ""
                                        )],
                                        at: workspaceURL
                                    )
                                }
                                return false
                            }
                        } catch {
                            if didApplyEdit, let previousOpenText {
                                _ = await self.services.workspaceTextEditUndoController.apply(
                                    [WorkspaceTextEdit(
                                        path: relativePath,
                                        sourceText: replacementText,
                                        replacementText: previousOpenText,
                                        sourceIdentity: ""
                                    )],
                                    at: workspaceURL
                                )
                            }
                            throw error
                        }
                    }
                }
                return true
            },
            generateAICommitMessage: { [weak self] workingTreeDiff in
                guard let self else { return nil }
                self.refreshAIConfigurations()
                guard self.settings.commitMessageAI.activeProvider != nil else { return nil }
                let value = try await self.services.moduleRuntime.activateCapability(.aiCommitMessage)
                guard let capability = value as? any AICommitMessageGenerating else { return nil }
                defer { try? self.services.moduleRuntime.markIdle(.aiAssistance) }
                let fileInputs: [CommitMessageFileInput] = workingTreeDiff.files.prefix(40).map { file in
                    let kind: CommitMessageChangeKind
                    switch file.kind {
                    case .added: kind = .added
                    case .modified: kind = .modified
                    case .deleted: kind = .deleted
                    case .renamed: kind = .renamed
                    }
                    return CommitMessageFileInput(
                        path: file.path,
                        changeKind: kind,
                        diff: String(file.diffText.prefix(4000))
                    )
                }
                guard !fileInputs.isEmpty else { return nil }
                return try await capability.generateCommitMessage(
                    input: CommitMessageInput(files: fileInputs),
                    settings: self.settings.commitMessageAI
                )
            },
            openFile: { [weak self] url in self?.openFile(url) },
            openDiffForRelativePath: { [weak self] relPath, rootPath in
                self?.openAIAgentDiffInEditor(relativePath: relPath, rootPath: rootPath)
            },
            refreshWorkspaceAndGit: { [weak self] in
                guard let self else { return }
                await self.refreshWorkspace()
                if let git = self.gitFeatureIfActive {
                    await git.refreshGit()
                }
            },
            notify: { [weak self] message in self?.showNotification(message) }
        )
    }
}
