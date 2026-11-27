#!/bin/zsh

set -euo pipefail

ROOT_DIR="${0:A:h:h}"
CONFIGURATION="debug"
TRIPLE=""
OUTPUT_DIR=""
SIGNING_IDENTITY="${LITHE_CODESIGN_IDENTITY:--}"
PLUGIN_ID=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --configuration) CONFIGURATION="$2"; shift 2 ;;
        --triple) TRIPLE="$2"; shift 2 ;;
        --output) OUTPUT_DIR="$2"; shift 2 ;;
        --plugin-id) PLUGIN_ID="$2"; shift 2 ;;
        *) print -u2 -- "Usage: $0 --triple triple [--configuration debug|release] [--output directory] [--plugin-id id]"; exit 2 ;;
    esac
done

if [[ "$CONFIGURATION" != "debug" && "$CONFIGURATION" != "release" ]]; then
    print -u2 -- "Unsupported configuration: $CONFIGURATION"
    exit 2
fi
case "$TRIPLE" in
    arm64-apple-macosx) TARGET="arm64-apple-macosx13.0" ;;
    x86_64-apple-macosx) TARGET="x86_64-apple-macosx13.0" ;;
    *) print -u2 -- "Unsupported macOS Swift triple: $TRIPLE"; exit 2 ;;
esac

BUILD_DIR="$ROOT_DIR/.build/$TRIPLE/$CONFIGURATION"
if [[ -e "$BUILD_DIR/Modules/LitheModuleAPI.swiftmodule" && \
      -e "$BUILD_DIR/Modules/LitheCoreContracts.swiftmodule" && \
      -e "$BUILD_DIR/Modules/LitheLanguageExtensionSupport.swiftmodule" ]]; then
    MODULE_DIR="$BUILD_DIR/Modules"
else
    # New SwiftPM layouts put module bundles beside the executable.
    MODULE_DIR="$BUILD_DIR"
fi
if [[ ! -e "$MODULE_DIR/LitheModuleAPI.swiftmodule" \
    || ! -e "$MODULE_DIR/LitheCoreContracts.swiftmodule" \
    || ! -e "$MODULE_DIR/LitheLanguageExtensionSupport.swiftmodule" ]]; then
    print -u2 -- "Build Lithe for $TRIPLE ($CONFIGURATION) before packaging official plugins"
    exit 1
fi

if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="$BUILD_DIR/OfficialPlugins"
fi
SDK_PATH="${SDKROOT:-$(/usr/bin/xcrun --sdk macosx --show-sdk-path)}"
if ! SWIFT_COMPILER=$(command -v swiftc); then
    print -u2 -- "Swift compiler is not available on PATH"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
for stale_package in "$OUTPUT_DIR"/*(/N); do
    [[ -f "$stale_package/plugin.json" ]] || continue
    rm -rf "$stale_package"
done
matched=0
for plugin_source in "$ROOT_DIR"/Plugins/mac/Official/*(/N); do
    manifest="$plugin_source/plugin.json"
    [[ -f "$manifest" ]] || continue
    package_id=$(/usr/bin/plutil -extract id raw "$manifest")
    if [[ -n "$PLUGIN_ID" && "$package_id" != "$PLUGIN_ID" ]]; then
        continue
    fi
    entrypoint_kind=$(/usr/bin/plutil -extract entrypoint.kind raw "$manifest")
    matched=$((matched + 1))
    package_dir="$OUTPUT_DIR/$package_id"
    rm -rf "$package_dir"
    mkdir -p "$package_dir"
    cp "$manifest" "$package_dir/plugin.json"
    if [[ -d "$plugin_source/Resources" ]]; then
        cp -R "$plugin_source/Resources" "$package_dir/Resources"
    fi
    if [[ "$entrypoint_kind" == "declarative" ]]; then
        continue
    fi
    info_plist="$plugin_source/Info.plist"
    if [[ ! -f "$info_plist" ]]; then
        print -u2 -- "Official native plugin $package_id is missing Info.plist"
        exit 1
    fi
    module_suffix="${plugin_source:t}"
    source_dir="$plugin_source/Sources/Lithe${module_suffix}Module"
    source_files=("$source_dir"/**/*.swift(N))
    if (( ${#source_files[@]} == 0 )); then
        print -u2 -- "Official plugin $package_id has no Swift sources at $source_dir"
        exit 1
    fi
    bundle_name=$(/usr/bin/plutil -extract entrypoint.bundlePath raw "$manifest")
    executable_name=$(/usr/bin/plutil -extract CFBundleExecutable raw "$info_plist")
    bundle_dir="$package_dir/$bundle_name"
    executable_dir="$bundle_dir/Contents/MacOS"

    mkdir -p "$executable_dir"
    cp "$info_plist" "$bundle_dir/Contents/Info.plist"

    "$SWIFT_COMPILER" \
        -emit-library \
        -parse-as-library \
        -module-name "Lithe${module_suffix}Plugin" \
        -swift-version 6 \
        -target "$TARGET" \
        -sdk "$SDK_PATH" \
        -I "$MODULE_DIR" \
        -Xlinker -undefined \
        -Xlinker dynamic_lookup \
        "${source_files[@]}" \
        -o "$executable_dir/$executable_name"

    /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" "$bundle_dir"
done

if (( matched == 0 )); then
    if [[ -n "$PLUGIN_ID" ]]; then
        print -u2 -- "No official plugin matched $PLUGIN_ID"
        exit 1
    fi
fi
print -r -- "$OUTPUT_DIR"
