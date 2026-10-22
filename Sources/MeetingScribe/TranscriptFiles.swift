import Foundation

/// 議事録ファイルの書き出し。.txt を正とし、設定に応じて同じ名前の .md を
/// .txt の内容から作り直す。自動保存(エンジン)と、相手の名前を付け替えた後の
/// 書き直し(UI)の両方から使う。
enum TranscriptFiles {
    static func write(_ text: String, to textURL: URL) throws {
        try text.write(to: textURL, atomically: true, encoding: .utf8)
        guard ExportSettings.saveMarkdown else { return }
        let title = textURL.deletingPathExtension().lastPathComponent
        let markdown = TranscriptFormatter.markdown(from: text, title: title)
        try markdown.write(to: markdownURL(for: textURL), atomically: true, encoding: .utf8)
    }

    static func markdownURL(for textURL: URL) -> URL {
        textURL.deletingPathExtension().appendingPathExtension("md")
    }

    /// 保存先フォルダの直下にある .txt かどうか。書き直す前に確かめ、エンジンを装った
    /// 別のプロセスから任意のファイルを書き換えさせられないようにする。
    /// シンボリックリンクと「..」は解決してから比べる。
    static func isExportedTranscript(_ url: URL, in folder: URL) -> Bool {
        let file = url.standardizedFileURL.resolvingSymlinksInPath()
        let expectedFolder = folder.standardizedFileURL.resolvingSymlinksInPath()
        return file.pathExtension == "txt"
            && file.deletingLastPathComponent().path == expectedFolder.path
    }
}
