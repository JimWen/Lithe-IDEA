#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
cd "$ROOT_DIR"

scripts/verify-rust-core-comments.sh
scripts/verify-rust-core-layout.sh
cargo fmt --manifest-path rust/Cargo.toml -p lithe-core -p lithe-git-host -- --check
node .agents/skills/write-stable-tests/scripts/run-rust-tests-with-timing.mjs \
    --manifest rust/Cargo.toml --package lithe-git-host \
    --suite-timeout-ms 120000 \
    --report .artifacts/test-stability/git-host-rust.json
cargo test --manifest-path rust/Cargo.toml -p lithe-core
node scripts/test-rust-core-link.mjs

case "$(uname -m)" in
    arm64) TRIPLE="arm64-apple-macosx"; RUST_TARGET="aarch64-apple-darwin" ;;
    x86_64) TRIPLE="x86_64-apple-macosx"; RUST_TARGET="x86_64-apple-darwin" ;;
    *) print -u2 -- "Unsupported host architecture: $(uname -m)"; exit 1 ;;
esac

RUST_LIBRARY="$(scripts/build-rust-core.sh --debug --target "$RUST_TARGET")"

SWIFT_LINKER_ARGS=()
if ! /usr/bin/xcrun ld -help 2>&1 | /usr/bin/grep -q -- '-no_warn_duplicate_libraries'; then
    SWIFT_LINKER_ARGS=(-Xswiftc "-ld-path=$ROOT_DIR/scripts/ld-macos13-compat.sh")
fi

swift build --disable-sandbox --triple "$TRIPLE" "${SWIFT_LINKER_ARGS[@]}" \
    -Xswiftc -Xfrontend \
    -Xswiftc -disable-round-trip-debug-types \
    -Xcc -include \
    -Xcc "$ROOT_DIR/scripts/MacOS13SDKCompatibility.h" \
    -Xlinker -force_load \
    -Xlinker "$RUST_LIBRARY"

BRIDGE_BINARY="$(mktemp -t lithe-rust-bridge).out"
trap 'rm -f "$BRIDGE_BINARY"' EXIT
MACOS_SDK="$(xcrun --sdk macosx --show-sdk-path)"
swiftc scripts/RustCoreBridgeVerification.swift \
    macos/Sources/LitheRustCore/bridge.c \
    -sdk "$MACOS_SDK" \
    -target "${TRIPLE}13.0" \
    -Xlinker -force_load \
    -Xlinker "$RUST_LIBRARY" \
    -o "$BRIDGE_BINARY"
"$BRIDGE_BINARY"

BINARY=".build/$TRIPLE/debug/Lithe"
if ! nm -gU "$BINARY" | grep -F "_lithe_core_execute_json" > /dev/null; then
    print -u2 -- "Rust Core symbols are missing from the macOS binary"
    exit 1
fi
if ! nm -gU "$BINARY" | grep -F "_lithe_core_lsp_provider_catalog_json" > /dev/null; then
    print -u2 -- "Rust Core LSP provider catalog symbol is missing from the macOS binary"
    exit 1
fi

# This suite requires the real Core and must never pass via the weak unlinked
# bridge used by the separate Swift-only CI lane.
"$ROOT_DIR/.agents/skills/write-stable-tests/scripts/test-stability-macos.sh" \
    --report "$ROOT_DIR/.artifacts/test-stability/macos-project-metadata.json" -- \
    --filter ProjectMetadataOperationsTests \
    -Xlinker -force_load -Xlinker "$RUST_LIBRARY"

# The C bridge has weak fallbacks for Swift-only tests. This lane must contain
# strong implementations of both new functions before running helper fixtures.
GIT_SYMBOL_TABLE="$(nm -m "$BINARY")"
for git_symbol in _lithe_core_execute_json_with_events _lithe_core_git_askpass; do
    if ! print -r -- "$GIT_SYMBOL_TABLE" | awk -v symbol="$git_symbol" '$NF == symbol && /external/ && !/weak/ && !/undefined/ { found = 1 } END { exit !found }'; then
        print -u2 -- "Strong Git execution symbol is missing from the macOS binary: $git_symbol"
        exit 1
    fi
done

# This explicitly identified integration lane uses isolated repositories and a
# loopback HTTP server. The built app is exercised only in its early helper mode.
cargo build --manifest-path rust/Cargo.toml -p lithe-core
python3 scripts/test-git-execution.py --application "$BINARY"
node --input-type=module -e 'import { writeTestReportArtifacts } from "./.agents/skills/write-stable-tests/scripts/generate-test-report.mjs"; writeTestReportArtifacts(".artifacts/test-stability/git-execution-integration.json");'

LITHE_RUN_GIT_EXECUTION_INTEGRATION=1 \
    ./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh \
    --suite-timeout-seconds 900 \
    --report .artifacts/test-stability/git-console-bridge.json \
    -- --filter 'MacGitHubGitOperationsTests|GitConsolePresentationBridgeTests|GitConsoleLifecycleBridgeTests' -Xlinker -force_load -Xlinker "$RUST_LIBRARY"

print "Rust Core verification passed: comments, Rust tests, Swift bridge, linked symbols, project metadata, and Git execution integration"
