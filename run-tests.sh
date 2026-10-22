#!/bin/bash
# swift test を Command Line Tools だけの環境で動かすスクリプト。
#
# なぜ必要か: Xcode 本体が無いと XCTest は使えないが、Swift Testing は
# Command Line Tools に同梱されている。ただしそのフレームワークの場所は
# 既定の検索パスに入っていないため、コンパイラとリンカに明示的に渡す。
set -euo pipefail
cd "$(dirname "$0")"

DEV_DIR="$(xcode-select -p)"
FRAMEWORKS="$DEV_DIR/Library/Developer/Frameworks"
LIBS="$DEV_DIR/Library/Developer/usr/lib"

swift test \
    -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
    -Xlinker -F -Xlinker "$FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$LIBS" \
    "$@"
