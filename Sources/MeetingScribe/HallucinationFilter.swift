import Foundation
import WhisperKit

/// Whisper が無音や環境音に対して出しがちな定型の誤認識(幻聴)を取り除く。
/// 動画の字幕データで学習している影響で「ご視聴ありがとうございました」や
/// 「(音楽)」のような、実際には誰も話していない文が出ることがある。
enum HallucinationFilter {
    /// これだけで1セグメントになっていたら捨てる定型文。句読点は比較前に落とす。
    private static let knownPhrases: Set<String> = [
        "ご視聴ありがとうございました",
        "ご清聴ありがとうございました",
        "チャンネル登録よろしくお願いします",
        "チャンネル登録お願いします",
        "字幕視聴ありがとうございました"
    ]

    /// (音楽) [拍手] 【字幕】 のような括弧書きの注記と、音符記号。
    private static let annotationPattern = try! NSRegularExpression(
        pattern: #"[(（\[［【][^)）\]］】]*[)）\]］】]|[♪♫～〜]"#
    )

    private static let trimmedCharacters = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "。、.,!！?？"))

    /// 注記を除いたテキストを返す。定型の幻聴だけだった場合は空文字列。
    static func clean(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let stripped = annotationPattern
            .stringByReplacingMatches(in: text, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if knownPhrases.contains(stripped.trimmingCharacters(in: trimmedCharacters)) {
            return ""
        }
        return stripped
    }

    /// 各セグメントのテキストを clean し、空になったセグメントは取り除く。
    static func filter(_ segments: [TranscriptionSegment]) -> [TranscriptionSegment] {
        segments.compactMap { segment in
            let text = clean(segment.text)
            guard !text.isEmpty else { return nil }
            var cleaned = segment
            cleaned.text = text
            return cleaned
        }
    }
}
