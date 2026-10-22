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

KEYCHAIN=~/Library/Keychains/login.keychain-db

# --recreate: 既存の証明書と鍵(と信頼設定)を消して作り直す。以前の版のスクリプトで
# 作った鍵は、どのアプリからでも使える設定(-A)のままなので、作り直して塞ぐ。
# 作り直すと署名が変わるため、画面/システム音声キャプチャの許可を一度与え直す必要がある。
if [ "${1:-}" = "--recreate" ]; then
    while security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$CERT_NAME"; do
        security delete-identity -c "$CERT_NAME" -t "$KEYCHAIN"
    done
fi

if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$CERT_NAME"; then
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
# 秘密鍵を使えるのは codesign だけにする。-A(全アプリに許可)を付けると、
# 他のプログラムが同じ証明書で署名し、このアプリへの許可を横取りできてしまう。
security import "$WORK_DIR/cert.p12" -k "$KEYCHAIN" -P "$PASSPHRASE" -T /usr/bin/codesign

echo "コード署名用に信頼設定しています..."
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$WORK_DIR/cert.pem"

echo "完了。以下のアイデンティティが使えるようになりました:"
security find-identity -v -p codesigning "$KEYCHAIN"
