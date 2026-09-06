#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
cd "$ROOT_DIR"
node "$ROOT_DIR/scripts/verify-swiftterm-source.mjs"

FORWARDED_ARGS=("$@")
SKIP_BUILD=false
for argument in "${FORWARDED_ARGS[@]}"; do
    [[ "$argument" == --skip-build ]] && SKIP_BUILD=true
done
RUST_LINK_INDEX=0
RUST_LINK_PREFIX=""
PREVIOUS_LINKER_ARGUMENT=""
for (( index = 1; index <= ${#FORWARDED_ARGS}; index++ )); do
    argument="${FORWARDED_ARGS[index]}"
    prefix=""
    if [[ "$argument" == -Xlinker ]] && (( index < ${#FORWARDED_ARGS} )); then
        (( index += 1 ))
        linker_argument="${FORWARDED_ARGS[index]}"
    elif [[ "$argument" == -Xlinker=* ]]; then
        linker_argument="${argument#-Xlinker=}"
        prefix="-Xlinker="
    else
        continue
    fi
    if [[ "$PREVIOUS_LINKER_ARGUMENT" == -force_load && "${linker_argument:t}" == liblithe_core.a ]]; then
        if (( RUST_LINK_INDEX != 0 )); then
            print -u2 -- "Only one Rust Core force-load archive may be supplied"
            exit 2
        fi
        RUST_LINK_INDEX=$index
        RUST_LINK_PREFIX="$prefix"
        RUST_LINK_ARCHIVE="$linker_argument"
    fi
    PREVIOUS_LINKER_ARGUMENT="$linker_argument"
done
if (( RUST_LINK_INDEX != 0 )) && [[ "$SKIP_BUILD" == false ]]; then
    RUST_LINK_ARCHIVE="$("$ROOT_DIR/scripts/prepare-rust-core-link.sh" "$RUST_LINK_ARCHIVE")"
    FORWARDED_ARGS[RUST_LINK_INDEX]="$RUST_LINK_PREFIX$RUST_LINK_ARCHIVE"
fi

SWIFT_ARGS=(
    test --disable-sandbox
    -Xswiftc -Xfrontend
    -Xswiftc -disable-round-trip-debug-types
    -Xcc -include
    -Xcc "$ROOT_DIR/scripts/MacOS13SDKCompatibility.h"
)

if ! /usr/bin/xcrun ld -help 2>&1 | /usr/bin/grep -q -- '-no_warn_duplicate_libraries'; then
    SWIFT_ARGS+=(-Xswiftc "-ld-path=$ROOT_DIR/scripts/ld-macos13-compat.sh")
fi

swift "${SWIFT_ARGS[@]}" "${FORWARDED_ARGS[@]}"
