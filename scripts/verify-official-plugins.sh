#!/bin/zsh

set -euo pipefail

ROOT_DIR="${0:A:h:h}"
cd "$ROOT_DIR"
LEGACY_GO_PACKAGE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --legacy-go-0.3.0)
            [[ $# -ge 2 ]] || { print -u2 -- "Missing legacy Go package path"; exit 2; }
            LEGACY_GO_PACKAGE="$2"
            shift 2
            ;;
        *) print -u2 -- "Usage: $0 [--legacy-go-0.3.0 trusted-package-directory]"; exit 2 ;;
    esac
done
if [[ -n "$LEGACY_GO_PACKAGE" && ! -f "$LEGACY_GO_PACKAGE/plugin.json" ]]; then
    print -u2 -- "Legacy Go package is missing plugin.json: $LEGACY_GO_PACKAGE"
    exit 2
fi

case "$(uname -m)" in
    arm64) TRIPLE="arm64-apple-macosx" ;;
    x86_64) TRIPLE="x86_64-apple-macosx" ;;
    *) print -u2 -- "Unsupported host architecture: $(uname -m)"; exit 1 ;;
esac

SWIFT_BUILD_ARGS=(
    --triple "$TRIPLE"
    -Xswiftc -Xfrontend
    -Xswiftc -disable-round-trip-debug-types
)

# The verifier links the public SDK and shared language resource support. Building
# every product also recompiles the macOS application and exposes this focused
# check to unrelated Swift compiler failures.
swift build "${SWIFT_BUILD_ARGS[@]}" --product LitheOfficialPluginVerifier
PLUGIN_ROOT=$(scripts/build-official-plugins.sh \
    --configuration debug \
    --triple "$TRIPLE")
plugins=("$PLUGIN_ROOT"/*(/N))
for plugin in "${plugins[@]}"; do
    swift run "${SWIFT_BUILD_ARGS[@]}" --skip-build LitheOfficialPluginVerifier "$plugin"
done
print "Verified ${#plugins[@]} current official native plugin package(s)"
if [[ -n "$LEGACY_GO_PACKAGE" ]]; then
    # Use a separate process: old and new bundles share Objective-C class names.
    swift run "${SWIFT_BUILD_ARGS[@]}" --skip-build LitheOfficialPluginVerifier \
        --legacy-go-0.3.0 "$LEGACY_GO_PACKAGE"
fi
