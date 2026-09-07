# Project tools metadata, version 1

`execution.normalizeProjectMetadata` is a pure JSON command. It consumes complete
stdout captured by the host after a successful metadata process exit and drain.
It neither discovers toolchains nor launches processes, downloads dependencies,
reads manifests, or edits files. The host remains responsible for process exit,
timeouts, byte capture, filesystem authorization and workspace/provider identity.

## Request

```json
{
  "id": "metadata-1",
  "operationId": "refresh-1",
  "command": "execution.normalizeProjectMetadata",
  "payload": {
    "language": "rust",
    "workspaceDirectory": "/fixture/workspace",
    "roots": [{"id": "workspace", "path": "/fixture/workspace"}],
    "cargoMetadata": "<complete cargo metadata --format-version 1 stdout>"
  }
}
```

`language` is `rust` or `go`. Rust requires `cargoMetadata`; Go requires
`goModules` and `goPackages`, each containing a whitespace-separated JSON object
stream from `go list`. Opposite-language fields are rejected. Go packages are
ordinary `./...` records, without `-test`, `-compiled` or `-modfile`: manifests
must be in their module directory, and healthy package import paths must match
that directory's suffix under the declared main module. Native discovery must
enforce these flags, rather than accepting inherited GOFLAGS blindly.

The host supplies all authorized location roots, including external workspace
members and Cargo path dependencies. IDs contain 1–64 ASCII letters, digits,
periods, underscores or hyphens. Paths are absolute POSIX paths up to 8 KiB;
repeated separators and `.` normalize, while `..` and NUL fail. Duplicate root
IDs or normalized paths fail. The host freezes the entire mapping for one
workspace incarnation. Adding a more specific root requires a new incarnation.
Mapping uses the longest component prefix and performs no symlink resolution.
It is a portability mapping, not proof of filesystem containment or permission.

`workspaceDirectory` names the opened workspace and anchors the result's
`workspace` location. Cargo's own `workspace_root` may nest anywhere inside it
(a selected manifest that is a package in a subdirectory) but must never leave
it; a cargo root outside `workspaceDirectory` fails the whole request. Go
module directories follow the same containment rule.

## Result

The ordinary Core envelope contains `version: 1`, `language`, `workspace`,
`members`, `defaultMemberIDs`, and `diagnostics`. Every location is
`{"rootID": string, "relativePath": string}`, with `.` naming the mapped root.
Absolute paths never appear in identities. Raw native tool error information
may appear only in diagnostics `details`.

Members contain `id`, `name`, nullable `version`/`languageVersion`, `directory`,
`manifest`, nullable `defaultRun`, `targets`, `features`, `featureEntries`, `dependencies`,
`incomplete`, and `diagnostics`. Cargo dependencies are declarations containing
name/rename/versionReq/kind/optional/defaultFeatures/features/target/location;
they do not claim a resolved dependency graph. Go package imports are retained
on their targets; this command does not infer per-module dependency graphs from
the Go module stream. Non-main Go modules are validated but not workspace members.

`featureEntries` is an additive version 1 field containing `{name, enables}`
items, ordered by the feature name's original UTF-8 bytes. It carries the same
declarations as the unchanged `features` object; `enables` retains the existing
sorted, deduplicated activation expressions without Unicode normalization.
Go returns `{}` and `[]`, respectively. Hosts whose dictionary keys compare
canonically equivalent Unicode as equal must consume the array to preserve
distinct names such as `é` and `e\u0301`. The current Swift consumer requires
this field and fails explicitly on an older Core response instead of falling
back to a lossy dictionary. Core and that consumer ship together; old consumers
may continue reading `features`. Both wire views borrow the same map during
serialization and count toward the existing 32 MiB output limit.

Targets contain `id`, `name`, canonical `kind`, `rawKinds`, `crateTypes`, nullable
`edition`, `directory`, `sources`, nullable `importPath`, `requiredFeatures`,
`runnable`, `testable`, `doctest`, `incomplete`, `imports`, `testImports`,
`externalTestImports`, and `diagnostics`. A source has a `location` and role:
`root` for Cargo; `go`, `cgo`, `test`, `externalTest`, or `ignored` for Go.

Cargo target kind uses `lib` for library crate kinds, the known single kind for
bin/example/test/bench/custom-build, and `unknown` otherwise. Sorted raw kind
and crate-type values remain available. Only bin or example targets with binary
crate type are runnable; required features remain explicit preconditions for
the future action planner. Build scripts and unknown kinds receive no Run/Test
eligibility. Cargo's test/doctest metadata is retained; eligibility is not proof
that a toolchain exists or a build succeeds. `defaultRun` must identify a bin.
Unknown optional JSON fields are ignored for upstream compatibility.

Go target identity uses the main-module manifest and package import path, not a
filename or package display name. Healthy main packages with active Go/cgo
source are runnable. Package Error/DepsErrors/Module.Error and member module
errors prevent Run/Test eligibility. `-e` error records lacking Dir or Module
remain top-level diagnostics and never invent targets. Diagnostics preserve
Err/Pos/ImportStack; absolute or otherwise unsuitable query identifiers are
stored as `Query` inside details with `importPath: null`. An explicit ForTest or
synthetic bracketed import path is rejected; a legitimate `.test` suffix is not.

`defaultMemberIDs: null` means Cargo omitted or supplied null defaults; `[]`
means it explicitly selected none. Defaults must be a unique subset of workspace
members, not merely arbitrary entries in Cargo packages. Go defaults select all
reported main modules. Cargo opaque package IDs are used only to validate these
references and are not returned.

Member IDs are `sha256:` plus lowercase SHA-256 of compact UTF-8 JSON
`[language,{"rootID":rootID,"relativePath":manifestPath}]`, preserving this
object field order. Target IDs hash `[memberID,canonicalKind,name]` for Cargo
and `[memberID,"package",importPath]` for Go. Versions, source filenames,
tool opaque IDs and input ordering do not participate. Unicode strings are not
normalized or case-folded. Moving a manifest or changing the root incarnation
can change IDs; hosts must not treat IDs as persistent filesystem authorization.

Members sort by `(rootID, relativePath)` of their manifest. Cargo targets sort
by `(kind,name)`, Go by importPath. Sources, feature sets, imports and declared
dependencies are ordered deterministically. Diagnostic ordering is deterministic
but the meaningful order inside ImportStack remains intact.

## Failure and resource bounds

Malformed typed items, duplicate member/target identities, missing members,
inconsistent package ownership and unsupported Cargo schema versions fail the
whole snapshot with `parse_failed`. Invalid request/path/budget inputs use
`invalid_request`; unmapped paths use `permission_denied`; unsupported language
uses `not_supported`. Never return a partially valid success tree after dropping
a malformed record. Tool-level Go error records are valid diagnostic data.

Combined stdout is at most 16 MiB. Before typed decoding, a non-allocating scan
checks cancellation every 64 KiB, JSON string tokens up to 64 KiB (including
their closing quote), at most 128 nested containers, and a combined structural
budget of 200000 opening containers/commas. Typed serde decoding retains its
own recursion checks. Limits include unknown optional fields. Roots are at most
128, member records at most 10000, targets/package records at most 100000.
Output is at most 32 MiB; repeated path and diagnostic expansion is charged
before allocating copies. Final bounded serialization enforces the byte cap.

Core checks cancellation before/after bounded decode and while projecting items,
including after the final envelope-value decode. A single bounded serde decode
is not preemptible. The operation deadline still includes its elapsed time; hosts
must keep this work off the UI thread and discard stale results independently.

The executable fixture is
[`project-metadata-v1.json`](../fixtures/execution/project-metadata-v1.json).
Current implementation supplies the shared topology foundation. Native capture,
independent tasks, configuration planning and the Go/Cargo right toolbar are
separate pending deliveries in
[`goland-parity-go-cargo.md`](../../docs/architecture/goland-parity-go-cargo.md).
