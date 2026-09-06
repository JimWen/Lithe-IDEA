#!/bin/zsh
set -euo pipefail

if (( $# != 1 )) || [[ ! -f "$1" || "${1:t}" != liblithe_core.a ]]; then
    print -u2 -- "Usage: $0 path/to/liblithe_core.a"
    exit 2
fi

ARCHIVE="${1:a}"
archive_digest() {
    local digest_line
    digest_line=$(/usr/bin/shasum -a 256 < "$1")
    print -r -- "${digest_line%% *}"
}
DIGEST="$(archive_digest "$ARCHIVE")"

# Already prepared archives must be stable under repeated wrapper invocations.
if [[ "${ARCHIVE:h:h:t}" == lithe-link ]]; then
    if [[ -L "$ARCHIVE" || "${ARCHIVE:h:t}" != "$DIGEST" ]]; then
        print -u2 -- "Rust link archive does not match its content identity: $ARCHIVE"
        exit 1
    fi
    print -r -- "$ARCHIVE"
    exit 0
fi

LINK_CACHE="${ARCHIVE:h}/lithe-link"
PUBLISHED_ARCHIVE="$LINK_CACHE/$DIGEST/liblithe_core.a"
if [[ -e "$PUBLISHED_ARCHIVE" || -L "$PUBLISHED_ARCHIVE" ]]; then
    if [[ -L "$PUBLISHED_ARCHIVE" || ! -f "$PUBLISHED_ARCHIVE" ]] ||
        [[ "$(archive_digest "$PUBLISHED_ARCHIVE")" != "$DIGEST" ]]; then
        print -u2 -- "Rust link archive cache is invalid: $PUBLISHED_ARCHIVE"
        exit 1
    fi
    print -r -- "$PUBLISHED_ARCHIVE"
    exit 0
fi

mkdir -p "$LINK_CACHE/$DIGEST"
PUBLISH_DIRECTORY="$(mktemp -d "$LINK_CACHE/.publish.XXXXXX")"
trap 'rm -rf -- "$PUBLISH_DIRECTORY"' EXIT
STAGED_ARCHIVE="$PUBLISH_DIRECTORY/liblithe_core.a"
# APFS clone copies avoid duplicating unchanged archive blocks. Other file
# systems still receive an independent copy rather than a mutable symlink.
if ! /bin/cp -c "$ARCHIVE" "$STAGED_ARCHIVE" 2>/dev/null; then
    /bin/cp "$ARCHIVE" "$STAGED_ARCHIVE"
fi
if [[ "$(archive_digest "$STAGED_ARCHIVE")" != "$DIGEST" ]]; then
    print -u2 -- "Rust archive changed while preparing its link snapshot; retry the build"
    exit 1
fi
chmod a-w "$STAGED_ARCHIVE"
# Publish without overwriting a concurrent publisher's snapshot. The staged
# inode is immutable and independent of Cargo's mutable output archive.
if ! /bin/ln "$STAGED_ARCHIVE" "$PUBLISHED_ARCHIVE" 2>/dev/null; then
    if [[ -L "$PUBLISHED_ARCHIVE" || ! -f "$PUBLISHED_ARCHIVE" ]] ||
        [[ "$(archive_digest "$PUBLISHED_ARCHIVE")" != "$DIGEST" ]]; then
        print -u2 -- "Could not publish a valid Rust link archive: $PUBLISHED_ARCHIVE"
        exit 1
    fi
fi
print -r -- "$PUBLISHED_ARCHIVE"
