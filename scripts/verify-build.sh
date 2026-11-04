#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILE="$ROOT/build/RDM-ARM-1.4.3-universal.dmg"
EXPECTED_SIZE=2797230
EXPECTED_SHA=3a4de370ad4a6a24b68974d11acab75da115ec21e7abeeeddecfc1423dc2533c

[[ -f "$FILE" ]] || { echo "缺少产物：$FILE" >&2; exit 1; }
SIZE=$(stat -f%z "$FILE")
SHA=$(shasum -a 256 "$FILE" | cut -d' ' -f1)
[[ "$SIZE" == "$EXPECTED_SIZE" ]] || { echo "大小不一致：$SIZE != $EXPECTED_SIZE" >&2; exit 1; }
[[ "$SHA" == "$EXPECTED_SHA" ]] || { echo "SHA-256 不一致：$SHA != $EXPECTED_SHA" >&2; exit 1; }
echo "OK $(basename "$FILE") size=$SIZE sha256=$SHA"
