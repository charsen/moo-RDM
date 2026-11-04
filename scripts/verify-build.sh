#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILE="$ROOT/build/RDM-ARM-1.4.3-universal.dmg"
EXPECTED_SIZE=2796510
EXPECTED_SHA=3022c7d3a6c95f42b3389e5fdd6bec0394e9568454d8c42379e32009e7f39b0c

[[ -f "$FILE" ]] || { echo "缺少产物：$FILE" >&2; exit 1; }
SIZE=$(stat -f%z "$FILE")
SHA=$(shasum -a 256 "$FILE" | cut -d' ' -f1)
[[ "$SIZE" == "$EXPECTED_SIZE" ]] || { echo "大小不一致：$SIZE != $EXPECTED_SIZE" >&2; exit 1; }
[[ "$SHA" == "$EXPECTED_SHA" ]] || { echo "SHA-256 不一致：$SHA != $EXPECTED_SHA" >&2; exit 1; }
echo "OK $(basename "$FILE") size=$SIZE sha256=$SHA"
spctl -a -vv -t install "$FILE" 2>&1 | grep -q "accepted" || { echo "Gatekeeper 未通过：$FILE" >&2; exit 1; }
xcrun stapler validate "$FILE" >/dev/null 2>&1 || { echo "公证票据未装订：$FILE" >&2; exit 1; }
echo "OK notarized + stapled $FILE"
