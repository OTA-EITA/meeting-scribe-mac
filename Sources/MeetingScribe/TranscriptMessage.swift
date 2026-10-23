import Foundation

/// エンジン(TranscriptionServer)とUI(TranscriptClient)の間でやり取りする
/// ローカルWebSocketメッセージ。type で用途を切り替える簡易プロトコル。
struct TranscriptMessage: Codable {
    var type: String // "status" | "transcript" | "error" | "warning" | "control"
    var status: String? // "modelLoading" | "ready" | "recording" | "stopped"
    var confirmedText: String?
    var unconfirmedText: String?
    var message: String?
    var action: String? // control: "start" | "stop"
}
