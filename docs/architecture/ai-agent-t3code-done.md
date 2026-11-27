# AI Agent Right-Sidebar Workbench (T3 Code Parity + Antigravity CLI ACP)

Status: **Done** (macOS, branch `feat/t3code-ai-agent`, verified 2026-11-27)

## Overview

Replicates the T3 Code (`pingdotgg/t3code`) multi-provider coding agent workflow natively inside Lithe for macOS as a dedicated, workspace-scoped built-in module (`LitheAIAgentModule`, `dev.lithe.ai-agent`) hosted in a resizable trailing sidebar (`LitheSplitPaneView` + `SplitHandleView`), with native **Antigravity CLI (`agy acp`, ACP v1 JSON-RPC 2.0 over stdio)** as the default backend alongside **Codex CLI**, **Claude Code CLI**, and **Direct HTTP Streaming**.

## Layer Ownership

- **Shared Contracts (`macos/Sources/LitheCoreContracts/AI/`)**:
  - `AIAgentModels.swift`: `AIAgentBackendKind` (`.antigravityCLI`, `.codexCLI`, `.claudeCLI`, `.directHTTP`), `AIAgentPermissionMode` (`.plan`, `.supervised`, `.autoEdit`, `.fullAuto`), `AIAgentReasoningEffort`, `AIAgentSettings` (`antigravityCLIPath`, `defaultAntigravityModel`, default backend `.antigravityCLI`), `AIAgentThread`, `AIAgentTurn` (`permissionMode`, `durationSeconds`, `assistantResponseText`, `isCompletedPlanProposal`, `canRevertCheckpoint`), `AIAgentTimelineItem`, `AIAgentApprovalRequest` (`allowsAllowOnce`, `allowsAllowAlways`, `cacheAlwaysAllowByKind`), `AIAgentCheckpoint` (`gitTreeHash`, `gitPostTurnTreeHash`, `fileSnapshots`, `preTurnDirtyBufferSnapshots`, `hasTreeDiffChanges`, `canRevert`), `AIAgentWorkingTreeDiff` (`aheadCount`, `behindCount`), `AIAgentContextAttachmentKind` (`.file`, `.selection`, `.image`), and `AIAgentSlashCommand` (including `/fork`).
  - `AIAgentPorts.swift`: platform-neutral ports (`AIAgentProcessSession`, `AIAgentProcessSessionFactory`, `AIHTTPStreamingTransport`, `AIAgentCLIResolving`, `AIAgentThreadStoring`, `AIAgentWorkspaceHost` including `captureGitCheckpointTree`, `openDirtyFileSnapshots`, `diffGitTrees`, `restoreGitCheckpointTree`, `discardFileChange`, `generateCommitMessage`, and `readImageData`).
- **Built-In Runtime Module (`macos/Sources/LitheAIAgentModule/`)** — Swift 6, zero AppKit/SwiftUI/Lithe imports:
  - `AIAgentModule.swift`: `LitheModule` lifecycle, `ModuleResource` + `ModuleLease` tracking per running turn so idle sleep/shutdown cleanly stops every subprocess and HTTP stream.
  - `Protocols/AIAgentACPProtocol.swift`: full Swift 6 `Sendable` ACP v1 JSON-RPC 2.0 builder & stateful stream parser (`ACPJSONRPCID` preserving string vs integer IDs, `ACPJSONRPCBuilder`, `ACPResponsePayload`, `ACPStreamParser`) for `initialize`, `session/new`, `session/resume`, `session/set_mode`, `session/set_model`, `session/set_config_option`, `session/prompt` (with multimodal image blocks), `session/cancel`, `session/update` (`agent_message_chunk`, `agent_thought_chunk`, `tool_call`, `tool_call_update`, `plan`), and bidirectional `session/request_permission` (strictly preserving option scope—never upgrading `.allowOnce` to `allow_always` and keeping server-scoped `allow_always` free of host kind-wide caching).
  - `Protocols/AIAgentStreamParsers.swift`: bounded `AIAgentLineBuffer` with `droppedOversizedLineCount` tracking, `CodexJSONLParser`, `ClaudeStreamJSONParser` (with consecutive identical error deduplication), `DirectHTTPSSEParser`, and `AIAgentPromptBuilder` with bounded `<prior_conversation>` history re-seeding (16 KiB) for fresh CLI sessions (forks, provider switches, worktree handoffs, ACP resume fallbacks).
  - `Backends/AIAgentBackends.swift`: `AIAgentTurnRunner` supporting:
    - **Antigravity CLI (`agy acp`)**: bidirectional JSON-RPC state machine with lossless framing under a hard 16 MiB queued-transport cap (`ACPTransportBudgetBox`, terminating runaway subprocesses rather than silently dropping frames), explicit 4 MiB single-frame overflow errors, fatal `session/set_mode` enforcement, live mid-turn interactive `session/request_permission`, `session/resume` -> `session/new` fallback with history seeding, multimodal image blocks, and `session/cancel` + `stopAndWait()` teardown.
    - **Codex CLI**: `exec --json` / `exec resume` with `-i <imagePath>` multimodal image attachments.
    - **Claude Code CLI**: `stream-json` + `--include-partial-messages` (omitting invalid `"default"` `--permission-mode` for `.supervised`).
    - **Direct HTTP Streaming**: OpenAI Responses (`input_image`), Chat Completions (`image_url`), and Anthropic Messages (`image`) with built-in workspace tool loop (`list_files`, `read_file`, `search_files`, `replace_in_file`, `write_file`, `run_command`), per-tool approvals, and fail-closed file snapshotting.
  - `Application/AIAgentFeatureModel.swift`: multi-thread management, prompt queueing & mid-run steering, interactive approvals (with cancellation-safe continuations), universal Git-tree + dirty-buffer checkpoints & revert, Plan Mode `implementPlan(from:inNewWorktree:)` embedding `<approved_plan>`, `forkThread`, `exportThreadMarkdown`, `retryTurn`, `loadTurnIntoComposer`, isolated Git worktree lifecycle with cross-fork ownership guards, `discardWorkingTreeFile`, `generateCommitMessageForWorkingTree`, `commitAndPushWorkingTreeChanges` (root-bound), generation-guarded diff refresh, and `/` slash commands.
- **macOS Platform Adapters (`macos/Sources/Lithe/Platform/MacOS/AI/`)**:
  - `MacAIAgentProcessSession.swift`: `MacManagedProcess` + `ManagedProcessRegistry` dedicated process group, `F_SETNOSIGPIPE`, dedicated serial off-main-actor chunked stdin writer for bidirectional ACP JSON-RPC, EOF-drained termination, and `stopAndWait()`.
  - `MacAIAgentCLIResolver.swift`: discovery for `agy` (`antigravityCLIPath`, `PATH`, `~/.local/bin/agy`, Homebrew), `codex`, and `claude` with bounded `--version` probes and auth hints (`~/.gemini/antigravity-cli` / `GEMINI_API_KEY`).
  - `MacAIAgentThreadStore.swift`: atomic per-workspace thread persistence under Application Support.
  - `MacAIAgentWorkspaceBridge.swift`: verbatim-whitespace root-contained file I/O; workspace edits routed through `WorkspaceTextEditUndoController` (mutation leases, freshness checks, atomic buffer-and-save rollback, shared Undo/Redo); `GitRepositoryLayout` (`--show-toplevel` + `--show-prefix`) rebasing all diff, checkpoint, discard, and commit operations to opened workspace subdirectories; NUL-delimited (`-z`) Git parsing; `--literal-pathspecs` on discard + staged rename source restoration; `--attr-source=<treeHash>` isolated `checkout-index` staging preserving `.gitattributes`, symlinks (`120000`), POSIX modes (`100755`), non-UTF-8/binary/>16 MiB entries, and `.gitignore`d files; preflight non-empty directory blocker checks + safe empty-directory pruning + full batch rollback compensation; symlink-safe untracked diff rendering (`O_NOFOLLOW`, never reading external symlink targets); ahead/behind counts; and AI commit generation via `LitheAIAssistanceModule` (`CommitMessageInput`) with deterministic fallback.
  - `MacURLSessionTransport.swift`: `AIHTTPStreamingTransport` via `URLSession.shared.bytes(for:)`.
- **Resizable Right Sidebar, Editor Integration & Settings (`macos/Sources/Lithe/Views/`)**:
  - `WorkbenchView.swift` + `WorkbenchLayoutStore.swift`: trailing right sidebar using `LitheSplitPaneView` + `SplitHandleView` with persisted `rightSidebarWidth`, preserving `minimumWorkspaceContentWidth` and mutual exclusion across AI Agent, Go Tools, and Cargo.
  - `Views/AIAgent/`: `AIAgentToolWindowView` (unified `.litheContextMenu`, Fork Thread, Copy Markdown transcript, drag-and-drop workspace files/images, background running-thread count badge), `AIAgentTimelineView` (Plan Mode proposal action bar `Implement Plan` / `In Worktree` / `Copy`, live elapsed timer, duration badge, Retry / Edit-in-Composer, universal Revert, server-scoped approval buttons), `AIAgentComposerView` (Attach Image button, image chips, keyboard navigation `↑`/`↓`/`Tab` in `/` and `@file` autocomplete, backend/model/effort/mode pills), `AIAgentDiffReviewPanel` (per-file Discard with confirmation, AI Generate Commit Message, Commit & Push, ahead/behind badge, Expand/Collapse All, persistent file filter).
  - `Views/Editor/CodeEditorView.swift` + `LitheCommandCatalog.swift` + `LitheAction.swift` + `en.lproj`/`zh-Hans.lproj`: editor right-click `Ask AI Agent…`, `Explain with AI Agent`, `Review & Fix with AI Agent` plus commands `toggle-ai-agent` (`⌘⇧L`), `new-ai-agent-thread`, `ask-ai-agent`, and `explain-with-ai-agent`.
  - `Views/App/AIAgentSettingsSectionView.swift`: Antigravity CLI path & default model, Codex/Claude CLI probes on `.task`, and Direct API active profile status.

## Verification Summary

- **Static, contract, boundary, stability & plugin gates (all passed, 0 errors)**:
  - `git diff --check`
  - `cargo fmt --manifest-path rust/Cargo.toml --all --check`
  - `./scripts/verify-rust-core-comments.sh` & `./scripts/verify-rust-core-layout.sh`
  - `./scripts/verify-git-graph.sh`
  - `./scripts/verify-shared-contracts.sh`
  - `./scripts/verify-module-boundaries.sh`
  - `./scripts/verify-service-boundaries.sh` (`AppModel.swift` = 1,742 lines <= 1,800 limit)
  - `./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh`
  - `LitheCoreVerifier` (`Core verification passed`)
  - `./scripts/verify-official-plugins.sh` (3/3 native bundles: `GoSupport`, `PythonSupport`, `RustSupport`)
- **Automated timed test suites**:
  - **Rust workspace** (`rust-aiagent-final.json`): **572/572 passed** (`lithe-core` 543, `lithe-db-sidecar` 19, `lithe-db-mcp` 4, `lithe-git-host` 6).
  - **Focused macOS Swift AI Agent & workbench suites**: **116/116 passed** across 9 suites in `4.413s` (`AIAgentStreamParserTests`, `AIAgentModuleTests`, `AIAgentIntegrationTests`, `AppLocalizationTests`, `KeyboardShortcutTests`, `WorkbenchRenderingSafetyTests`, `ModuleRuntimeTests`, etc.).
  - **Full macOS Swift timed suite** (`macos-aiagent-final-full.json`): **1,720/1,721 passed** across 205 suites in `43.678s`, with the single pre-existing PTY flake (`MacTerminalConfigurationTests.badInterpreterProducesNormalizedExitAndVisibleRetryError`) passing **5/5 in `0.532s`** on targeted suite re-run (`ContextMenuCoverageTests` 8/8, `ProjectWindowManagerTests` full suite, `StableRollbackTests` 12/12, `TerminalActivationTests` full suite all green).
- **Independent Codex CLI reviews (`codex review -c model="gpt-6.1-sol" -c model_reasoning_effort="high" --uncommitted`)**:
  - 5 consecutive review rounds across the entire feature & ACP implementation; all 34 P1/P2 findings resolved and locked with deterministic regression tests.
- **Live toolchain smoke tests**:
  - **Antigravity CLI (`agy 1.5.18`)**: verified live `/Users/wenzhou/.local/bin/agy acp` end-to-end (`initialize` -> `session/new` -> `session/set_mode(plan)` -> `session/prompt` -> `session/update` `agent_message_chunk` -> `stopReason=end_turn`, reply `LITHE_ACP_OK`) plus live `session/resume` and `session/request_permission` protocol compatibility.
  - **Codex CLI (`codex 0.163.0`)**: verified live `codex exec --json --skip-git-repo-check` streaming `thread.started`, `agent_message`, and `turn.completed` token usage.

## Known Limitations

- Non-interactive `codex exec` and `claude -p` CLIs do not expose interactive mid-turn per-tool approval RPCs over stdio; in `Supervised` mode those two backends gate execution with an explicit pre-turn approval card, whereas **Antigravity CLI (`agy acp`)** and **Direct API** support full live mid-turn per-tool interactive approval cards.
- Claude Code CLI (`2.1.280`) was installed but logged out on this verification host, so its runtime invocation path is covered by parser/argument unit tests rather than a live authenticated API round trip.
- Checkpoint restoration intentionally refuses to overwrite a directory containing untracked or `.gitignore`d files (preserving user data rather than recursively deleting uncaptured files).
