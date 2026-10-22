import Foundation

/// 議事録テキストの整形。テキストは TranscriptionServer.labelSegmentsHybrid が
/// 作る「[hh:mm:ss] [話者] 発言」の行の並びを前提にする(話者は変わった行にだけ付く)。
enum TranscriptFormatter {
    /// 録音開始からの経過秒を hh:mm:ss にする。端数は切り捨てる。
    static func elapsed(_ seconds: Float) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }

    private static let linePattern = try! NSRegularExpression(
        pattern: #"^\[(\d{2}:\d{2}:\d{2})\] (?:\[([^\]]+)\] )?(.*)$"#
    )

    /// 議事録テキストを Markdown の箇条書きにする。話者が省かれた行は直前の話者を引き継ぐ。
    static func markdown(from text: String, title: String) -> String {
        var lines = ["# \(title)", ""]
        var speaker: String?
        for line in text.components(separatedBy: "\n") where !line.isEmpty {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = linePattern.firstMatch(in: line, range: range),
                  let timeRange = Range(match.range(at: 1), in: line),
                  let bodyRange = Range(match.range(at: 3), in: line) else {
                lines.append("- \(line)")
                continue
            }
            if let speakerRange = Range(match.range(at: 2), in: line) {
                speaker = String(line[speakerRange])
            }
            let head = [String(line[timeRange]), speaker].compactMap { $0 }.joined(separator: " ")
            lines.append("- **\(head)**: \(line[bodyRange])")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static let otherSpeakerPattern = try! NSRegularExpression(pattern: #"\[(相手\d*)\]"#)

    /// テキストに出てくる「相手」「相手1」…のラベルを、初出の順に重複なく返す。
    static func otherSpeakerLabels(in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        var labels: [String] = []
        for match in otherSpeakerPattern.matches(in: text, range: range) {
            guard let labelRange = Range(match.range(at: 1), in: text) else { continue }
            let label = String(text[labelRange])
            if !labels.contains(label) {
                labels.append(label)
            }
        }
        return labels
    }

    /// 「[相手1]」のような角括弧付きのラベルだけを置き換える。新しい名前が空なら元のままにする。
    static func renameSpeakers(in text: String, mapping: [String: String]) -> String {
        var result = text
        for (label, name) in mapping {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            result = result.replacingOccurrences(of: "[\(label)]", with: "[\(trimmed)]")
        }
        return result
    }
}
