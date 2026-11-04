#!/bin/bash
# UrlQueue.app をビルドして dist/ に組み立て、CLI を PATH に通す。
#
#   ./build.sh            ビルドのみ
#   ./build.sh install    ビルド + /Applications へ配置 + CLI シンボリックリンク作成
#
# 環境変数:
#   BIN_DIR    CLI シンボリックリンクの置き場所（既定 ~/.local/bin）
#   APP_DIR    .app の配置先（既定 /Applications）
#   UNIVERSAL  1 なら arm64 + x86_64 のユニバーサルバイナリ

set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="UrlQueue"
BUNDLE_ID="com.github.takeo.urlqueue"
VERSION="1.0.0"
EXEC_NAME="urlqueue"

BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
APP_DIR="${APP_DIR:-/Applications}"

echo "==> Swift ビルド (release)"
if [ "${UNIVERSAL:-0}" = "1" ]; then
  swift build -c release --arch arm64 --arch x86_64
else
  swift build -c release
fi
BIN_PATH="$(swift build -c release --show-bin-path)/$EXEC_NAME"

APP="dist/$APP_NAME.app"
echo "==> バンドル組み立て: $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/$EXEC_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>                  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>           <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>            <string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key>            <string>$EXEC_NAME</string>
  <key>CFBundlePackageType</key>           <string>APPL</string>
  <key>CFBundleShortVersionString</key>    <string>$VERSION</string>
  <key>CFBundleVersion</key>               <string>$VERSION</string>
  <key>LSMinimumSystemVersion</key>        <string>13.0</string>
  <key>NSHighResolutionCapable</key>       <true/>
  <!-- Dock に出す通常アプリ。メニューバー常駐は実行時に併設する -->
  <key>LSUIElement</key>                   <false/>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> ad-hoc 署名"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 \
  || echo "    (署名をスキップしました。初回起動時に Gatekeeper の確認が出る場合があります)"

echo "==> 完成: $APP"

if [ "${1:-}" = "install" ]; then
  echo "==> $APP_DIR へ配置"
  rm -rf "$APP_DIR/$APP_NAME.app"
  cp -R "$APP" "$APP_DIR/$APP_NAME.app"

  # Launch Services に登録しておく（open -b / Spotlight 用）
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$APP_DIR/$APP_NAME.app" >/dev/null 2>&1 || true

  echo "==> CLI を $BIN_DIR/$EXEC_NAME にリンク"
  mkdir -p "$BIN_DIR"
  ln -sf "$APP_DIR/$APP_NAME.app/Contents/MacOS/$EXEC_NAME" "$BIN_DIR/$EXEC_NAME"

  echo
  echo "インストール完了。"
  case ":$PATH:" in
    *":$BIN_DIR:"*) echo "  urlqueue https://example.com  で使えます" ;;
    *)
      echo "  $BIN_DIR が PATH にありません。シェルの設定に追加してください:"
      echo "    fish: fish_add_path $BIN_DIR"
      echo "    bash/zsh: export PATH=\"$BIN_DIR:\$PATH\""
      ;;
  esac
fi
