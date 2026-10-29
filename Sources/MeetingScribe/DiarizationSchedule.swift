import Foundation

/// 録音中に話者分離をやり直す間隔。話者分離は毎回「録音の最初から今まで」の
/// 音声全体を処理するため、会議が長くなるほど1回が重くなる。固定の間隔だと
/// 長い会議では休みなく CPU を使い続け、文字起こしの邪魔をする。
/// 前回かかった時間に比例して休み、話者分離に使う時間を全体の一定割合までに抑える。
enum DiarizationSchedule {
    /// 短い録音でもこれより短い間隔ではやり直さない。
    static let minimumDelay: Double = 4
    /// 録音中の時間のうち、話者分離に使ってよい割合の上限。
    static let maxBusyRatio: Double = 0.25

    static func delay(afterRunTaking runSeconds: Double) -> Double {
        max(minimumDelay, runSeconds * (1 / maxBusyRatio - 1))
    }
}
