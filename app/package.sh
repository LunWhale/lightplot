#!/bin/sh
# ============================================================
#  打包 macOS 应用：.app 与 .dmg
#
#  用法：
#     ./package.sh              出 LightPlot.app + LightPlot-<版本>.dmg
#     ./package.sh --no-dmg     只出 .app
#
#  产物在 dist/：
#     LightPlot.app             可直接拖进"应用程序"
#     LightPlot-0.001.dmg       带 /Applications 快捷方式的安装镜像
#
#  签名说明（重要）：
#     本机没有 Apple 开发者证书，所以用 **ad-hoc 签名**。
#     ad-hoc 签名的应用在本机能直接打开；拷到别的 Mac 上，
#     Gatekeeper 会提示"无法验证开发者"，需要右键 → 打开，
#     或执行 xattr -dr com.apple.quarantine /Applications/LightPlot.app。
#     要彻底消除这个提示，需要 Developer ID 证书 + 公证（见 README）。
# ============================================================
set -eu
cd "$(dirname "$0")"

APP_NAME="LightPlot"
BUNDLE_ID="studio.lightplot.app"
VOL_NAME="LightPlot"
SCHEME="LightPlot-macOS"
CONFIG="Release"
BUILD_DIR=".build/xcode-pkg"
DIST="dist"

MAKE_DMG=1
if [ "${1:-}" = "--no-dmg" ]; then MAKE_DMG=0; fi

hr() { printf '%s\n' "=============================================="; }
step() { printf '\n[%s] %s\n' "$1" "$2"; }

hr
echo " 打包 $APP_NAME"
hr

# ------------------------------------------------------------
# 1. 编译 Release（通用二进制：Apple 芯片 + Intel）
# ------------------------------------------------------------
step "1/6" "编译 Release ..."
if ! xcodebuild -project LightPlot.xcodeproj -scheme "$SCHEME" \
      -configuration "$CONFIG" -derivedDataPath "$BUILD_DIR" \
      ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
      build > /tmp/lightplot_pkg_build.log 2>&1; then
  echo "  编译失败。完整输出：/tmp/lightplot_pkg_build.log" >&2
  grep -m8 "error:" /tmp/lightplot_pkg_build.log >&2
  exit 1
fi
BUILT="$BUILD_DIR/Build/Products/$CONFIG/$APP_NAME.app"
[ -d "$BUILT" ] || { echo "  找不到 $BUILT" >&2; exit 1; }
echo "  OK"

# ------------------------------------------------------------
# 2. 校验 .app 本身
# ------------------------------------------------------------
step "2/6" "校验应用包 ..."
BIN="$BUILT/Contents/MacOS/$APP_NAME"
ARCHS=$(lipo -archs "$BIN" 2>/dev/null || echo "unknown")
case "$ARCHS" in
  *arm64*) ;;
  *) echo "  缺少 arm64（实际：$ARCHS）" >&2; exit 1 ;;
esac
case "$ARCHS" in
  *x86_64*) ;;
  *) echo "  缺少 x86_64（实际：$ARCHS）" >&2; exit 1 ;;
esac
echo "  架构：$ARCHS（Apple 芯片与 Intel 都能跑）"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
          "$BUILT/Contents/Info.plist")
GOT_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" \
         "$BUILT/Contents/Info.plist")
DISPLAY=$(/usr/libexec/PlistBuddy -c "Print :CFBundleDisplayName" \
          "$BUILT/Contents/Info.plist" 2>/dev/null || echo "$APP_NAME")
if [ "$GOT_ID" != "$BUNDLE_ID" ]; then
  echo "  Bundle ID 不对：$GOT_ID（应为 $BUNDLE_ID）" >&2; exit 1
fi
echo "  标识：$GOT_ID"
echo "  版本：$VERSION"
echo "  名称：$DISPLAY"

# 必须声明支持的文件类型，否则双击 .lpx/.yaml 不会打开本应用
if /usr/libexec/PlistBuddy -c "Print :CFBundleDocumentTypes" \
     "$BUILT/Contents/Info.plist" > /dev/null 2>&1; then
  echo "  文件关联：已声明（.lpx / .yaml / .json）"
else
  echo "  文件关联：缺失（双击图纸不会用本应用打开）" >&2; exit 1
fi

if codesign --verify --deep --strict "$BUILT" 2>/dev/null; then
  echo "  签名：有效（ad-hoc）"
else
  # Xcode 有时不签 Release；显式补一个 ad-hoc 签名
  codesign --force --deep --sign - --options runtime "$BUILT" >/dev/null 2>&1 || {
    echo "  ad-hoc 签名失败" >&2; exit 1; }
  codesign --verify --deep --strict "$BUILT" || { echo "  签名仍无效" >&2; exit 1; }
  echo "  签名：已补 ad-hoc 并校验通过"
fi

# ------------------------------------------------------------
# 3. 放到 dist/
# ------------------------------------------------------------
step "3/6" "输出到 $DIST/ ..."
rm -rf "$DIST"
mkdir -p "$DIST"
# 用 ditto 保留扩展属性与签名封条（cp -R 会破坏签名）
ditto "$BUILT" "$DIST/$APP_NAME.app"
codesign --verify --deep --strict "$DIST/$APP_NAME.app" || {
  echo "  拷贝后签名失效" >&2; exit 1; }
SIZE=$(du -sh "$DIST/$APP_NAME.app" | cut -f1 | tr -d ' ')
echo "  $DIST/$APP_NAME.app（$SIZE）"

if [ "$MAKE_DMG" = "0" ]; then
  hr
  echo " 完成（只出 .app）"
  hr
  exit 0
fi

# ------------------------------------------------------------
# 4. 组装 DMG 内容
#
#    应用 + /Applications 快捷方式（拖过去就安装）+ 一份说明。
#    说明里写清 Gatekeeper 提示怎么处理 —— 用户第一次双击
#    大概率会撞上"无法验证开发者"，没有这句话就是死路。
# ------------------------------------------------------------
step "4/6" "组装安装镜像 ..."
STAGE=".build/dmg-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto "$DIST/$APP_NAME.app" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/安装说明.txt" <<TXT
$APP_NAME $VERSION
================================================

安装
  把左边的 $APP_NAME 拖到右边的 Applications 文件夹里。

第一次打开（重要）
  本应用没有 Apple 开发者证书，所以第一次打开时 macOS 会提示
  「无法验证开发者」或「已损坏，无法打开」。这是缺证书，不是文件坏了。

  解决办法（任选一种）：
    1. 在"应用程序"里右键点 $APP_NAME → 打开 → 再点"打开"
    2. 打开"终端"，执行：
         xattr -dr com.apple.quarantine /Applications/$APP_NAME.app

  之后就可以正常双击打开了。

系统要求
  macOS 14 或更高。Apple 芯片与 Intel 都能运行。

打开图纸
  双击 .lpx 或旧管线格式的 .yaml 会自动用本应用打开；
  也可以在应用里用 文件 → 打开。

界面语言
  跟随系统语言：中文系统显示中文，其余显示英文。
TXT

echo "  已放入应用、Applications 快捷方式、安装说明"

# ------------------------------------------------------------
# 5. 生成 DMG
# ------------------------------------------------------------
step "5/6" "生成 DMG ..."
DMG="$DIST/$APP_NAME-$VERSION.dmg"
if ! hdiutil create -volname "$VOL_NAME" -srcfolder "$STAGE" \
      -ov -format UDZO -imagekey zlib-level=9 "$DMG" \
      > /tmp/lightplot_dmg.log 2>&1; then
  echo "  hdiutil 失败：" >&2
  tail -5 /tmp/lightplot_dmg.log >&2
  exit 1
fi
DMG_SIZE=$(du -sh "$DMG" | cut -f1 | tr -d ' ')
echo "  $DMG（$DMG_SIZE）"

# ------------------------------------------------------------
# 6. 验证：真的挂上、真的能跑
# ------------------------------------------------------------
step "6/6" "验证镜像 ..."
MOUNT=$(hdiutil attach "$DMG" -nobrowse -readonly 2>/dev/null \
        | grep -o '/Volumes/.*' | head -1)
if [ -z "$MOUNT" ]; then
  echo "  挂载失败" >&2; exit 1
fi
cleanup() { hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM

[ -d "$MOUNT/$APP_NAME.app" ] || { echo "  镜像里没有应用" >&2; exit 1; }
[ -L "$MOUNT/Applications" ] || { echo "  镜像里没有 Applications 快捷方式" >&2; exit 1; }
[ -f "$MOUNT/安装说明.txt" ] || { echo "  镜像里没有安装说明" >&2; exit 1; }
echo "  内容：应用 + Applications 快捷方式 + 安装说明"

if codesign --verify --deep --strict "$MOUNT/$APP_NAME.app" 2>/dev/null; then
  echo "  镜像内的应用签名有效"
else
  echo "  镜像内的应用签名无效" >&2; exit 1
fi

# 真的启动一次：能起来才算"可用"，静态检查证明不了这一点
if open -a "$MOUNT/$APP_NAME.app" 2>/dev/null; then
  sleep 4
  if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    echo "  从镜像启动：成功（进程已运行）"
    osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || \
      pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    sleep 1
  else
    echo "  从镜像启动：进程没有起来" >&2
    exit 1
  fi
else
  echo "  从镜像启动：open 失败" >&2
  exit 1
fi

cleanup
trap - EXIT INT TERM

SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
echo "  SHA-256：$SHA"

hr
echo " 完成"
echo ""
echo "   dist/$APP_NAME.app          $SIZE"
echo "   dist/$APP_NAME-$VERSION.dmg $DMG_SIZE"
echo ""
echo "   分发前请注意：本机没有开发者证书，DMG 内是 ad-hoc 签名。"
echo "   别人下载后第一次打开需右键 →「打开」，说明文字已放在镜像里。"
hr
