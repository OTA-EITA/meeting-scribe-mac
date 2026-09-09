#!/bin/bash
# swift build の成果物を正式な .app バンドルに詰め直すスクリプト。
#
# なぜ必要か: SPM の実行ファイルは Info.plist をリンカで __TEXT,__info_plist に
# 埋め込む方法でマイク権限(TCC)は動作するが、画面/システム音声キャプチャ
# (ScreenCaptureKit)は LaunchServices に正しく登録された .app バンドルでないと
# 権限ダイアログ自体が出ないことが実機検証で判明した。そのためこのスクリプトで
# 通常の macOS アプリと同じ構造(Contents/MacOS, Contents/Info.plist)に組み直す。
#
# 署名は ad-hoc (-) ではなく、setup-dev-signing-cert.sh で作成したローカル
# 署名証明書を使う。ad-hoc は再ビルドごとに署名ハッシュが変わり、画面/システム
# 音声キャプチャの許可が毎回失われてしまうため。証明書が無ければ自動で作成する。
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-debug}"
APP_NAME="MeetingScribe"
BUILD_DIR=".build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
SIGNING_IDENTITY="MeetingScribe Dev"

if ! security find-identity -v -p codesigning ~/Library/Keychains/login.keychain-db 2>/dev/null | grep -q "$SIGNING_IDENTITY"; then
    ./setup-dev-signing-cert.sh
fi

echo "Building ($CONFIG)..."
swift build -c "$CONFIG"

BIN_PATH=$(swift build -c "$CONFIG" --show-bin-path)

echo "Packaging $APP_NAME.app..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN_PATH/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "Sources/$APP_NAME/Info.plist" "$APP_DIR/Contents/Info.plist"

codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP_DIR" >/dev/null 2>&1

echo "Built: $APP_DIR"
