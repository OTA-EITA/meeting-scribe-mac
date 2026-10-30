import Foundation
import SwiftUI

/// TranscriptionServer にローカルWebSocketで接続し、状態・文字起こし結果を
/// 受信してUIへ公開するクライアント。メインウィンドウ・字幕オーバーレイの
/// 両方がこれを共有(または個別に接続)して同じリアルタイム結果を表示する。
///
/// 接続には RawWebSocketClient (生のBSDソケット実装) を使う。このマシンでは
/// FortiClientのVPN用NetworkExtensionがループバックの NWConnection 通信を
/// 中断させてしまう(ECONNABORTED)ため、Network.framework を経由しない
/// クライアント実装が必要だった。
@MainActor
final class TranscriptClient: ObservableObject {
    @Published var statusText = "接続しています…"
    @Published var isModelLoading = true
    @Published var isRecording = false
    @Published var isDiarizing = false
    /// 録音は続いているが、結果に影響する問題(システム音声を取れない等)。次の録音開始で消す。
    @Published var warningText: String?
    /// 字幕オーバーレイの背景の不透明度(0〜1)。ユーザーがスライダーで調整できる。
    @Published var overlayOpacity: Double = 0.6
    /// 現在の録音セッション中の確定/未確定テキスト(ライブキャプション用)
    @Published var confirmedText = ""
    @Published var unconfirmedText = ""
    /// セッションをまたいで蓄積した文字起こし全文(保存・一覧表示用)
    @Published var transcript = ""
    /// 直前の録音セッションで自動保存された議事録(.txt か .txt.enc)の場所
    @Published var lastExportURL: URL?

    private var client: RawWebSocketClient?
    private let port: UInt16

    init(port: UInt16 = TranscriptionServer.port) {
        self.port = port
    }

    func connect() {
        guard client == nil else { return }
        let newClient = RawWebSocketClient(host: "127.0.0.1", port: port)
        newClient.onText = { [weak self] text in
            Task { @MainActor in self?.handle(text) }
        }
        newClient.onClose = { [weak self] in
            Task { @MainActor in self?.scheduleReconnect() }
        }
        client = newClient

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let connected = newClient.connect()
            if !connected {
                Task { @MainActor in self?.scheduleReconnect() }
            }
        }
    }

    private func scheduleReconnect() {
        client?.disconnect()
        client = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.connect()
        }
    }

    /// (internal: 単体テストから直接メッセージを渡せるようにするため private にしていない)
    func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let message = try? JSONDecoder().decode(TranscriptMessage.self, from: data) else { return }
        switch message.type {
        case "status":
            switch message.status {
            case "modelLoading":
                isModelLoading = true
                statusText = "モデルを準備しています…"
            case "ready":
                isModelLoading = false
                isRecording = false
                statusText = "準備完了。録音を開始してください。"
            case "recording":
                isRecording = true
                warningText = nil
                confirmedText = ""
                unconfirmedText = ""
                statusText = "録音中…"
            case "diarizing":
                isRecording = false
                isDiarizing = true
                statusText = "話者を分析しています…"
            case "stopped":
                isRecording = false
                isDiarizing = false
                lastExportURL = message.message.map { URL(fileURLWithPath: $0) }
                finalizeSession()
                statusText = "完了。続けて録音できます。"
            default:
                break
            }
        case "transcript":
            confirmedText = message.confirmedText ?? confirmedText
            unconfirmedText = message.unconfirmedText ?? ""
        case "error":
            statusText = message.message ?? "エラーが発生しました"
        case "warning":
            warningText = message.message
        default:
            break
        }
    }

    private func finalizeSession() {
        let sessionText = (confirmedText + unconfirmedText).trimmingCharacters(in: .whitespacesAndNewlines)
        if !sessionText.isEmpty {
            transcript = transcript.isEmpty ? sessionText : transcript + "\n" + sessionText
        }
        confirmedText = ""
        unconfirmedText = ""
    }

    /// 「相手1」などのラベルを実際の名前に付け替える。画面の全文と、
    /// 直前に自動保存した議事録を、保存したときと同じ形式で書き直す。
    /// 保存先フォルダの外を指していたら、ファイルには触れない。
    func renameSpeakers(_ mapping: [String: String], exportFolder: URL = ExportSettings.folderURL) {
        transcript = TranscriptFormatter.renameSpeakers(in: transcript, mapping: mapping)
        guard let lastExportURL else { return }
        guard TranscriptFiles.isExportedTranscript(lastExportURL, in: exportFolder) else {
            statusText = "保存先フォルダの外のファイルは書き直しません"
            return
        }
        do {
            let saved = try TranscriptFiles.read(lastExportURL)
            let renamed = TranscriptFormatter.renameSpeakers(in: saved, mapping: mapping)
            try TranscriptFiles.rewrite(renamed, at: lastExportURL)
        } catch {
            statusText = "議事録の書き直しに失敗しました: \(error.localizedDescription)"
        }
    }

    func startRecording() {
        send(TranscriptMessage(type: "control", status: nil, confirmedText: nil, unconfirmedText: nil, message: nil, action: "start"))
    }

    func stopRecording() {
        send(TranscriptMessage(type: "control", status: nil, confirmedText: nil, unconfirmedText: nil, message: nil, action: "stop"))
    }

    /// ModelSettings に保存したモデルへ差し替えるようエンジンに頼む。
    func reloadModel() {
        send(TranscriptMessage(type: "control", status: nil, confirmedText: nil, unconfirmedText: nil, message: nil, action: "reloadModel"))
    }

    private func send(_ message: TranscriptMessage) {
        guard let data = try? JSONEncoder().encode(message), let text = String(data: data, encoding: .utf8) else { return }
        client?.send(text: text)
    }
}
