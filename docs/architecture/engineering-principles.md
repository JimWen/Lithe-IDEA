# Lithe Engineering & Lightweight Performance Principles

> **Status**: Active Governance (Last synced: 2026-11-27, branch `feat/t3code-ai-agent`)
> **Design Goal**: A **lightweight, high-performance, native macOS IDE** (AppKit/`NSTextView` + Swift 6 modular kernel + deterministic Rust Core), delivering JetBrains-grade daily ergonomics for **Go / Rust / Python** + native **AI Agent** collaboration at a fraction of JVM memory and startup cost.

Adopted from our cross-repository closed-loop engineering standards (`doris-qt` governance) and refined from Lithe's actual macOS / Rust Core / sidecar production history, these rules apply to every implementation, review, and optimization batch.

---

## 1. Core Architectural Invariants

1. **macOS-Only Native Product**:
   - Ship macOS only (`arm64` Apple Silicon primary). Exclude Windows targets/CI, Java ecosystem increments (Maven/Spring/MyBatis/JDT/JDTLS/bundled JDK), Linux.do, and Monaco editor migration.
   - Retain native AppKit `NSTextView` with stable native `UndoManager`, UTF-16 surrogate-pair safety, and IME `NSTextInputClient` marked-text deferral.
2. **Strict Layer Ownership** (enforced by `./scripts/verify-service-boundaries.sh` and `./scripts/verify-module-boundaries.sh`):
   - `macos/Sources/Lithe/Views/`: SwiftUI/AppKit presentation only; never import or call Rust C ABI directly; never spawn OS processes or open raw file handles.
   - `macos/Sources/Lithe/{Core,Services,Application,Models}/` + `LitheCoreContracts` + `Lithe*Module`: **zero `SwiftUI` / `AppKit` imports**.
   - `macos/Sources/Lithe/Platform/MacOS/`: macOS adapters, process groups, keychains, plugin loaders, and composition root (`MacServiceContainer`).
   - `Plugins/mac/Official/{GoSupport,RustSupport,PythonSupport}`: independent signed native bundles statically unlinked from executable target `Lithe`; import only `Foundation`, `LitheCoreContracts`, `LitheModuleAPI`, `LitheLanguageExtensionSupport`; never directly spawn `Process`/`Pipe`/`FileHandle`/`FileManager`.
   - `rust/lithe-core/`: deterministic, platform-neutral Rust engine linked statically into `Lithe` via JSON C ABI (`-force_load`).
   - `rust/lithe-db-sidecar/`, `rust/lithe-db-mcp/`, `rust/lithe-git-host/`: isolated helper executables with bounded stdio/RPC protocols.
3. **Frozen Native Plugin ABI v1**:
   - Never add stored properties to non-resilient v1 structs returned by value across `.bundle` boundaries (`LanguageServerExtensionConfiguration`, `LanguageSyntaxProfile`).
   - Extend plugin capabilities exclusively via opt-in protocols (`LanguageServerInitializationOptionsProviding`, `LanguageSyntaxExtensionProviding`) or side-table structs (`LanguageSyntaxEnrichment`) decoded from `Resources/syntax.json`.

---

## 2. Rust Core & Helper Development Principles

1. **Zero-Panic FFI Boundary (`rust/lithe-core/src/runtime/ffi.rs`)**:
   - Every `extern "C"` entry point MUST wrap execution in `std::panic::catch_unwind(AssertUnwindSafe(...))` and return a structured JSON error (`ErrorCode::Unknown`) or safe sentinel (`0`) rather than unwinding across C ABI (UB / instant IDE abort).
   - Never use unchecked `Instant::now() + Duration` for caller-supplied timeouts; always use `checked_add`.
   - Pair every allocated `CString::into_raw` with `lithe_core_free_string`.
2. **Subprocess Signal, Safety & Lifecycle Discipline**:
   - Because `lithe-core` is linked as a static library into a macOS GUI app (no Rust `main()` installing `SIG_IGN` on `SIGPIPE`), every spawned child process with piped `stdin` MUST apply `libc::fcntl(fd, libc::F_SETNOSIGPIPE, 1)` on macOS so writing to a crashed server (`gopls`, `rust-analyzer`, etc.) returns `EPIPE` instead of terminating Lithe.
   - Never pass untrusted arguments without `--`; use `--literal-pathspecs` and NUL-delimited `-z` output for Git path operations.
   - Never use unbounded `Command::output()` on user repositories; route through bounded capture with explicit timeout, cooperative cancellation, and output byte caps (e.g., 32 MiB).
   - Reap every child process (LSP, Git, SSH tunnel, DB sidecar) via `Drop` + `wait()` or process-group termination; never leave orphans or zombies.
3. **Zero Hot-Path O(N²) & Idle CPU Discipline**:
   - Build line-start / UTF-16 offset tables once per document (`O(n)`) for LSP edits, symbol extraction, completions, hover, and breakpoint relocation; never rescan from byte 0 per symbol or edit.
   - Prefer single-pass scanning and trigram pruning (do not disable trigrams globally for non-ASCII comments).
   - Avoid fixed-interval busy polling (e.g. 10ms wakeups in idle LSP/Git loops); prefer `Condvar`, event-driven I/O, or adaptive backoff.
4. **Symlink-Safe, Bounded Filesystem Traversal**:
   - Recursive directory scans MUST inspect `entry.file_type()` (never `path.is_dir()`, which follows symlink cycles like `a -> .` or Bazel `bazel-*`).
   - Skip unreadable directories gracefully (`let Ok(entries) = fs::read_dir(...) else { continue; }`) rather than failing the entire workspace command.
   - Enforce explicit visited-entry/byte budgets and share a single canonical `VisibilityRules` implementation across file tree, search, replacement, and Local History.
   - Reject FIFOs / non-regular files before blocking reads (`read_regular_file`), and use atomic temp-file + rename for durable writes.
5. **Security & Data Integrity at the True Boundary**:
   - Enforce database read-only guarantees inside `lithe-db-sidecar` (`BEGIN READ ONLY ... ROLLBACK`, `START TRANSACTION READ ONLY`, `PRAGMA query_only=ON`), never solely via client-side SQL text heuristics.
   - Reject `<unsupported>` cells before writing SQL recovery snapshots; execute PG/SQLite restore DROP + INSERT atomically inside transactions.
   - Write local secrets atomically with `0o600` (`O_CREAT|O_EXCL|O_NOFOLLOW`), never create-then-`chmod`.
6. **Code Style & Comments**:
   - Every `pub` item in `rust/lithe-core/` MUST have English Rustdoc (`./scripts/verify-rust-core-comments.sh`); format with `cargo fmt --manifest-path rust/Cargo.toml --all --check`.

---

## 3. macOS Swift & Native UI Performance Rules

1. **Zero `@MainActor` Blocking I/O or Subprocess Spawns**:
   - Never call synchronous `FileManager` scans, Rust heavy queries, or `MacProcessRunner` (`java_home -V`, `git`, `go`, `cargo`) directly on `@MainActor`. Use `Task.detached` or cached background snapshots (`ProjectRuntimeService.javaRuntimes`).
   - Deduplicate external file-change batches with `Set` (`O(changes + files)`), never `Array.contains` or nested `projectFiles.contains` (`O(changes × files)`).
2. **Smooth Editor, Tab Switch & Streaming Rendering**:
   - Preserve the bounded Warm Tab Pool (`EditorAreaView`, max 8 plain-code docs ≤ 512 KiB) with immediate close eviction, deactivation `breakUndoCoalescingForDeactivation()`, and registry-revision-aware highlight invalidation.
   - Never call full-document `NSLayoutManager.ensureLayout(for: textContainer)` on caret movement or tab click; use `ensureLayout(forCharacterRange:)` or `ensureLayout(forBoundingRect:)`.
   - Use O(1) revision counters (`textRevision`, `gitCommitsVersion`, `LanguageSyntaxProfileRegistry.revision`) instead of hashing full strings/arrays in SwiftUI `.task(id:)` or `updateNSView`.
   - Coalesce high-frequency streaming text deltas (e.g., 40ms leading/trailing window in `AIAgentFeatureModel`) with synchronous flush barriers before structural events, approvals, or completion.
   - Pause background timers and `CVDisplayLink` (`FrameRateMonitor`) when `NSApp` resigns active.
3. **High-Performance Resizable Panels & Native Focus/IME**:
   - Use `LitheSplitPaneView` + `SplitHandleView` for all draggable panels; commit layout widths only on drag end.
   - Route non-modal shortcuts through `MacFocusHandoffCoordinator`; defer IME marked text (`hasMarkedText()`) in every local key monitor (`MacShortcutDetector`, `MacReturnKeyMonitor`, `CodeTextView`).
   - Use `.litheContextMenu` everywhere (never raw SwiftUI `.contextMenu`) and localize all `LitheCommandCatalog` commands in both `en.lproj` and `zh-Hans.lproj`.
4. **Concurrency & Operation-ID Hygiene**:
   - Guard every async subprocess/network/refresh callback with an `operationID` or `generation` token (`RunService`, `LanguageTestService`, `GitFeatureModel`, `SearchFeatureModel`, `AIAgentFeatureModel`) so late callbacks from restarted or cancelled work can never clear or pollute the active session.
   - Provide `contentIdentity: { featureIdentity(...) }` on every optional module renderer in `WorkbenchModuleUIComposition` wrapped in `.equatable()`.

---

## 4. Closed-Loop Workflow: Build -> Review -> Test -> Doc Sync

For every non-trivial feature, optimization, or bug-fix batch:

1. **Red -> Green Regression Tests**: Reproduce the bug or performance invariant with a bounded deterministic test (following `.agents/skills/write-stable-tests/SKILL.md`) before declaring completion.
2. **Independent Codex CLI Review**: Run `codex review -c model="gpt-6.1-sol" -c model_reasoning_effort="xhigh" -c service_tier="fast" --uncommitted` (or latest available Sol model) and resolve all P0/P1 and actionable P2 findings until clean.
3. **Full Multi-Dimensional Verification**:
   - All static/contract/boundary/stability checks: `cargo fmt --check`, `verify-rust-core-comments.sh`, `verify-rust-core-layout.sh`, `verify-service-boundaries.sh`, `verify-module-boundaries.sh`, `verify-shared-contracts.sh`, `verify-test-stability.sh`, `verify-core.sh`, `verify-git-graph.sh`, `verify-official-plugins.sh`, `git diff --check`.
   - Full timed Rust workspace suite (`run-rust-tests-with-timing.mjs`) and full timed macOS Swift suite (`test-stability-macos.sh` with `SDKROOT=MacOSX26.5.sdk`, `LITHE_SWIFT_BUILD_SYSTEM=native`, `-Xlinker -force_load`).
4. **Clean Release Packaging & Live Verification**:
   - Commit cleanly by logical feature batch (never mix unrelated changes), build Release from clean `HEAD` (`LITHE_ARCH=arm64 ./scripts/package-app.sh`), verify `LitheBuildGitDirty == false` + `codesign --verify --deep --strict`, safely replace `/Applications/Lithe.app` with rollback protection, launch/quit live check, and confirm **zero leftover Lithe/LSP/DAP/sidecar processes**.
5. **Mandatory Documentation Sync (every completed batch)**:
   - Update:
     - [docs/architecture/goland-parity-implementation.md](goland-parity-implementation.md) (Architecture & Feature Progress: Done / Todo / Deferred)
     - [docs/architecture/performance-optimization.md](performance-optimization.md) (Performance Baselines, Completed Optimizations, Prioritized Review Backlog)
     - Feature-specific doc (e.g., [plugin-architecture.md](plugin-architecture.md), [ai-agent-t3code-done.md](ai-agent-t3code-done.md))
     - [AGENTS.md](../../AGENTS.md) when baselines or pitfall guardrails evolve.
   - Record ONLY verified numbers and honest limitations; never invent unmeasured metrics.
