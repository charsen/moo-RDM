#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILE="$ROOT/build/RDM-ARM-1.4.4-universal.dmg"
EXPECTED_SIZE=2875662
EXPECTED_SHA=a9c6c38b0bec489ac2c3b325b246dc908df977f087e42a321b98e00c3d240dc8

[[ -f "$FILE" ]] || { echo "缺少产物：$FILE" >&2; exit 1; }
SIZE=$(stat -f%z "$FILE")
SHA=$(shasum -a 256 "$FILE" | cut -d' ' -f1)
[[ "$SIZE" == "$EXPECTED_SIZE" ]] || { echo "大小不一致：$SIZE != $EXPECTED_SIZE" >&2; exit 1; }
[[ "$SHA" == "$EXPECTED_SHA" ]] || { echo "SHA-256 不一致：$SHA != $EXPECTED_SHA" >&2; exit 1; }
echo "OK $(basename "$FILE") size=$SIZE sha256=$SHA"
spctl -a -vv -t install "$FILE" 2>&1 | grep -q "accepted" || { echo "Gatekeeper 未通过：$FILE" >&2; exit 1; }
xcrun stapler validate "$FILE" >/dev/null 2>&1 || { echo "公证票据未装订：$FILE" >&2; exit 1; }
echo "OK notarized + stapled $FILE"
