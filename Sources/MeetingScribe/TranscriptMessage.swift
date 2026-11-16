import Foundation

/// エンジン(TranscriptionServer)とUI(TranscriptClient)の間でやり取りする
/// ローカルWebSocketメッセージ。type で用途を切り替える簡易プロトコル。
struct TranscriptMessage: Codable {
    var type: String // "status" | "transcript" | "error" | "warning" | "control"
    var status: String? // "modelLoading" | "ready" | "recording" | "stopped"
    var confirmedText: String?
    var unconfirmedText: String?
    /// 確定前の部分まで含めた、話者ラベル付きの文字起こし。最後の数かたまりは後ろに
    /// 続きの音声が来るまで確定しないので、短く話して黙ると confirmedText に出てこない。
    /// 外部のツールがすぐに受け取れるように送る。確定前の部分は後で書き換わることがある
    var liveText: String?
    var message: String?
    var action: String? // control: "start" | "stop"
}
