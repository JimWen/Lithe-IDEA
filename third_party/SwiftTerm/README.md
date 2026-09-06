# SwiftTerm typography patch

Lithe compiles SwiftTerm **1.15.0**, revision
`dd2fb8ac5b861e7bf617c872895e338f38165648`, from the minimal source package here.
The upstream library has a font-update path that performs DECSTR; no released
revision provided the required state-preserving typography update when this
patch was prepared. See
[the design](../../docs/architecture/goland-parity-terminal-display.md).

`upstream.json` lists every retained upstream file and its SHA-256 before local
changes. `lithe-typography.patch` contains all changes to upstream files,
including the library-only package manifest. `LICENSE` is unmodified; a second
copy and the local change notice ship in `SwiftTerm_SwiftTerm.bundle/Notices`.
Examples, CLI tools, upstream test suites and CI files are not vendored.

Run `node scripts/verify-swiftterm-source.mjs` from the repository root. This
checks the exact file set, reverses the patch in a temporary copy, then verifies
all restored upstream hashes. It never modifies the source package or SwiftPM
checkouts and needs no network. The rest of Lithe still has remote dependencies.
Build and test wrappers run this check before compilation. Original source
whitespace is preserved through scoped `.gitattributes`; the verifier separately
checks the patch's added lines with strict, explicit Git whitespace rules.

For an upstream merge, review the small patch first. If an upstream release
provides equivalent state preservation and cache invalidation, switch the root
package dependency back to that pinned release and remove this local package
and its verification hook. Do not edit `.build/checkouts`. When refreshing the
pin, recompute the upstream manifest from the immutable Git revision, regenerate
the patch against those exact files, and run protocol, PTY, Metal and package
acceptance again.
