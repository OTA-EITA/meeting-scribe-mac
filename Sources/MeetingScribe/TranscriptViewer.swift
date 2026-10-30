import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 保存済みの議事録を開いたときの中身。
struct OpenedTranscript: Identifiable {
    let id = UUID()
    let url: URL
    let text: String
}

/// 保存済みの議事録を読むシート。暗号化した議事録もここで読め、
/// 必要なときだけ平文の .txt か .md に書き出せる。
struct TranscriptViewer: View {
    let transcript: OpenedTranscript
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(TranscriptFiles.title(for: transcript.url))
                .font(.headline)
            ScrollView {
                Text(transcript.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding()
            }
            .background(Color(nsColor: .textBackgroundColor))
            .cornerRadius(8)
            HStack {
                Button("平文で書き出す…") { exportPlainText() }
                Spacer()
                Button("閉じる") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 420)
    }

    /// 拡張子を .md にすると Markdown で、それ以外はそのままのテキストで書き出す。
    private func exportPlainText() {
        let title = TranscriptFiles.title(for: transcript.url)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "md") ?? .plainText]
        panel.allowsOtherFileTypes = true
        panel.nameFieldStringValue = "\(title).txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let content = url.pathExtension == "md"
            ? TranscriptFormatter.markdown(from: transcript.text, title: title)
            : transcript.text
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }
}
