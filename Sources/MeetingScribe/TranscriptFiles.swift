import Foundation
import CryptoKit

/// 議事録ファイルの書き出しと読み込み。自動保存(エンジン)と、相手の名前を付け替えた後の
/// 書き直し・保存済みの議事録を開く(UI)の両方から使う。
///
/// 暗号化するときは `.txt.enc` だけを書き、平文の .md は作らない。
/// 暗号化しないときは .txt を正とし、設定に応じて同じ名前の .md を .txt の内容から作り直す。
enum TranscriptFiles {
    static let sealedExtension = "enc"

    /// 書き出して、実際に書いたファイルの場所を返す。
    @discardableResult
    static func write(_ text: String, to textURL: URL,
                      encrypt: Bool = ExportSettings.encrypt,
                      markdown: Bool = ExportSettings.saveMarkdown,
                      key: () throws -> SymmetricKey = TranscriptKeyStore.key) throws -> URL {
        if encrypt {
            let url = sealedURL(for: textURL)
            try TranscriptCrypto.seal(text, using: key()).write(to: url, options: .atomic)
            return url
        }
        try text.write(to: textURL, atomically: true, encoding: .utf8)
        if markdown {
            let markdownText = TranscriptFormatter.markdown(from: text, title: title(for: textURL))
            try markdownText.write(to: markdownURL(for: textURL), atomically: true, encoding: .utf8)
        }
        return textURL
    }

    /// 既にあるファイルを、そのファイルと同じ形式(暗号化か平文か)で書き直す。
    static func rewrite(_ text: String, at url: URL,
                        markdown: Bool = ExportSettings.saveMarkdown,
                        key: () throws -> SymmetricKey = TranscriptKeyStore.key) throws {
        if isSealedFile(url) {
            try write(text, to: url.deletingPathExtension(), encrypt: true, key: key)
        } else {
            try write(text, to: url, encrypt: false, markdown: markdown, key: key)
        }
    }

    /// 暗号化した議事録なら復号し、平文ならそのまま読む。
    static func read(_ url: URL, key: () throws -> SymmetricKey = TranscriptKeyStore.key) throws -> String {
        let data = try Data(contentsOf: url)
        if TranscriptCrypto.isSealed(data) {
            return try TranscriptCrypto.open(data, using: key())
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw TranscriptCrypto.Failure.notUTF8
        }
        return text
    }

    static func markdownURL(for textURL: URL) -> URL {
        textURL.deletingPathExtension().appendingPathExtension("md")
    }

    static func sealedURL(for textURL: URL) -> URL {
        textURL.appendingPathExtension(sealedExtension)
    }

    /// 「議事録_2026-10-30_10-00-00」のような、拡張子を除いた名前。
    static func title(for url: URL) -> String {
        let base = isSealedFile(url) ? url.deletingPathExtension() : url
        return base.deletingPathExtension().lastPathComponent
    }

    private static func isSealedFile(_ url: URL) -> Bool {
        url.pathExtension == sealedExtension && url.deletingPathExtension().pathExtension == "txt"
    }

    /// 保存先フォルダの直下にある .txt か .txt.enc かどうか。書き直す前に確かめ、
    /// エンジンを装った別のプロセスから任意のファイルを書き換えさせられないようにする。
    /// シンボリックリンクと「..」は解決してから比べる。
    static func isExportedTranscript(_ url: URL, in folder: URL) -> Bool {
        let file = url.standardizedFileURL.resolvingSymlinksInPath()
        let expectedFolder = folder.standardizedFileURL.resolvingSymlinksInPath()
        return (file.pathExtension == "txt" || isSealedFile(file))
            && file.deletingLastPathComponent().path == expectedFolder.path
    }
}
