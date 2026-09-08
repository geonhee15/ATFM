#!/bin/zsh
# Builds ATFM.app into ./build with swiftc directly (works with Command Line Tools only, no Xcode).
#   ./build.sh            # release build
#   ./build.sh debug      # debug build
#   ./build.sh --run      # build, then (re)launch the app
set -euo pipefail
cd "$(dirname "$0")"

CONFIG=release
RUN=0
for arg in "$@"; do
  case "$arg" in
    debug) CONFIG=debug ;;
    --run) RUN=1 ;;
  esac
done

APP_NAME=ATFM
VERSION=$(sed -n 's/^version: *//p' VERSION 2>/dev/null || echo 0.1.0)
BUILD_NUMBER=$(date +%Y%m%d%H%M)
SDK="$(xcrun --show-sdk-path)"
ARCH="$(uname -m)"

OPT=(-O)
[[ "$CONFIG" == "debug" ]] && OPT=(-Onone -g)
mkdir -p build

# Work around a broken Command Line Tools install where a stale
# usr/include/swift/module.modulemap redefines 'SwiftBridging' (see Scripts/toolchain-fix).
EXTRA=()
CLT_INC=/Library/Developer/CommandLineTools/usr/include/swift
if [[ -f "$CLT_INC/module.modulemap" && -f "$CLT_INC/bridging.modulemap" ]]; then
  FIX_DIR="$(pwd)/Scripts/toolchain-fix"
  sed "s|__FIX_DIR__|$FIX_DIR|" "$FIX_DIR/overlay.yaml.in" > build/overlay.yaml
  EXTRA+=(-vfsoverlay build/overlay.yaml)
  echo "▶ applying toolchain-fix VFS overlay"
fi
EXTRA+=(-module-cache-path build/ModuleCache)

echo "▶ swiftc ($CONFIG, $ARCH)"
swiftc "${OPT[@]}" -parse-as-library -swift-version 5 \
  -target "${ARCH}-apple-macos14.0" -sdk "$SDK" "${EXTRA[@]}" \
  $(find Sources/ATFM -name '*.swift' | sort) \
  -o "build/$APP_NAME"

# Now Playing bridge: a dylib that Apple's perl loads (see Sources/MediaRemoteBridge/Bridge.swift).
echo "▶ MediaRemote bridge"
swiftc -O -emit-library -module-name ATFMMediaRemote \
  -target "${ARCH}-apple-macos14.0" -sdk "$SDK" "${EXTRA[@]}" \
  Sources/MediaRemoteBridge/Bridge.swift \
  -o "build/ATFMMediaRemote.dylib"

APP="build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "build/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" Resources/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [[ ! -f build/AppIcon.icns ]]; then
  echo "▶ generating app icon"
  swiftc -O -target "${ARCH}-apple-macos14.0" -sdk "$SDK" "${EXTRA[@]}" Scripts/make-icon.swift -o build/make-icon
  ./build/make-icon build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp build/ATFMMediaRemote.dylib "$APP/Contents/Resources/ATFMMediaRemote.dylib"
cp Resources/mediaremote.pl "$APP/Contents/Resources/mediaremote.pl"
cp Resources/elements.json "$APP/Contents/Resources/elements.json"

# Finder likes to stamp com.apple.FinderInfo on the .app folder once it has been launched; codesign
# refuses to seal a bundle carrying it, and an unsealed signature makes TCC ignore every permission grant.
xattr -c "$APP" 2>/dev/null || true
xattr -cr "$APP" 2>/dev/null || true
# A stable signing identity keeps TCC grants (Screen Recording, Automation) across rebuilds;
# ad-hoc signatures change every build and macOS forgets the permission.
SIGN_IDENTITY="${ATFM_SIGN_IDENTITY:-Omni Dev Signing}"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$SIGN_IDENTITY\""; then
  SIGN_WITH="$SIGN_IDENTITY"
else
  SIGN_WITH="-"
fi
# Finder re-stamps FinderInfo within a second or two, so strip + sign in one breath and retry if it lost the race.
signed=0
for attempt in 1 2 3; do
  xattr -c "$APP" 2>/dev/null || true
  xattr -cr "$APP" 2>/dev/null || true
  if codesign --force --sign "$SIGN_WITH" "$APP" 2>/dev/null; then signed=1; break; fi
  sleep 0.3
done
# Non-strict verify: this is what TCC checks. (--strict would flag the FinderInfo xattr Finder adds
# back later, which does not invalidate the sealed signature.)
if [[ $signed -ne 1 ]] || ! codesign --verify "$APP" 2>/dev/null || codesign -dvv "$APP" 2>&1 | grep -q "Sealed Resources=none"; then
  echo "✖ codesign did not produce a valid sealed signature:"
  codesign --verify --verbose=2 "$APP" 2>&1 | sed 's/^/   /'
  exit 1
fi
echo "✔ built $APP"

# The project lives in an iCloud-synced folder, where Finder keeps re-stamping the bundle with
# com.apple.FinderInfo and breaking strict signature validation. The copy people actually run
# therefore goes to ~/Applications (not synced); build/ATFM.app stays for dev snapshots.
INSTALL_APP="${ATFM_INSTALL_DIR:-$HOME/Applications}/$APP_NAME.app"
if [[ "$CONFIG" != "debug" ]]; then
  mkdir -p "$(dirname "$INSTALL_APP")"
  rm -rf "$INSTALL_APP"
  ditto --noextattr --noqtn "$APP" "$INSTALL_APP"
  if codesign --verify "$INSTALL_APP" 2>/dev/null; then
    echo "✔ installed $INSTALL_APP"
  else
    echo "✖ installed copy failed signature check"; codesign --verify --verbose=2 "$INSTALL_APP" 2>&1 | sed 's/^/   /'; exit 1
  fi
fi

if [[ $RUN -eq 1 ]]; then
  pkill -x "$APP_NAME" 2>/dev/null || true
  sleep 0.5
  if [[ "$CONFIG" != "debug" && -d "$INSTALL_APP" ]]; then open "$INSTALL_APP"; else open "$APP"; fi
fi
