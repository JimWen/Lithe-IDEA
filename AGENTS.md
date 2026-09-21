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
