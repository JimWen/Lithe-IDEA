# Shared Rust Test Stability

The report generator, static verifier, Swift runner, and Rust runner use Node.js.

## Rust

- Prefer channels, barriers, and injected clocks to `thread::sleep`. Channel
  receives used for coordination require `recv_timeout` or an equivalent
  bounded operation.
- A thread may be joined only after a bounded signal proves that it reached a
  terminating path. Keep cleanup capable of releasing all barriers and killing
  child processes.
- Test subprocesses require a watchdog and process-tree termination. Reading to
  EOF or calling `wait` is not a timeout strategy.
- Avoid shared global environment mutation. If unavoidable, serialize access
  with an owned guard and restore the previous value in teardown.

Run the Rust timing harness on macOS:

```bash
node .agents/skills/write-stable-tests/scripts/run-rust-tests-with-timing.mjs --manifest rust/Cargo.toml --package lithe-core
```

The runner compiles once, enumerates the produced test binaries, and runs every case individually with a process timeout and duration report. One suite deadline covers compilation, enumeration, and every test process. HTML and JUnit reports are written under `.artifacts/test-stability/`.


The Git execution verification lane runs `lithe-git-host` separately from
`lithe-core`: Cargo does not run a dependency's own tests when testing Core.
Native Git process and AskPass cases write `git-host-rust.json`.

The Rust runner accepts repeatable `--test-budget prefix=milliseconds` options.
The most specific matching prefix controls a case's process deadline and its
HTML/JUnit classification; the suite deadline still caps all work. Apply scoped
budgets only to measured integration costs, never to hide unbounded waits or
assertion failures. Record each case's effective `maxMs` in the report.
