#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILE="$ROOT/build/RDM-ARM-1.4.6-universal.dmg"
EXPECTED_SIZE=2877100
EXPECTED_SHA=4e8b3adc67e57eb94e7ea1f5afec0aa426ed261dd58e37d1b5bd76fd3be09cf6

[[ -f "$FILE" ]] || { echo "缺少产物：$FILE" >&2; exit 1; }
SIZE=$(stat -f%z "$FILE")
SHA=$(shasum -a 256 "$FILE" | cut -d' ' -f1)
[[ "$SIZE" == "$EXPECTED_SIZE" ]] || { echo "大小不一致：$SIZE != $EXPECTED_SIZE" >&2; exit 1; }
[[ "$SHA" == "$EXPECTED_SHA" ]] || { echo "SHA-256 不一致：$SHA != $EXPECTED_SHA" >&2; exit 1; }
echo "OK $(basename "$FILE") size=$SIZE sha256=$SHA"
spctl -a -vv -t install "$FILE" 2>&1 | grep -q "accepted" || { echo "Gatekeeper 未通过：$FILE" >&2; exit 1; }
xcrun stapler validate "$FILE" >/dev/null 2>&1 || { echo "公证票据未装订：$FILE" >&2; exit 1; }
echo "OK notarized + stapled $FILE"
