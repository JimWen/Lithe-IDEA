# macOS Service Boundaries

The macOS application uses a stable Rust Core boundary and a native adapter
layer. SwiftUI and AppKit render the product, application feature models own UI
state transitions, and macOS adapters provide capabilities that cannot be
shared with Windows.

## Runtime graph

```text
SwiftUI / AppKit Views
          ↓
AppModel: UI state, navigation, feature composition
          ↓
Application Feature Models
          ↓
AppServices + Swift Services
     ┌────┴───────────────┐
     ↓                    ↓
Rust operations       macOS ports/adapters
     ↓                    ↓
Rust Core + JSON C ABI  FileSystem / FSEvents / Process / PTY / UI
```

`MacServiceContainer` is the macOS composition root. It creates the Rust Core
bridge, Rust-backed workspace/Git/history/Java operations, Swift services, and
macOS adapters, then injects them into `AppServices`. A future Windows
composition root must construct the same application-facing ports with Windows
implementations.

## Source ownership

| Directory | Responsibility |
| --- | --- |
| `macos/Sources/Lithe/Views/` | SwiftUI/AppKit presentation, input, navigation destinations, and view-local rendering. |
| `macos/Sources/Lithe/Models/` | UI-facing models and value types. `AppModel` is the observable aggregate, not the platform composition root. |
| `macos/Sources/Lithe/Application/` | Workspace, Document, Git, Search, Java, Terminal, Project History, and UI Feature Models. These coordinate state and user actions. |
| `macos/Sources/Lithe/Services/` | Product workflow orchestration. Language feature routing plus Run/Debug lifecycles remain Swift workflows; the LSP service is a semantic facade over the Rust runtime. |
| `macos/Sources/Lithe/Core/Ports/` | Platform-neutral interfaces for process, terminal, storage, runtime discovery, file operations, watchers, and native UI capabilities. |
| `macos/Sources/Lithe/Core/Rust/` | Typed operations and model conversion for the shared Rust JSON contract. |
| `macos/Sources/Lithe/Platform/MacOS/` | FSEvents, file operations, persistence, process sessions, PTY, runtime discovery, native UI, shortcuts, and updates. |
| `rust/lithe-core/` | Shared commands, validation, parsing, ordering, Git operations, history, and JSON/C ABI. |

## Rules

Core ports and application code must not import SwiftUI, AppKit, CoreServices,
or concrete `Mac*` types. They must not construct `Process`, `Pipe`,
`FileManager`, `UserDefaults`, or `FileHandle` directly.

Services must receive those capabilities through ports. A Service may own a
workflow state machine, such as language-provider routing or Debug
lifecycle, but it must not decide how the operating system starts, watches,
stores, or terminates the underlying resource. The Rust LSP runtime is the
sole owner of its child process, stdio, JSON-RPC state, document versions,
request deadlines, diagnostics, and message normalization.

Views receive `AppModel` or a dedicated UI Feature Model. They must not receive
concrete workflow services, call the Rust C ABI directly, or construct platform
adapters.

The Rust Core owns deterministic cross-platform behavior:

- workspace snapshots, UTF-8 file reads/writes, search, and replacement preview;
- Git status, Diff, History, Blame, Stash, branch operations, remote sync,
  Clone, Commit, and patch application;
- Local History metadata and snapshot operations;
- Java source structure, code vision, class-name, and run-configuration parsing;
- lightweight language features and the complete LSP runtime: process,
  stdio/framing, lifecycle, documents, deadlines, capabilities, diagnostics,
  provider adapters, and normalized feature results;
- request envelopes, cancellation, deadlines, error codes, validation, and
  stable JSON ordering.

macOS owns the platform side of these capabilities:

- workspace selection, FSEvents, atomic/native file operations, permissions,
  persistence location, and Finder integration;
- language-server/JDK discovery and platform environment resolution;
- Java/Debug process transports, terminal PTY, shell, signals, and
  native handles (LSP process transport belongs to Rust);
- native window, menu, clipboard, shortcut, installer, and update behavior.

## Project window ownership

`ProjectWindowManager` owns the per-window `ProjectSessionManager` instances and
aggregates unsaved-document confirmation and shutdown across the application.
Each SwiftUI workspace scene has its own stable UUID and session manager. New
projects join the source window as native macOS tabs by default; Settings →
Projects can instead select separate windows or confirmation on each opening.
Existing stored opening preferences keep their raw values.

`ProjectWindowPresentation` owns weak native window references and invokes
AppKit tab operations. Merging, reordering, and dragging a tab into a separate
window do not transfer or recreate the project's `AppModel`, documents, terminal
sessions, or debug services. A project already open in another window is focused
instead of duplicated. Window closure retains its session manager until module
and process cleanup completes, and application termination also awaits those
closing windows.

`LitheProjectCommands` observes an immutable menu projection owned by
`MenuPresentationCoordinator`. Background changes coalesce after mutation and
publication pauses during native menu tracking. The app root retains FPS and
memory monitor references without subscribing to their samples; only status-bar
views observe those frequent changes, preventing Scene updates from dismissing
native submenus. The macOS command environment
separately validates the current key window, modal state, project generation,
and action payload before shortcuts or menu actions execute. Recent-project
availability runs on a bounded background worker. Window-opening and native restoration
paths allocate session managers; process-local retired identities prevent a
delayed scene from reviving a cancelled presentation request.

`KeyboardShortcutFeatureModel` resolves persisted bindings before registration
or display. Explicit overrides outrank defaults; colliding explicit bindings
are disabled for every owner while their original intent remains editable.
Menus, activity-bar help, search actions and native detectors use that same
resolution. Module UI actions map explicitly to catalog command IDs. Tool-window
commands share live eligibility and activation paths, including reopening a
retained Commit selection after Git sleeps. View-menu appearance and editor-tab
choices join the frozen menu snapshot and write the existing application
settings only after validating the native application context.

Find in Files and the Find tool window share the search module's query/options
and results. The popup owns selection and bounded source previews. Search
generations reject late responses when the query or scope changes. Open Files
uses the existing shared preview operation with explicit paths and editor text
overrides, without applying replacements or writing files.

Go, Rust and Python settings appear when the active project's manifest or file
inventory matches the language catalog. Project executable choices persist
through `ProjectRuntimeService` and its injected key-value store; the existing
runtime resolver applies them to subsequent Run, Debug and language-tool
launches. Language-server configuration continues to use the Language
Intelligence module. Editing a run configuration waits for the current
workspace snapshot before identifying entry points or presenting the editor.

## Update adapter

In-app updates use Sparkle through the macOS update adapter. See
[`macos-updates.md`](macos-updates.md) for signing, differential archives,
legacy-client compatibility, and release verification.

## Verification

Run this check after changing an application boundary:

```bash
scripts/verify-service-boundaries.sh
```

The script rejects platform imports and concrete adapter references in Core and
Services, direct workflow-service dependencies in Views, platform composition
in `AppModel`, and an oversized UI aggregate. Shared JSON behavior is checked
with `scripts/verify-shared-contracts.sh` and `scripts/verify-rust-core.sh`.

## Remaining migration work

The current boundary is usable and enforced, but it is not a claim that every
workflow has moved into Rust. Language provider routing remains an application
workflow, while the LSP process lifecycle and protocol state are shared Rust
contracts. Java Run/Debug sessions, and terminal session
state still use Swift platform ports. See
[`language-tooling.md`](language-tooling.md) for the language tooling split.

The macOS workbench mounts its project, branch and execution controls in a
`WorkbenchTitlebar` titlebar accessory above AppKit's project tab strip. Content
respects the window safe area. Resizing updates the native accessory width
without publishing high-frequency SwiftUI state. Project and branch popovers
anchor to their titlebar controls; no content overlay spans across native tabs.
Native tab dimensions and drag behavior follow the running macOS version.

## Upstream main integration (2026-09-09)

The merge imports upstream history through `4bb921dc78ef237fb6a51e2c1c0b62b0f04e5912`
with `8479dfa6` as the local baseline. Windows and Java/framework increments are
excluded from the resulting tree. The existing macOS module runtime, plugin
capabilities, per-window project ownership, and document mutation leases remain
the architectural owners; upstream aggregate/coordinator replacements are
adapted into those boundaries.

Integrated behavior includes multi-repository Git changes and repository
selection, native commit/file/worktree rendering, shared context menus and
coalesced split handles, local search drafts, incremental editor highlighting
and LSP synchronization, detected terminal shells, and diagnostic exports.
Git forwarding methods live in `AppModel+GitOperations`; selecting a repository
clears the previous repository’s history filter, and commit/stash/shelf state
uses the active repository. Go/Cargo project trees retain their native menus. Runnable gutter left and
right clicks use the shared presenter and freeze the clicked document’s actions.

The editor coalesces sequential UTF-16 edits against one snapshot. Rust verifies
that replay matches the authoritative buffer before publishing document state
or an LSP notification and recovers stale deltas with a full update. Native edit
callbacks respect document mutation leases. Mixed buffer/disk transactions and
every Undo/Redo cycle use the same owned workflow, with deferred watcher events,
resumed autosave, and compensation against the file identity actually installed. Programmatic buffer updates discard
pending deltas. Diagnostics UI observes published state values; cancellation and
operation generations prevent stale exports from clearing a newly prepared
bundle. The diagnostics workflow is composed in `MacServiceContainer` through
filesystem, system-information, and archiving ports.

Workbench resizing reuses `LitheSplitPaneView` and `SplitHandleView`, retains
mounted editor content when panels hide, constrains adjacent pane sizes, and
persists only committed drag sizes. Native drag events use stable screen
coordinates and the coalescing scheduler; they do not update the entire
workbench for every pointer event. DMG creation keeps its diagnostic output
outside the source tree and retries bounded transient resource-busy failures.

Verification for this integration is complete. The linked Swift stability run
passed 1,250 tests in 138 suites and the Rust timing run passed 390 cases. The
ARM64 packaged app is signed, contains the Go native plugin and required helper
resources, and excludes retired Java language-server resources. In the packaged
app, Go `main` renders the green gutter entry; left and right clicks both show
Run, Debug, and Modify Run Configuration; generated Go and Rust projects auto-
create runtime configurations; and Go environment, arguments, and working
directory persist in `.lithe/run/local.json`. Go and Rust runs produced their
fixture `GO_OK` and `RUST_OK` output. Raw test, package, and UI evidence is in
`.artifacts/main-merge-*` and `.artifacts/test-stability/`.

## Upstream 0.4.5 integration status (2026-09-21)

Base: fork `fd7d3cd1`; incoming upstream release: `f620ab70` (`v0.4.5`).

The current integration retains the existing project-window, language-tooling,
Run/Debug, and syntax ownership contracts while adding generic Git history
review/recovery and native update behavior. Maven/Spring workflows, bundled Java
toolchains, Windows product code, and Linux.do remain outside this fork. The
verification record above describes the earlier integration; the current
0.4.5 build, package, and installed-app UI checks are pending. Raw integration
records are kept in `.artifacts/upstream-045-050/`.
