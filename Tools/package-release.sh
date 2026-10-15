#!/bin/bash
#
# RDM-ARM release packaging.
#
# Builds a universal (arm64 + x86_64) app, wraps it in a zip that preserves the
# bundle's permissions and structure, and prints a SHA-256 for the release notes.
#
# The app is ad-hoc signed, so anything downloaded from the internet lands under
# Gatekeeper quarantine. The zip therefore ships an install note explaining the
# one-line fix — without it, every tester just reports "it says the app is
# damaged".
#
# Usage:
#   ./Tools/package-release.sh            package the version in build.sh
#   ./Tools/package-release.sh --no-build reuse the existing build/RDM-ARM.app
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/RDM-ARM.app"

DO_BUILD=1
for arg in "$@"; do
  case "$arg" in
    --no-build) DO_BUILD=0 ;;
    -h|--help)  sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
  echo "==> building universal app"
  "$ROOT/build.sh" --universal
fi

if [ ! -d "$APP" ]; then
  echo "error: $APP not found — run build.sh first" >&2
  exit 1
fi

ARCHS="$(lipo -archs "$APP/Contents/MacOS/RDM-ARM")"
echo "==> arch      $ARCHS"
case "$ARCHS" in
  *arm64*) ;;
  *) echo "error: build is missing arm64" >&2; exit 1 ;;
esac

# ---------------------------------------------------------------- stage

STAGE="$BUILD_DIR/stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"

# ditto (not cp) preserves symlinks and the executable bit inside the bundle.
ditto "$APP" "$STAGE/RDM-ARM.app"

cat > "$STAGE/安装说明.txt" <<EOF
RDM-ARM $VERSION —— 安装说明
====================================

1. 把 RDM-ARM.app 拖进「应用程序」文件夹。

2. 首次打开会被 macOS 拦下（提示「已损坏」或「无法验证开发者」）。
   这是正常的：本应用没有 Apple 开发者签名与公证，只做了 ad-hoc 签名。
   在「终端」里执行下面这一行即可解除拦截：

       xattr -dr com.apple.quarantine /Applications/RDM-ARM.app

   然后双击打开。只需做一次。

3. 本应用没有主窗口 —— 它是菜单栏应用。打开后请看屏幕**顶部菜单栏**，
   会多出一个显示器图标，点它就能看到所有分辨率。

   如果菜单栏图标太多看不到，可以在菜单栏空白处按住 Command 再拖动图标调整顺序，
   或先把别的菜单栏图标关掉几个。

4. 想切到某个分辨率：点菜单栏图标 → 你的显示器 → 分辨率 → 选一个。
   带 ⚡️ 的是 HiDPI 模式（画面更细腻），这些模式 macOS 自己不会显示出来。

5. 卸载：退出应用（菜单里「退出」），把 RDM-ARM.app 删掉即可。
   若还清理过偏好设置：defaults delete io.rdmarm.RDM-ARM

命令行用法（可选）：在终端里运行应用内的可执行文件，例如

    /Applications/RDM-ARM.app/Contents/MacOS/RDM-ARM -ld      # 列出显示器
    /Applications/RDM-ARM.app/Contents/MacOS/RDM-ARM -lm      # 列出全部模式
    /Applications/RDM-ARM.app/Contents/MacOS/RDM-ARM --selftest   # 自检

系统要求：macOS 13.0 或更高。$ARCHS 通用二进制。
EOF

# ---------------------------------------------------------------- zip

ZIP="$BUILD_DIR/RDM-ARM-$VERSION-universal.zip"
rm -f "$ZIP"
# No --keepParent: that would nest everything under "stage/". Without it the
# archive root is the *contents* of the staging folder, so unzipping gives a
# ready-to-drag RDM-ARM.app plus the install note.
ditto -c -k --sequesterRsrc "$STAGE" "$ZIP"

# ---------------------------------------------------------------- report

echo
echo "packaged  $ZIP"
echo "arch      $ARCHS"
echo "version   $VERSION"
echo "size      $(du -sh "$ZIP" | cut -f1)"
echo "sha256    $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
