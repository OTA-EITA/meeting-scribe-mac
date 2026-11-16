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
