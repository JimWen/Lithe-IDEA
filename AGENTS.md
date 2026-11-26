# Lithe Agent Entry Point

Before any work in this repository, load and follow the `develop-lithe` skill
at `.agents/skills/develop-lithe/SKILL.md`. That skill is the single source of
truth for AI coding and verification rules, including the required Rust Core
comment standard.

If a task creates, modifies, or reviews test code or test infrastructure,
additionally load `.agents/skills/write-stable-tests/SKILL.md` before
proceeding. That skill defines the mandatory bounded-wait, deterministic-time,
cleanup, and per-test timing rules for macOS and shared Rust.

If a task prepares, validates, or publishes a stable Lithe release,
additionally load `.agents/skills/release-lithe/SKILL.md` before changing
release notes, version metadata, tags, or release workflows.

## Architecture Documentation

Follow the "Maintain architecture documents by feature" section of
[develop-lithe](.agents/skills/develop-lithe/SKILL.md#maintain-architecture-documents-by-feature)
when creating, updating, renaming, or completing architecture documents. It owns
the feature naming, `-done` status, acceptance summary, and reference-update rules.

## Upstream Integration Principles

The following fork policy was confirmed on 2026-09-21. Apply it to subsequent
integrations from `https://github.com/1lck/Lithe-IDEA` unless the user explicitly
changes the scope.

- Use the current fork branch as the base and integrate the requested upstream
  releases in order. Preserve original upstream commit identities, authors,
  messages and ancestry with real merge commits; do not squash or rewrite the
  upstream history. Resolve excluded changes out of the resulting tree and
  record the retained, adapted and excluded scope.
- Ship macOS only. Exclude Windows implementation, plugins, resources, build
  dependencies and CI increments. Retain platform-neutral Rust/contracts and
  generic fixes actually used by macOS, even when their upstream commit also
  contains excluded platform changes.
- Exclude Java ecosystem and framework support increments, including Maven,
  Spring, MyBatis, JDT/JDTLS, bundled JDKs and their UI, dependencies, resources,
  tests and packaging. Inspect mixed commits by behavior and hunk; retain
  independent generic improvements. Preserve existing compatibility types and
  ordinary text handling when needed; this policy is not a blanket identifier
  deletion. Keep the fork's existing Linux.do exclusion.
- Retain the native AppKit/NSTextView editor. Monaco migration is deferred:
  exclude its editor replacement, JS bridge/model/undo path, frontend toolchain
  and bundles, and features implemented only by Monaco (including its minimap
  and theme integration). Do not add nonfunctional settings for excluded
  features. Independently useful fixes such as guarded saving, external-file
  observation, search, Git, or HTML preview may be adapted to the native editor.
  Reconsidering the editor engine requires a separate explicit user decision.
- Preserve the fork's Go/Rust/Python capabilities, official plugins, native
  project windows, module ownership and terminal behavior. Preserve mutation
  leases, document freshness, actual project-replacement Apply, selected-file
  and occurrence exclusions, shared Undo/Redo and disk compensation. Adapt to
  existing owners instead of restoring deleted upstream coordinators.
- Keep fork version metadata, release policy, architecture documents and agent
  rules unless the requested task explicitly changes them. Merging an upstream
  release does not authorize publishing, pushing, creating tags or replacing
  the fork's release identity.
- Check scope, conflicts, contracts, boundaries and whitespace for each merge.
  For a requested multi-release batch, finish the integrations and then run the
  consolidated affected test suites with timing reports, build the final app,
  replace the installed system app, and perform corresponding real UI actions.
  Fix and reverify failures; compilation or static parsing alone is not feature
  acceptance. Verify the installed app matches the committed source, preserve
  rollback during replacement, record actual results and limitations, and
  clean up app/helper processes. Follow any explicit per-release verification
  sequence requested by the user instead of this batch default.

`CLAUDE.md` summarizes the same policy and points here for the full rules.

## Test Process Lifecycle and Cleanup

Unless the user gives a specific instruction to keep a process running, any
Lithe application started for building, testing, debugging, previewing, or
verification must be shut down when the task or test run is complete. Clean up
all child processes, helper processes, temporary app instances, and related
resources, then verify that no Lithe processes remain before handing the work
back. Do not launch duplicate Lithe instances during repeated checks, and do
not leave test-built applications open in the user's application list. If a
process cannot be stopped cleanly, report it explicitly and make a bounded
best-effort cleanup before continuing.

## High-Performance UI Interaction and Resizable Layout Requirements

When working on draggable splitters, resizable panels, continuous dragging,
scrolling, or other high-frequency UI interactions, prioritize reusing the
project's existing high-performance layout containers and interaction
components. Do not quickly implement these behaviors by stacking custom
`DragGesture` handlers in a business parent view, writing to multiple `@State`
properties on every event, or duplicating splitter logic.

- Resizable macOS panels must use `LitheSplitPaneView` and `SplitHandleView`
  whenever possible. If they genuinely cannot be reused, explain why in the
  change summary and preserve the same behavioral contract.
- Drag handling must use a stable coordinate space, preferably global
  coordinates for continuous dragging, to prevent the moving splitter from
  changing the coordinate origin and causing jumps.
- High-frequency drag events must be throttled, coalesced, or filtered with a
  dead zone. Do not trigger unnecessary parent-view reconstruction on every
  pointer event. Keep mutable size state in a local layout container whenever
  possible so dragging does not recompute the entire feature page.
- Provide explicit minimum and maximum sizes and available-space constraints so
  adjacent panels retain their minimum usable widths. Window resizing, panel
  hiding, and panel restoration must not produce negative sizes or layout
  overflow.
- Interaction behavior should match existing Git, editor, and tool windows,
  including hover/drag highlighting, the platform-appropriate resize cursor,
  help text, and accessibility labels.
- If sizes must persist across refreshes or restarts, commit the final size
  through the existing layout-persistence mechanism rather than continuously
  writing to persistent storage during dragging.
- After adding or modifying this type of UI, at minimum complete the relevant
  product build, `git diff --check`, and boundary checks. During code review,
  explicitly confirm that dragging does not cause high-frequency full-page
  redraws.

These requirements apply to the shipped macOS product and retained shared
contracts. They do not authorize restoring the excluded Windows product.

## Closed-Loop Development, Quality & Acceptance Principles

Adopted from our cross-repository engineering standards (see `doris-qt`
governance) and refined from Lithe's actual macOS / Rust Core history, apply
these rules to every non-trivial fix, refactor, or feature batch:

### 1. Architecture, Performance & Concurrency Guardrails

- **Enforce strict layer ownership**: keep SwiftUI/AppKit out of `Core/`,
  `Services/`, `Application/`, `LitheCoreContracts`, and `Lithe*Module`; keep
  macOS platform adapters in `macos/Sources/Lithe/Platform/MacOS/`; keep
  deterministic cross-platform logic in `rust/lithe-core/`; keep DB sidecar
  runtime logic in `rust/lithe-db-sidecar/` & `rust/lithe-db-mcp/`; keep
  official external language bundles in `Plugins/mac/Official/`. Validate with
  `./scripts/verify-service-boundaries.sh` and
  `./scripts/verify-module-boundaries.sh`.
- **Zero hot-path O(N²), redundant redraw, or unbounded work debt**:
  - Prefer single-pass lexing/scanning over overlapping multi-pass regexes for
    syntax highlighting and SQL analysis.
  - Use O(1) version counters rather than hashing large arrays in SwiftUI
    `.task(id:)` identities, and avoid redundant `@Published` emissions on
    unchanged or no-op resets (e.g., `EditorChromeModel.reset()`).
  - Bound background work and buffers (throttled Local History pruning, diff
    line-count precomputation and similarity caps, bounded subprocess output
    caps, and paged/backend-filtered Git history).
- **Concurrency, lifecycle, and process-ownership discipline**:
  - Deduplicate concurrent `ModuleRuntime.activate(_:)` calls in flight without
    making `shutdown(_:)` block on gated activations.
  - Coordinate workspace switches by awaiting `awaitModuleRuntimeShutdown()`
    before lazy workspace-module activation.
  - Register every spawned child process (LSP, DAP, Run, project tools, SSH
    tunnels) with `ManagedProcessRegistry` / `MacProcessGroup` or Rust `Drop` +
    `wait()` so teardown leaves neither orphans nor zombies.
- **Security & edit-transaction hygiene**:
  - Write local secrets atomically with `0o600` (`O_CREAT|O_EXCL|O_NOFOLLOW`),
    never via create-then-`chmod`.
  - Prevent subprocess/SSH argument or shell injection (`--` separator,
    allowlisted tokens, no unsanitized `ProxyCommand`).
  - Preserve mutation leases, document freshness checks, shared Undo/Redo, and
    disk compensation for multi-file edits, and roll back multi-statement DB
    transactions on intermediate failure.

### 2. Production-Verified Pitfalls Checklist (Do Not Regress)

Each item below corresponds to a real defect diagnosed in Lithe's history; keep
its regression tests intact:

1. **Swift 6.2.4 `IRGen` crash on bare `swift test`**: always execute macOS
   tests via `./scripts/test-macos.sh` or
   `./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh` (which
   pass `-disable-round-trip-debug-types`, `MacOS13SDKCompatibility.h`, and
   `-Xlinker -force_load` for Rust Core).
2. **Shortcut focus handoff & keystroke leakage (`⌥F12` / `⌘⇧O` / `⇧ ⇧`)**:
   never dispatch non-modal shortcuts via async `Task { @MainActor }` without
   synchronously detaching the active editor first responder through
   `MacFocusHandoffCoordinator`; keep early terminal input buffered until the
   PTY starts, keep Search Everywhere input on native AppKit without overlay
   animations, defer plain Control chords to `LitheTerminalView` (`#1360`), and
   defer marked text to `NSTextInputClient` (IME).
3. **`ModuleRuntime` concurrent activation vs project-switch teardown**: keep
   in-flight deduplication in `activate(_:)` (prevents dual `gopls` spawns),
   but never `await` in-flight activations inside `shutdown(_:)` (deadlocks
   gated project-switch teardown and races `openProjectDirectly` against lazy
   activations). Workspace module activators (Git/Execution/Debug/LSP) must
   await `awaitModuleRuntimeShutdown()` first.
4. **Restored/background tabs & cross-file LSP freshness**: synchronizing only
   `activeDocument` on server ready/restart leaves restored sibling tabs without
   a server snapshot and triggers `staleSource` rejections during rename. Keep
   full provider-tab synchronization on ready/restart and sibling-tab sync in
   `captureLanguageEditContext`.
5. **Plugin-owned debuggers & `/tmp` symlinks**:
   `PluginLanguageProviderCatalogSource` strips `.debugAdapter` when
   `debugModuleID` is missing, and `LanguagePackRegistry` omits host defaults
   for extension-owned languages. Export `.languageDebugExtension(id)` without
   mutating frozen v1 plugin manifests, avoid redirecting non-Java `.currentFile`
   debug launches to `.javaMain`, and match breakpoint/frame URLs via
   `resolvingSymlinksInPath().standardizedFileURL` (`/tmp` vs `/private/tmp`).
6. **LSP capability honesty & protocol fixtures**:
   `shared/fixtures/lsp/client-initialize-v1.json` locks emitted capabilities.
   Keep `workspace.applyEdit: false` and resource operations unadvertised until
   their host transactions exist; probe nested flags
   (`renameProvider.prepareProvider`, `resolveProvider`) in both static
   `initialize` and dynamic `client/registerCapability`/`unregisterCapability`;
   keep `.prepareRename` separate from `.rename`.
7. **Multi-language search, trigram & replacement Apply guards**: index symbols
   across Go/Rust/Python/JS-TS/C-family/Java (not Java-only); do not disable
   trigrams for whole files solely on non-ASCII content; never classify binary
   or unindexed files as `parse_failed` in replacement previews (which blocks
   Apply).
8. **Git history, diff, blame & stash correctness**: run filtered Git log
   queries in the Rust backend with `--date=format-local:` (not author
   timezone); avoid O(N²) line counting in `parse_diff`; check `stash@{0}` OID
   before reporting auto-stash conflicts; propagate non-zero `git diff` exit
   codes; inject `GIT_EDITOR=true` on `--continue`; parse `git blame --porcelain`
   content after the leading `\t` with 40/64-char hex OID validation.
9. **Database sidecar correctness & tunnel safety**: decode SQLite/`AnyRow`
   cells by runtime value type (never `<unsupported>` on expression columns);
   escape MySQL backslashes and format decimals verbatim in SQL exports; emit
   `IS NULL` for null mutation keys; strip comments/strings before dangerous-SQL
   checks; roll back SQL Server transactions on error; reap `SshTunnel` in
   `Drop`.
10. **Native `NSTextView`, UTF-16 & localization invariants**: preserve native
    `UndoManager` across editor lifetimes, never split UTF-16 surrogate pairs
    in caret/selection/edit offsets, keep `EditorChromeModel` silent on no-op
    resets, and add both `en.lproj` and `zh-Hans.lproj` `Localizable.strings`
    entries for every command added to `LitheCommandCatalog` (enforced by
    `AppLocalizationTests`).

### 3. Multi-Dimensional Verification Gates & Acceptance Baseline

For any significant functional, concurrency, protocol, search, Git, debug, or
database change, do not declare completion from a narrow unit filter alone. Run
the full applicable verification matrix and iterate red → green until all gates
pass:

1. **Static, contract & boundary gates (must be 0 errors/warnings)**:
   - `cargo fmt --manifest-path rust/Cargo.toml --all --check`
   - `./scripts/verify-rust-core-comments.sh` & `./scripts/verify-rust-core-layout.sh`
   - `./scripts/verify-service-boundaries.sh` & `./scripts/verify-module-boundaries.sh`
   - `./scripts/verify-shared-contracts.sh`
   - `./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh`
   - `./scripts/verify-core.sh`, `./scripts/verify-git-graph.sh`,
     `./scripts/verify-official-plugins.sh`
   - `git diff --check`
2. **Full timed test suites (baseline as of 2026-11-26, commit `36e45432`)**:
   - **Rust workspace timed suites** (`run-rust-tests-with-timing.mjs`):
     **564/564** (`lithe-core` 535, `lithe-db-sidecar` 19, `lithe-db-mcp` 4,
     `lithe-git-host` 6).
   - **macOS full Swift timed suite** (`test-stability-macos.sh` with
     `-Xlinker -force_load -Xlinker "$RUST_LIB"`): **1,630/1,630** across 193
     suites.
   - **Rust Core & C-bridge integration** (`./scripts/verify-rust-core.sh`):
     Swift C-bridge, strong linked symbols, `ProjectMetadataOperationsTests`,
     `test-git-execution.py`, and Git/LSP/Run bridge integration suites.
3. **Release packaging, real toolchain smoke & installed-app verification**:
   - Build Release from clean committed `HEAD` (`LITHE_ARCH=arm64 ./scripts/package-app.sh`)
     and verify `LitheBuildGitRevision == HEAD`, `LitheBuildGitDirty == false`,
     `codesign --verify --deep --strict`, `arm64` slices, strong Rust symbols,
     packaged `GoSupport.bundle`, and absence of retired JDK/JDTLS/Linux.do
     resources.
   - Run bounded real-tool smoke checks matching the change (e.g., real `gopls`
     protocol negotiation/`prepareRename`/`rename`, real `cargo + lldb-dap`
     breakpoint + locals inspection, packaged `lithe-db-sidecar` SQLite query).
   - When replacing `/Applications/Lithe.app`, stage with `ditto`, preserve a
     rollback copy until post-install `codesign` + SHA-256 + launch/quit checks
     succeed, and confirm zero leftover Lithe/LSP/DAP/sidecar processes.
4. **Zero-tolerance correctness vs rational engineering stop boundaries**:
   - Functional regressions, data corruption, silent wrong results, races, and
     leaks have zero tolerance: locate the root cause, add a deterministic
     bounded regression test, fix, and re-verify.
   - Only stop pursuing further optimization or parity scope when the next
     increment would violate layer/fork boundaries, require disproportionate
     complexity, or depend on tools/services absent from the current host—and
     always record the exact gap and trade-off honestly.
5. **Mandatory doc sync, commit hygiene & milestone reporting**:
   - After major verified batches, update the owning feature documents
     (`docs/architecture/goland-parity-implementation.md`,
     `docs/architecture/goland-parity-b6-refactor.md`,
     `shared/contracts/rust-core-api.md`, `README.zh-CN.md`, `README.md`, and
     this file when baselines/pitfalls change) with only actually verified
     results and honest limitations.
   - When asked to commit, split commits cleanly by logical feature batch (do
     not push or tag unless explicitly requested).
   - On long multi-stage tasks, report concise milestone updates after each
     stage (scope finished, verified numbers, regressions caught, next step)
     instead of remaining silent until the end.
