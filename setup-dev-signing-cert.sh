#!/bin/bash
# 開発用のローカル自己署名コード署名証明書をログインキーチェーンに作成する。
#
# なぜ必要か: SPM の実行ファイルを ad-hoc (`codesign -s -`) で署名すると、
# 再ビルドのたびに署名ハッシュが変わり、macOS の画面/システム音声キャプチャ
# (kTCCServiceScreenCapture) の許可が「別のアプリ」として扱われて毎回失われる
# ことが実機検証で判明した(マイク権限は影響を受けない)。
# ログインキーチェーン内の安定した署名アイデンティティを使うことで、
# 再ビルドしても同じアプリとして認識され、一度許可すれば維持される。
#
# この証明書はコード署名専用で、他の用途(SSL/TLS等)の信頼設定には影響しない。
set -euo pipefail
cd "$(dirname "$0")"

CERT_NAME="MeetingScribe Dev"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

if security find-identity -v -p codesigning ~/Library/Keychains/login.keychain-db 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "署名証明書 '$CERT_NAME' は既に存在します。何もしません。"
    exit 0
fi

echo "自己署名コード署名証明書を作成しています..."
openssl req -x509 -newkey rsa:2048 -keyout "$WORK_DIR/key.pem" -out "$WORK_DIR/cert.pem" -days 3650 -nodes \
    -subj "/CN=$CERT_NAME" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:false"

PASSPHRASE=$(openssl rand -hex 16)
openssl pkcs12 -export -out "$WORK_DIR/cert.p12" \
    -inkey "$WORK_DIR/key.pem" -in "$WORK_DIR/cert.pem" \
    -passout "pass:$PASSPHRASE"

echo "ログインキーチェーンへインポートしています..."
security import "$WORK_DIR/cert.p12" -k ~/Library/Keychains/login.keychain-db -P "$PASSPHRASE" -T /usr/bin/codesign -A

echo "コード署名用に信頼設定しています..."
security add-trusted-cert -p codeSign -k ~/Library/Keychains/login.keychain-db "$WORK_DIR/cert.pem"

echo "完了。以下のアイデンティティが使えるようになりました:"
security find-identity -v -p codesigning ~/Library/Keychains/login.keychain-db
