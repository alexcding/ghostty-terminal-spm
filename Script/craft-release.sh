#!/usr/bin/env bash
# Builds Craft's release artifacts from the pinned Ghostty revision:
#   build/release/GhosttyKit.xcframework.zip   the binary target of this package
#   build/release/ghostty-vt-runtime.zip       the headless VT runtime craft-ptyd links
# Apple Silicon macOS only. Needs Xcode with the Metal Toolchain component
# (downloaded here when missing) and network access for Zig and Ghostty.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
LOCK="$ROOT/Craft/ghostty.lock.json"
BUILD="$ROOT/build"
mkdir -p "$BUILD/release" "$BUILD/tools"

lock() { python3 -c "import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$LOCK" "$1"; }
REVISION="$(lock revision)"; REPOSITORY="$(lock repository)"
ZIG_VERSION="$(lock zigVersion)"; ZIG_URL="$(lock zigURL)"; ZIG_SHA="$(lock zigSHA256)"

if ! xcrun -sdk macosx metal --version >/dev/null 2>&1; then
  echo "[+] downloading the Metal Toolchain"
  xcodebuild -downloadComponent MetalToolchain
fi

ZIG="$BUILD/tools/zig-aarch64-macos-$ZIG_VERSION/zig"
if [[ ! -x "$ZIG" ]]; then
  echo "[+] downloading Zig $ZIG_VERSION"
  curl -fsSL "$ZIG_URL" -o "$BUILD/tools/zig.tar.xz"
  echo "$ZIG_SHA  $BUILD/tools/zig.tar.xz" | shasum -a 256 -c -
  tar -xJf "$BUILD/tools/zig.tar.xz" -C "$BUILD/tools"
fi
[[ "$("$ZIG" version)" == "$ZIG_VERSION" ]]
export PATH="$(dirname "$ZIG"):$PATH"
export ZIG_GLOBAL_CACHE_DIR="$BUILD/cache/global"

checkout() { # <dir>
  if [[ ! -d "$1" ]]; then
    git clone --filter=blob:none --no-checkout "$REPOSITORY" "$1"
    git -C "$1" switch --detach "$REVISION"
  fi
  [[ "$(git -C "$1" rev-parse HEAD)" == "$REVISION" ]]
  git -C "$1" checkout -- . && git -C "$1" clean -fdq
}

# 1. libghostty with the app-runtime patches -> XCFramework.
SRC="$BUILD/native-source"; checkout "$SRC"
zsh "$ROOT/Script/apply-patches.sh" "$SRC"
for patch in "$ROOT"/Craft/patches/native/*.patch; do git -C "$SRC" apply "$patch"; done
(cd "$SRC" && ZIG_LOCAL_CACHE_DIR="$BUILD/cache/native" zig build -Doptimize=ReleaseFast -Dapp-runtime=none \
  -Demit-exe=false -Demit-xcframework=false -Demit-macos-app=false -Demit-docs=false \
  -Dsentry=false -Dcustom-shaders=false -Dinspector=false -Dtarget=aarch64-macos)
XC="$BUILD/GhosttyKit.xcframework"; rm -rf "$XC"
mkdir -p "$XC/macos-arm64/Headers/libghostty"
cp "$SRC/zig-out/lib/libghostty.a" "$XC/macos-arm64/libghostty.a"
cp "$SRC/include/ghostty.h" "$XC/macos-arm64/Headers/libghostty/ghostty.h"
printf 'module libghostty {\n    umbrella header "ghostty.h"\n    export *\n}\n' > "$XC/macos-arm64/Headers/libghostty/module.modulemap"
cat > "$XC/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>AvailableLibraries</key><array><dict>
		<key>HeadersPath</key><string>Headers</string>
		<key>LibraryIdentifier</key><string>macos-arm64</string>
		<key>LibraryPath</key><string>libghostty.a</string>
		<key>SupportedArchitectures</key><array><string>arm64</string></array>
		<key>SupportedPlatform</key><string>macos</string>
	</dict></array>
	<key>CFBundlePackageType</key><string>XFWK</string>
	<key>XCFrameworkFormatVersion</key><string>1.0</string>
</dict></plist>
PLIST
rm -f "$BUILD/release/GhosttyKit.xcframework.zip"
(cd "$BUILD" && ditto -c -k --keepParent GhosttyKit.xcframework release/GhosttyKit.xcframework.zip)

# 2. The headless VT runtime (libghostty-vt) with the snapshot patches only.
VT="$BUILD/vt-source"; checkout "$VT"
for patch in "$ROOT"/Craft/patches/vt/*.patch; do git -C "$VT" apply "$patch"; done
RUNTIME="$BUILD/runtime"; rm -rf "$RUNTIME"
(cd "$VT" && zig build -Demit-lib-vt -Demit-exe=false -Demit-macos-app=false -Demit-xcframework=false \
  -Doptimize=ReleaseFast --prefix "$RUNTIME" --cache-dir "$BUILD/cache/vt")
[[ -f "$RUNTIME/lib/libghostty-vt.a" ]]
echo "$REVISION" > "$RUNTIME/craft-ghostty-revision"
cp "$ROOT/Craft/patches/vt/0003-terminal-query-validation.patch" "$RUNTIME/craft-ghostty-query-patch"
cp "$ROOT/Craft/patches/vt/0007-glyph-snapshot.patch" "$RUNTIME/craft-ghostty-glyph-patch"
cp "$ROOT/Craft/patches/vt/0008-graphics-snapshot.patch" "$RUNTIME/craft-ghostty-graphics-patch"
rm -f "$BUILD/release/ghostty-vt-runtime.zip"
(cd "$BUILD" && ditto -c -k --keepParent runtime release/ghostty-vt-runtime.zip)

echo "[+] artifacts in $BUILD/release"
echo "[+] xcframework checksum: $(swift package compute-checksum "$BUILD/release/GhosttyKit.xcframework.zip")"
