#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
cd "$ROOT_DIR"

temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/lithe-package-verification.XXXXXX")
trap 'rm -rf -- "$temporary_directory"' EXIT
dist_root="$temporary_directory/dist"
package_log="$temporary_directory/package.log"
dmg_log="$temporary_directory/dmg.log"

env -u LITHE_ARCH -u LITHE_JDK_ROOT \
    LITHE_DIST_ROOT="$dist_root" \
    LITHE_CODESIGN_IDENTITY="-" \
    scripts/package-app.sh | tee "$package_log"

app_path="$(tail -n 1 "$package_log")"
expected_app_path="$dist_root/Lithe.app"
if [[ "$app_path" != "$expected_app_path" ]]; then
    print -u2 -- "Unexpected packaged app path: $app_path"
    exit 1
fi

required_executables=(
    "$app_path/Contents/MacOS/Lithe"
    "$app_path/Contents/Frameworks/Sparkle.framework/Sparkle"
    "$app_path/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
    "$app_path/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater"
    "$app_path/Contents/Helpers/lithe-db-sidecar"
    "$app_path/Contents/Helpers/lithe-db-mcp"
)
for executable in "${required_executables[@]}"; do
    if [[ ! -x "$executable" ]]; then
        print -u2 -- "Packaged executable is missing: $executable"
        exit 1
    fi
done

required_resources=(
    "$app_path/Contents/Info.plist"
    "$app_path/Contents/Resources/Lithe_Lithe.bundle"
    "$app_path/Contents/Resources/SwiftTerm_SwiftTerm.bundle/Shaders.metal"
)
for resource in "${required_resources[@]}"; do
    if [[ ! -e "$resource" ]]; then
        print -u2 -- "Packaged resource is missing: $resource"
        exit 1
    fi
done
/usr/bin/lipo "$app_path/Contents/MacOS/Lithe" -verify_arch arm64 x86_64
# Java resources must remain absent even when old preparation caches exist.
for retired_resource in "$app_path/Contents/Resources/LanguageServers"/jdk*(N) \
    "$app_path/Contents/Resources/LanguageServers/jdtls" \
    "$app_path/Contents/Resources/OfficialPlugins/dev.lithe.plugin.linux-do-support"; do
    if [[ -e "$retired_resource" ]]; then
        print -u2 -- "Retired resource was included: $retired_resource"
        exit 1
    fi
done
/usr/bin/lipo "$app_path/Contents/Frameworks/Sparkle.framework/Sparkle" -verify_arch arm64 x86_64
/usr/bin/otool -l "$app_path/Contents/MacOS/Lithe" | /usr/bin/grep -F '@executable_path/../Frameworks' >/dev/null

plugin_manifests=("$app_path/Contents/Resources/OfficialPlugins"/*/plugin.json(N))
if (( ${#plugin_manifests[@]} == 0 )); then
    print -u2 -- "Packaged app does not contain any official plugin manifests"
    exit 1
fi

/usr/bin/codesign --verify --deep --strict "$app_path"

env -u LITHE_ARCH \
    LITHE_DIST_ROOT="$dist_root" \
    LITHE_VERSION="ci-smoke" \
    scripts/create-dmg.sh | tee "$dmg_log"
dmg_path="$(tail -n 1 "$dmg_log")"
expected_dmg_path="$dist_root/Lithe-ci-smoke.dmg"
if [[ "$dmg_path" != "$expected_dmg_path" || ! -s "$dmg_path" ]]; then
    print -u2 -- "Disk image was not created at the expected path: $dmg_path"
    exit 1
fi
hdiutil imageinfo "$dmg_path" > /dev/null

/usr/bin/ruby -e '
  require "find"
  bytes = 0
  Find.find(ARGV.fetch(0)) { |path| bytes += File.size(path) if File.file?(path) && !File.symlink?(path) }
  puts "Universal app file bytes: #{bytes}"
  puts "Universal DMG bytes: #{File.size(ARGV.fetch(1))}"
' "$app_path" "$dmg_path"

print -- "macOS package and disk image verification passed for the default universal architecture"
