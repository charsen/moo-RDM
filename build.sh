#!/bin/bash
#
# RDM-ARM build script.
#
# Deliberately depends on nothing but the Xcode Command Line Tools — no Xcode.app,
# no Swift Package Manager, no CocoaPods. It compiles the sources with swiftc and
# assembles the .app bundle by hand.
#
# Usage:
#   ./build.sh                 build for the host architecture
#   ./build.sh --universal     build arm64 + x86_64 and merge with lipo
#   ./build.sh --install       build, then copy to /Applications
#   ./build.sh --run           build, then launch
#   ./build.sh --clean         remove build artefacts
#
# Signing:
#   Picks a "Developer ID Application" identity from the keychain when one is
#   installed, and falls back to an ad-hoc signature otherwise. Override with
#   MOO_RDM_SIGNING_IDENTITY. Set MOO_RDM_NOTARIZE=1 together with
#   MOO_RDM_NOTARY_PROFILE=<keychain profile> to submit and staple.
#
set -euo pipefail

APP_NAME="RDM-ARM"
BUNDLE_ID="com.mooeen.rdm"
VERSION="1.2.1"
MIN_MACOS="13.0"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
ICON_SOURCE="$BUILD_DIR/AppIcon-1024.png"
ICONSET="$BUILD_DIR/AppIcon.iconset"

DO_INSTALL=0
DO_RUN=0
ARCHS="arm64"

for arg in "$@"; do
  case "$arg" in
    --universal) ARCHS="arm64 x86_64" ;;
    --install)   DO_INSTALL=1 ;;
    --run)       DO_RUN=1 ;;
    --clean)
      rm -rf "$BUILD_DIR"
      echo "cleaned"
      exit 0
      ;;
    -h|--help)
      sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------- prerequisites

if ! command -v swiftc >/dev/null 2>&1; then
  echo "error: swiftc not found. Install the Xcode Command Line Tools:" >&2
  echo "  xcode-select --install" >&2
  exit 1
fi

SDK_PATH="$(xcrun --show-sdk-path)"
echo "==> SDK       $SDK_PATH"
echo "==> Swift     $(swiftc --version 2>&1 | head -1)"
echo "==> arch(es)  $ARCHS"

# VERSION here, AppInfo.version and the Info.plist template must all agree,
# otherwise the About panel and the Finder Get Info window would report
# different versions of the same build.
APPINFO_VERSION="$(sed -n 's/.*static let version = "\([^"]*\)".*/\1/p' \
  "$ROOT/Sources/Core/AppInfo.swift" | head -1)"
if [ -n "$APPINFO_VERSION" ] && [ "$APPINFO_VERSION" != "$VERSION" ]; then
  echo "error: version mismatch — build.sh has $VERSION but AppInfo.swift has $APPINFO_VERSION" >&2
  exit 1
fi

# The template is overwritten below, so a stale value would go unnoticed here and
# only show up in any bundle that skips this script.
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$ROOT/Resources/Info.plist" 2>/dev/null)"
if [ -n "$PLIST_VERSION" ] && [ "$PLIST_VERSION" != "$VERSION" ]; then
  echo "error: version mismatch — build.sh has $VERSION but Resources/Info.plist has $PLIST_VERSION" >&2
  exit 1
fi
echo "==> version   $VERSION"

# Same reason as the version check above: the template is overwritten below, so a
# stale Bundle ID would only surface once a user's preferences and TCC grants
# landed under an identity nobody wrote down.
PLIST_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
  "$ROOT/Resources/Info.plist" 2>/dev/null)"
if [ -n "$PLIST_BUNDLE_ID" ] && [ "$PLIST_BUNDLE_ID" != "$BUNDLE_ID" ]; then
  echo "error: bundle id mismatch — build.sh has $BUNDLE_ID but Resources/Info.plist has $PLIST_BUNDLE_ID" >&2
  exit 1
fi
echo "==> bundle id $BUNDLE_ID"

mkdir -p "$BUILD_DIR"

# ---------------------------------------------------------------- icon

if [ ! -f "$BUILD_DIR/AppIcon.icns" ]; then
  echo "==> rendering icon"
  swift "$ROOT/Tools/MakeIcon.swift" "$ICON_SOURCE" >/dev/null

  rm -rf "$ICONSET"
  mkdir -p "$ICONSET"
  for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
              "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" \
              "512 512x512" "1024 512x512@2x"; do
    set -- $spec
    sips -z "$1" "$1" "$ICON_SOURCE" --out "$ICONSET/icon_$2.png" >/dev/null 2>&1
  done
  iconutil -c icns "$ICONSET" -o "$BUILD_DIR/AppIcon.icns"
  echo "==> icon      $BUILD_DIR/AppIcon.icns"
fi

# ---------------------------------------------------------------- compile

SOURCES=()
while IFS= read -r file; do
  SOURCES+=("$file")
done < <(find "$ROOT/Sources" -name '*.swift' | sort)

echo "==> sources   ${#SOURCES[@]} file(s)"

FRAMEWORKS=(
  -framework AppKit
  -framework Carbon
  -framework CoreGraphics
  -framework IOKit
  -framework Foundation
  -framework UniformTypeIdentifiers
)

BINARIES=()
for arch in $ARCHS; do
  out="$BUILD_DIR/$APP_NAME-$arch"
  echo "==> compiling $arch"
  swiftc \
    -swift-version 5 \
    -O \
    -whole-module-optimization \
    -target "${arch}-apple-macos${MIN_MACOS}" \
    -sdk "$SDK_PATH" \
    "${SOURCES[@]}" \
    "${FRAMEWORKS[@]}" \
    -o "$out"
  BINARIES+=("$out")
done

# ---------------------------------------------------------------- bundle

echo "==> assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [ "${#BINARIES[@]}" -gt 1 ]; then
  lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/$APP_NAME"
else
  cp "${BINARIES[0]}" "$APP/Contents/MacOS/$APP_NAME"
fi
chmod +x "$APP/Contents/MacOS/$APP_NAME"

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$BUILD_DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Keep the version in Info.plist and AppInfo.swift in step.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist" >/dev/null

plutil -lint "$APP/Contents/Info.plist" >/dev/null

# ---------------------------------------------------------------- sign

# Two tiers. A Developer ID signature is what lets another machine open the app
# without a Gatekeeper override; ad-hoc is only good on the machine that built it.
# The identity is taken from the environment first so a CI run can pin it, then
# from the keychain.
SIGNING_IDENTITY="${MOO_RDM_SIGNING_IDENTITY:-}"
if [ -z "$SIGNING_IDENTITY" ]; then
  SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
fi
NOTARIZE="${MOO_RDM_NOTARIZE:-0}"
NOTARY_PROFILE="${MOO_RDM_NOTARY_PROFILE:-}"

# Sign inside-out instead of `--deep`. Apple discourages `--deep` for signing:
# it blurs which nested item is at fault when notarization rejects the bundle.
if [ -n "$SIGNING_IDENTITY" ]; then
  echo "==> signing (Developer ID)"
  echo "    $SIGNING_IDENTITY"
  codesign --force --options runtime --timestamp \
    --sign "$SIGNING_IDENTITY" "$APP/Contents/MacOS/$APP_NAME" 2>&1 | sed 's/^/    /'
  codesign --force --options runtime --timestamp \
    --sign "$SIGNING_IDENTITY" "$APP" 2>&1 | sed 's/^/    /'
else
  # Ad-hoc: enough for local use. The private rotation symbol is resolved at
  # runtime and needs no entitlement — hardened runtime still allows loading
  # Apple-signed private frameworks.
  echo "==> signing (ad-hoc)"
  codesign --force --options runtime --sign - "$APP" 2>&1 | sed 's/^/    /'
fi
codesign --verify --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'

# ---------------------------------------------------------------- notarize

if [ "$NOTARIZE" = "1" ]; then
  if [ -z "$SIGNING_IDENTITY" ]; then
    echo "error: MOO_RDM_NOTARIZE=1 but no Developer ID Application identity was found" >&2
    exit 1
  fi
  if [ -z "$NOTARY_PROFILE" ]; then
    echo "error: MOO_RDM_NOTARIZE=1 but MOO_RDM_NOTARY_PROFILE is empty (notarytool keychain profile)" >&2
    exit 1
  fi
  echo "==> notarizing"
  NOTARY_ZIP="$BUILD_DIR/$APP_NAME-notary.zip"
  rm -f "$NOTARY_ZIP"
  ditto -c -k --keepParent "$APP" "$NOTARY_ZIP"
  xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  rm -f "$NOTARY_ZIP"
  codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'
fi

# ---------------------------------------------------------------- report

echo
echo "built  $APP"
echo "arch   $(lipo -archs "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null || echo unknown)"
echo "size   $(du -sh "$APP" | cut -f1)"

if [ "$DO_INSTALL" -eq 1 ]; then
  echo "==> installing to /Applications"
  rm -rf "/Applications/$APP_NAME.app"
  # ditto, not cp -R: it preserves symlinks and extended attributes, so the
  # signature survives the copy.
  ditto "$APP" "/Applications/$APP_NAME.app"
  echo "installed /Applications/$APP_NAME.app"
fi

if [ "$DO_RUN" -eq 1 ]; then
  echo "==> launching"
  open "$APP"
fi

# ---------------------------------------------------------------- unregister

# LaunchServices registers every .app bundle it sees, wherever it sits. Without
# this the build output shows up in the system app list next to the installed
# copy — two entries called "RDM-ARM" that launch different binaries, which is
# impossible to tell apart without opening Get Info. The dev bundle is still
# fully usable from the command line and via `open`; it just stops competing
# with /Applications for a slot in the UI.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
