#!/bin/bash
#
# RDM-ARM release packaging.
#
# build.sh already produces the deliverable: a signed, notarized, stapled DMG
# holding the .app plus an /Applications shortcut. This wrapper exists to make
# the release path explicit and to assert the two things a release must not get
# wrong — universal architecture, and a version that agrees across build.sh,
# AppInfo.swift and Info.plist (build.sh already refuses to build if they drift).
#
# There is no zip any more. A zip has no drag-to-Applications affordance and
# cannot carry a staple of its own, so every macOS project here ships a DMG.
#
# Usage:
#   ./Tools/package-release.sh                 build + notarize, then report
#   ./Tools/package-release.sh --no-build      verify the existing build
#   ./Tools/package-release.sh --no-notarize   build without submitting to Apple
#
# Notarization reads MOO_RDM_NOTARY_PROFILE (a notarytool keychain profile).
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/build"
APP_NAME="RDM-ARM"
APP="$BUILD_DIR/$APP_NAME.app"

DO_BUILD=1
NOTARIZE=1
for arg in "$@"; do
  case "$arg" in
    --no-build)    DO_BUILD=0 ;;
    --no-notarize) NOTARIZE=0 ;;
    -h|--help)     sed -n '2,/^set -euo pipefail$/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

# Single source of truth for the version.
VERSION="$(sed -n 's/^VERSION="\([^"]*\)".*/\1/p' "$ROOT/build.sh" | head -1)"
if [ -z "$VERSION" ]; then
  echo "error: could not read VERSION from build.sh" >&2
  exit 1
fi

if [ "$DO_BUILD" -eq 1 ]; then
  echo "==> building universal app (notarize=$NOTARIZE)"
  if [ "$NOTARIZE" -eq 1 ]; then
    if [ -z "${MOO_RDM_NOTARY_PROFILE:-}" ]; then
      echo "error: MOO_RDM_NOTARY_PROFILE is not set (notarytool keychain profile)." >&2
      echo "       Pass --no-notarize to build without notarizing." >&2
      exit 1
    fi
    MOO_RDM_NOTARIZE=1 "$ROOT/build.sh" --universal
  else
    MOO_RDM_NOTARIZE=0 "$ROOT/build.sh" --universal
  fi
fi

if [ ! -d "$APP" ]; then
  echo "error: $APP not found — run build.sh first" >&2
  exit 1
fi

# ---------------------------------------------------------------- verify

ARCHS="$(lipo -archs "$APP/Contents/MacOS/$APP_NAME")"
echo "==> arch      $ARCHS"

# The published artifact has to run on both Apple silicon and Intel, and both the
# file name and the install note claim it does. Checking only for arm64 would let
# a --no-build run reuse an arm64-only bundle and ship a file that says
# "universal" on the label while failing on half the machines it is sent to.
case "$ARCHS" in
  *arm64*)  ;;
  *) echo "error: build is missing arm64" >&2; exit 1 ;;
esac
case "$ARCHS" in
  *x86_64*) ;;
  *) echo "error: build is missing x86_64 — re-run without --no-build" >&2; exit 1 ;;
esac

PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$APP/Contents/Info.plist" 2>/dev/null)"
if [ "$PLIST_VERSION" != "$VERSION" ]; then
  echo "error: built app is $PLIST_VERSION but build.sh says $VERSION" >&2
  exit 1
fi

DMG="$BUILD_DIR/$APP_NAME-$VERSION-universal.dmg"
if [ ! -f "$DMG" ]; then
  echo "error: $DMG not found — the build did not produce a disk image" >&2
  exit 1
fi

# ---------------------------------------------------------------- report

echo
echo "packaged  $DMG"
echo "arch      $ARCHS"
echo "version   $VERSION"
echo "size      $(du -sh "$DMG" | cut -f1)"
echo "sha256    $(shasum -a 256 "$DMG" | cut -d' ' -f1)"

# Informational only: this machine has Gatekeeper assessment disabled
# (`override=security disabled`), so a green result here proves the ticket is
# present, not that a clean machine will accept it.
if command -v spctl >/dev/null 2>&1; then
  echo "gatekeeper $(spctl -a -vv -t open --context context:primary-signature "$DMG" 2>&1 | sed -n 's/.*source=//p' | head -1)"
fi
