#!/bin/bash
# release でビルドした MeetingScribe.app を /Applications に入れて起動する。
#
# 入れたあとの最初の起動で、マイクとシステム音声の許可をまとめて求める
# (Permissions.swift)。署名の証明書が変わらないかぎり、入れ直しても許可は残る。
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="MeetingScribe"
DEST="/Applications/$APP_NAME.app"

./build-app.sh release

if pgrep -x "$APP_NAME" >/dev/null; then
    echo "Quitting the running $APP_NAME..."
    osascript -e "quit app \"$APP_NAME\"" || true
    while pgrep -x "$APP_NAME" >/dev/null; do sleep 0.5; done
fi

echo "Installing to $DEST..."
rm -rf "$DEST"
cp -R ".build/$APP_NAME.app" "$DEST"

open "$DEST"
echo "Installed: $DEST"
