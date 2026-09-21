# Git Execution and Project Console

## Scope and status

Integrates the generic Git execution contract from upstream `99b2fa00` into the
macOS fork. Integration validation is pending; upstream reports are historical
reference only. Windows adapters and product changes are excluded. Existing
Go, Rust, and Python language modules keep their current ownership.

## Ownership

`lithe-core` validates requests, applies request-scoped execution policy, plans
Fetch, sanitizes diagnostics, and projects console snapshots. The new
`rust/lithe-git-host` crate owns native executable discovery, Unix child process
groups, bounded output capture, cancellation cleanup, and loopback AskPass.
Neither Swift services nor views spawn Git or implement credential transport.

Each project window constructs one `MacServiceContainer`. That container creates
one `GitExecutionJournal` and passes it to the Rust bridge and Git module. GitHub
and Git feature workflows therefore use the same window console. Settings are
shared application preferences; histories and authentication challenges remain
window owned. Switching a selected checkout preserves that window's history.

The synchronous event C ABI invokes borrowed-string callbacks serially on the
caller worker. Swift copies each event within the callback. `GitService` carries
operation identity and task cancellation to detached native work. The feature
coalesces publication at 100 ms and cancels and joins its pump. Console rendering,
search, expansion, scrolling, and split layout remain view-local.

`MacApplicationEntryPoint` handles explicit or environment-selected AskPass
before invoking `LitheApp.main()`. It must not create a window, updater, plugin
runtime, or shared GUI state in helper mode.

## Behavior and verification pending

The console retains planned, running, completed, and unconfirmed states without
fabricating command execution from preflight. Clearing visible history keeps
running requests cancellable and suppresses their late output. Per-remote Fetch
retains partial successes, explicit counts, and configuration provenance.
Authentication answers are one-shot, bounded, and absent from retained events.

Required checks after sequential integration include Rust comments/format,
Core and host timing lanes, strong linked event/AskPass symbols, C ABI local
Git/HTTP fixtures, linked Swift console tests, full affected Swift validation,
service/shared boundaries, product packaging, and installed-app UI acceptance.
No current integration check or installed-app result is claimed here.

The wire contract and fixtures are specified in
[rust-core-api](../../shared/contracts/rust-core-api.md). Local preparation,
conflict decisions, and later raw verification evidence belong under
`.artifacts/upstream-045-050/`.
