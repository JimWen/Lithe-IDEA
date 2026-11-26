# AI Agent Right-Sidebar Workbench (T3 Code Architecture Parity)

Status: **Done** (macOS, branch `feat/t3code-ai-agent`, verified 2026-11-27)

## Overview

Replicates the T3 Code (`pingdotgg/t3code`) multi-provider coding agent workflow natively inside Lithe for macOS as a dedicated, workspace-scoped built-in module (`LitheAIAgentModule`, `dev.lithe.ai-agent`) hosted in a resizable trailing sidebar (`LitheSplitPaneView` + `SplitHandleView`).

## Layer Ownership

- **Shared Contracts (`macos/Sources/LitheCoreContracts/AI/`)**:
  - `AIAgentModels.swift`: `AIAgentBackendKind` (`.codexCLI`, `.claudeCLI`, `.directHTTP`), `AIAgentPermissionMode` (`.plan`, `.supervised`, `.autoEdit`, `.fullAuto`), `AIAgentReasoningEffort`, `AIAgentSettings`, `AIAgentThread`, `AIAgentTurn`, `AIAgentTimelineItem`, `AIAgentApprovalRequest`, `AIAgentCheckpoint`, `AIAgentWorkingTreeDiff`, `AIAgentSlashCommand`.
  - `AIAgentPorts.swift`: platform-neutral ports (`AIAgentProcessSession`, `AIAgentProcessSessionFactory`, `AIHTTPStreamingTransport`, `AIAgentCLIResolving`, `AIAgentThreadStoring`, `AIAgentWorkspaceHost`).
- **Built-In Runtime Module (`macos/Sources/LitheAIAgentModule/`)** — Swift 6, zero AppKit/SwiftUI/Lithe imports:
  - `AIAgentModule.swift`: `LitheModule` lifecycle, `ModuleResource` + `ModuleLease` tracking per running turn so idle sleep/shutdown cleanly stops every subprocess and HTTP stream.
  - `AIAgentStreamParsers.swift`: bounded `AIAgentLineBuffer`, `CodexJSONLParser` (Codex CLI `exec --json` / `exec resume`), `ClaudeStreamJSONParser` (Claude Code `stream-json` + `--include-partial-messages`), `DirectHTTPSSEParser` (OpenAI Responses, Chat Completions, Anthropic Messages).
  - `AIAgentBackends.swift`: `AIAgentTurnRunner` supporting Codex CLI, Claude Code CLI, and a Direct HTTP streaming tool loop (`list_files`, `read_file`, `search_files`, `replace_in_file`, `write_file`, `run_command`) with bounded output caps (8 MiB/turn stream cap, 64 KiB/item output cap), pre-turn approval for supervised CLI turns, per-tool approvals for Direct API, and fail-closed checkpoint snapshotting.
  - `AIAgentFeatureModel.swift`: multi-thread management, prompt queueing & mid-run steering, interactive approvals, checkpoint revert, isolated Git worktree lifecycle (`preferIsolatedWorktree` + manual isolation), generation-guarded diff refresh, and `/` slash commands.
- **macOS Platform Adapters (`macos/Sources/Lithe/Platform/MacOS/AI/`)**:
  - `MacAIAgentProcessSession.swift`: `MacManagedProcess` + `ManagedProcessRegistry` dedicated process group, `F_SETNOSIGPIPE`, off-main-actor chunked stdin writer, EOF-drained termination, and `stopAndWait()`.
  - `MacAIAgentCLIResolver.swift`: login-shell + `~/.local/bin` + `~/.nvm` + Homebrew discovery for `codex` and `claude` with bounded 2.5s `--version` probes and auth hints.
  - `MacAIAgentThreadStore.swift`: atomic per-workspace thread persistence under Application Support.
  - `MacAIAgentWorkspaceBridge.swift`: canonical root-contained file I/O, existing workspace edits routed through `WorkspaceTextEditUndoController` (mutation leases, freshness checks, disk compensation, shared Undo/Redo), unborn-HEAD & spaced-filename Git diff parsing, isolated Git worktree creation/removal, and Commit/Push actions.
  - `MacURLSessionTransport.swift`: `AIHTTPStreamingTransport` via `URLSession.shared.bytes(for:)`.
- **Resizable Right Sidebar & Settings (`macos/Sources/Lithe/Views/`)**:
  - `WorkbenchView.swift` + `WorkbenchLayoutStore.swift`: upgraded trailing right sidebar to `LitheSplitPaneView` + `SplitHandleView` with persisted `rightSidebarWidth`, preserving `minimumWorkspaceContentWidth` and mutual exclusion across AI Agent, Go Tools, and Cargo.
  - `Views/AIAgent/`: `AIAgentToolWindowView`, `AIAgentTimelineView`, `AIAgentComposerView` (`@file` and `/` autocomplete, model/effort/mode/backend pills, Stop/Queue/Send), `AIAgentDiffReviewPanel` (inline diff, jump to full editor diff, Commit All, Push on both dirty and clean branches).
  - `Views/App/AIAgentSettingsSectionView.swift` integrated into Settings → AI & Commit.
  - Shortcuts & localization: `toggle-ai-agent` (`⌘⇧L`) and `new-ai-agent-thread` in `LitheCommandCatalog`, `LitheActionRegistry`, `en.lproj`, and `zh-Hans.lproj`.

## Verification Summary

- Static, contract, boundary, and stability gates:
  - `git diff --check`: passed (0 issues)
  - `./scripts/verify-shared-contracts.sh`: passed (`dev.lithe.ai-agent` synced in `shared/fixtures/modules/built-in-v1.json`)
  - `./scripts/verify-module-boundaries.sh`: passed
  - `./scripts/verify-service-boundaries.sh`: passed (`AppModel.swift` = 1,741 lines <= 1,800 limit)
  - `./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh`: passed
- Timed Swift test suites (`test-stability-macos.sh`, `-Xlinker -force_load`):
  - **103/103 passed** across 12 suites in `0.233s` (`AIAgentStreamParserTests`, `AIAgentModuleTests`, `AIAgentIntegrationTests`, `KeyboardShortcutTests`, `AppLocalizationTests`, `WorkbenchRenderingSafetyTests`, `ModuleRuntimeTests`, `AIAssistanceModuleTests`, `ProjectEnvironmentAndLibrariesTests`, `GoTreePresentationTests`).
- Independent Codex CLI review (`codex review -c model="gpt-6.1-sol" -c model_reasoning_effort="high" --uncommitted`):
  - All 13 findings (4 P1, 9 P2) resolved and covered by regression tests.
- Live toolchain smoke test:
  - Verified live `codex exec --json --skip-git-repo-check -C <tmp> -m gpt-6.1-sol -c 'model_reasoning_effort="low"' --sandbox workspace-write -` streaming `thread.started`, `agent_message`, and `turn.completed` token usage.

## Known Limitations

- Non-interactive `codex exec` and `claude -p` CLIs do not expose interactive per-tool mid-turn approval RPCs over stdio; in `Supervised` mode, CLI backends gate execution with an explicit pre-turn approval card, while `Direct API` mode provides full per-file and per-command interactive approval cards.
- Checkpoint revert restores pre-turn snapshots captured for Direct API tool edits; edits performed by external CLI subprocesses are reviewed and reverted via Git diff/discard in the inline Diff Review panel or Lithe's Git tool window.
