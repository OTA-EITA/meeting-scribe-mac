import Foundation

/// 文字起こしの区切りが、録音のどの時間を覆っているかを調べる。
///
/// WhisperKit はときどき 30 秒の区切りを丸ごと空の文字で返す。停止後に録音全体を文字起こしし直したとき、
/// 文字の入っていない時間を見つけてそこだけ文字起こしし直したり、録音中にできた文字で埋めたりするのに使う。
enum TranscriptCoverage {
    typealias Span = (start: Float, end: Float)

    /// 0 秒から duration 秒までのうち、covered のどれにも覆われていない minimum 秒以上の時間
    static func gaps(covered: [Span], duration: Float, minimum: Float = 3) -> [Span] {
        var gaps: [Span] = []
        var cursor: Float = 0
        for span in covered.sorted(by: { $0.start < $1.start }) {
            if span.start - cursor >= minimum {
                gaps.append((cursor, span.start))
            }
            cursor = max(cursor, span.end)
        }
        if duration - cursor >= minimum {
            gaps.append((cursor, duration))
        }
        return gaps
    }

    /// text の言葉が reference にどれだけ出てくるか(0〜1)。2 文字ずつの組で比べるので、
    /// 句読点や誤認識の違いが少しあっても同じ内容なら高くなる
    static func containment(of text: String, in reference: String) -> Double {
        let pairs = bigrams(text)
        guard !pairs.isEmpty else { return 1 }
        let referencePairs = Set(bigrams(reference))
        return Double(pairs.filter { referencePairs.contains($0) }.count) / Double(pairs.count)
    }

    private static func bigrams(_ text: String) -> [String] {
        let characters = Array(text.filter { !$0.isWhitespace && !$0.isPunctuation })
        guard characters.count >= 2 else { return characters.isEmpty ? [] : [String(characters)] }
        return (0..<(characters.count - 1)).map { String(characters[$0...$0 + 1]) }
    }

    /// 録音中の区切りのうち、議事録に入っていないものの番号。時間で覆われていても、Whisper は区切りの
    /// 終わりの時刻を実際より後ろに伸ばすことがあるので、前後 window 秒の議事録の文字に言葉が
    /// 半分も出てこなければ入っていないとみなす
    static func missing(live: [(span: Span, text: String)], final: [(span: Span, text: String)], window: Float = 5) -> [Int] {
        let byTime = Set(uncovered(candidates: live.map(\.span), covered: final.map(\.span)))
        return live.indices.filter { index in
            if byTime.contains(index) { return true }
            let span = live[index].span
            let nearby = final
                .filter { $0.span.end > span.start - window && $0.span.start < span.end + window }
                .map(\.text)
                .joined()
            return containment(of: live[index].text, in: nearby) < 0.5
        }
    }

    /// candidates のうち、covered に半分以上覆われていないものの番号
    static func uncovered(candidates: [Span], covered: [Span]) -> [Int] {
        candidates.indices.filter { index in
            let candidate = candidates[index]
            let length = candidate.end - candidate.start
            guard length > 0 else { return false }
            let overlap = covered.reduce(Float(0)) { total, span in
                total + max(0, min(candidate.end, span.end) - max(candidate.start, span.start))
            }
            return overlap < length / 2
        }
    }
}
