@.agents/skills/develop-lithe/SKILL.md

Read and follow [AGENTS.md](AGENTS.md), including its **Upstream Integration
Principles** confirmed on 2026-09-21. For later upstream integrations:

- Keep the current fork as base; merge requested releases sequentially with
  original commit identities, messages, authors and ancestry preserved.
- Ship macOS only; exclude Windows and Java/framework support increments
  (Maven/Spring/MyBatis/JDT/JDTLS/JDK and related dependencies/resources/CI).
  Review mixed commits by hunk and keep independent generic macOS/shared fixes.
  Preserve the existing Linux.do exclusion.
- Keep the native AppKit/NSTextView editor. Defer Monaco and its bridge,
  frontend dependencies, bundles, minimap and other dependent features until
  an explicit user decision. Adapt useful saving, search, Git and HTML preview
  improvements to the native editor instead.
- Preserve Go/Rust/Python, native windows, plugins, module ownership, document
  leases/freshness, actual replacement Apply, occurrence selection, shared
  Undo/Redo and disk rollback. Keep fork metadata, docs and agent rules.
- Check every merge's scope and static contracts; after a multi-release batch,
  run consolidated timed tests, compile, replace the system installation and
  verify real UI operations. Fix failures, verify installed source identity,
  retain rollback and clean up all test app/helper processes. An explicit user
  verification sequence takes precedence. Do not push or publish unless asked.

For test work also load `.agents/skills/write-stable-tests/SKILL.md`. The full
policy and lifecycle/layout requirements remain in `AGENTS.md`.
