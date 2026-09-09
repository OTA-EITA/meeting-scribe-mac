import Foundation
import Network
import WhisperKit
import SpeakerKit

/// 録音・WhisperKitのリアルタイム文字起こしを実行し、結果をローカルWebSocketで
/// 配信するエンジン。UI(TranscriptClient)はこれに ws://127.0.0.1:<port> で
/// 接続し、start/stop の制御と文字起こし結果の受信を行う。
/// メイン画面と字幕オーバーレイの両方が同じ配信を購読できるようにするため、
/// 直接関数呼び出しではなくローカルWebSocketを介した設計にしている。
@MainActor
final class TranscriptionServer {
    nonisolated static let port: UInt16 = 8765

    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var whisperKit: WhisperKit?
    private var speakerKit: SpeakerKit?
    private var audioStreamTranscriber: AudioStreamTranscriber?
    private var latestTranscriberState: AudioStreamTranscriber.State?
    private var isRecording = false
    private var modelReady = false
    private var modelLoadError: String?

    /// 同じ話者の発話が続く場合でも、これ以上の無音が空いたら改行する。
    private let pauseBreakThreshold: Float = 1.5

    func start() {
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
        parameters.allowLocalEndpointReuse = true

        do {
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: Self.port)!)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.accept(connection)
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            print("TranscriptionServer: リスナーの起動に失敗しました: \(error)")
        }

        Task {
            await loadModel()
        }
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        var receivingStarted = false
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                guard !receivingStarted else { return }
                receivingStarted = true
                WebSocketIO.receiveLoop(on: connection) { text in
                    Task { @MainActor in self?.handleIncoming(text) }
                } onClose: {
                    Task { @MainActor in
                        connection.cancel()
                        self?.connections.removeAll { $0 === connection }
                    }
                }
                Task { @MainActor in self?.sendCurrentStatus(to: connection) }
            case .failed, .cancelled:
                Task { @MainActor in
                    self?.connections.removeAll { $0 === connection }
                }
            default:
                break
            }
        }
        connection.start(queue: .main)
    }

    private func handleIncoming(_ text: String) {
        guard let data = text.data(using: .utf8),
              let message = try? JSONDecoder().decode(TranscriptMessage.self, from: data),
              message.type == "control" else { return }
        switch message.action {
        case "start": startRecording()
        case "stop": stopRecording()
        default: break
        }
    }

    private func loadModel() async {
        broadcast(TranscriptMessage(type: "status", status: "modelLoading"))
        do {
            // "base" は日本語の認識精度が低く、繰り返しや幻聴的な誤認識が目立ったため
            // "small" に変更。M2 Mac ではリアルタイム処理に十分な速度が出る。
            // audioProcessor は MixedAudioProcessor に差し替え、マイクだけでなく
            // システム出力音声(Meet相手の声など)も合成して文字起こし対象にする。
            let pipe = try await WhisperKit(model: "small", audioProcessor: MixedAudioProcessor(), load: true)
            whisperKit = pipe
            modelReady = true
            broadcast(TranscriptMessage(type: "status", status: "ready"))
        } catch {
            modelLoadError = error.localizedDescription
            broadcast(TranscriptMessage(type: "error", message: "モデルの読み込みに失敗しました: \(error.localizedDescription)"))
        }

        // 話者分離モデルはベストエフォート。読み込みに失敗しても文字起こし自体は
        // 続行できるようにし、その場合は話者ラベル無しのテキストにフォールバックする。
        do {
            speakerKit = try await SpeakerKit(PyannoteConfig(download: true, load: true))
        } catch {
            print("TranscriptionServer: 話者分離モデルの読み込みに失敗しました: \(error)")
        }
    }

    private func startRecording() {
        guard let whisperKit, modelReady, !isRecording, let tokenizer = whisperKit.tokenizer else { return }
        isRecording = true
        broadcast(TranscriptMessage(type: "status", status: "recording"))

        let transcriber = AudioStreamTranscriber(
            audioEncoder: whisperKit.audioEncoder,
            featureExtractor: whisperKit.featureExtractor,
            segmentSeeker: whisperKit.segmentSeeker,
            textDecoder: whisperKit.textDecoder,
            tokenizer: tokenizer,
            audioProcessor: whisperKit.audioProcessor,
            decodingOptions: DecodingOptions(language: "ja", usePrefillPrompt: true, skipSpecialTokens: true)
        ) { [weak self] _, newState in
            Task { @MainActor in
                guard let self else { return }
                self.latestTranscriberState = newState
                let confirmed = self.joinWithPauseBreaks(newState.confirmedSegments)
                let unconfirmed = newState.unconfirmedSegments.map { $0.text }.joined()
                self.broadcast(TranscriptMessage(type: "transcript", confirmedText: confirmed, unconfirmedText: unconfirmed))
            }
        }
        audioStreamTranscriber = transcriber

        Task {
            do {
                try await transcriber.startStreamTranscription()
            } catch {
                await MainActor.run {
                    self.broadcast(TranscriptMessage(type: "error", message: "録音を開始できませんでした: \(error.localizedDescription)"))
                    self.isRecording = false
                }
            }
        }
    }

    private func stopRecording() {
        guard isRecording, let transcriber = audioStreamTranscriber else { return }
        isRecording = false
        Task {
            await transcriber.stopStreamTranscription()
            await self.finalizeWithSpeakerLabels()
        }
    }

    /// 停止後、録音全体に対して話者分離を実行し、話者ラベル付きの最終テキストを
    /// 配信・ローカルへ議事録として自動書き出しする。話者分離モデルが未ロード、
    /// もしくは失敗した場合はポーズ区切りのみのテキストのままにする。
    private func finalizeWithSpeakerLabels() async {
        guard let whisperKit, let state = latestTranscriberState else {
            broadcast(TranscriptMessage(type: "status", status: "stopped"))
            return
        }
        let allSegments = state.confirmedSegments + state.unconfirmedSegments
        guard !allSegments.isEmpty else {
            broadcast(TranscriptMessage(type: "status", status: "stopped"))
            return
        }

        var finalText = joinWithPauseBreaks(allSegments)

        if let speakerKit {
            broadcast(TranscriptMessage(type: "status", status: "diarizing"))
            let fullAudio = Array(whisperKit.audioProcessor.audioSamples)
            do {
                let diarization = try await speakerKit.diarize(audioArray: fullAudio)
                finalText = labelSegments(allSegments, with: diarization)
            } catch {
                print("TranscriptionServer: 話者分離に失敗しました: \(error)")
            }
        }

        broadcast(TranscriptMessage(type: "transcript", confirmedText: finalText, unconfirmedText: ""))
        exportTranscript(finalText)
        broadcast(TranscriptMessage(type: "status", status: "stopped"))
    }

    /// 録音セッションの最終テキストを、設定された保存先フォルダへ議事録として自動書き出しする。
    private func exportTranscript(_ text: String) {
        guard !text.isEmpty else { return }
        let folder = ExportSettings.folderURL
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let fileURL = folder.appendingPathComponent("議事録_\(formatter.string(from: Date())).txt")
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            print("TranscriptionServer: 議事録の自動書き出しに失敗しました: \(error)")
        }
    }

    /// 無音区間が閾値を超えたら改行を挟んでセグメントのテキストを連結する。
    /// (internal: 単体テストから直接検証できるようにするため private にしていない)
    func joinWithPauseBreaks(_ segments: [TranscriptionSegment]) -> String {
        guard let first = segments.first else { return "" }
        var result = first.text
        var previousEnd = first.end
        for segment in segments.dropFirst() {
            if segment.start - previousEnd > pauseBreakThreshold {
                result += "\n"
            }
            result += segment.text
            previousEnd = segment.end
        }
        return result
    }

    /// 各文字起こしセグメントに、時間的に最も重なりの大きい話者のラベルを付けて連結する。
    /// 話者が切り替わる、または無音区間が閾値を超えたタイミングで改行する。
    func labelSegments(_ segments: [TranscriptionSegment], with diarization: DiarizationResult) -> String {
        guard !segments.isEmpty else { return "" }
        var result = ""
        var previousEnd: Float?
        var previousLabel: String?
        for segment in segments {
            let label = dominantSpeakerLabel(for: segment, in: diarization)
            let gap = previousEnd.map { segment.start - $0 } ?? .infinity
            if label != previousLabel {
                result += result.isEmpty ? "" : "\n"
                result += "[\(label)] "
            } else if gap > pauseBreakThreshold {
                result += "\n"
            }
            result += segment.text
            previousEnd = segment.end
            previousLabel = label
        }
        return result
    }

    private func dominantSpeakerLabel(for segment: TranscriptionSegment, in diarization: DiarizationResult) -> String {
        var overlapBySpeaker: [Int: Float] = [:]
        for speakerSegment in diarization.segments {
            guard let speakerId = speakerSegment.speaker.speakerId else { continue }
            let overlapStart = max(segment.start, speakerSegment.startTime)
            let overlapEnd = min(segment.end, speakerSegment.endTime)
            let overlap = overlapEnd - overlapStart
            guard overlap > 0 else { continue }
            overlapBySpeaker[speakerId, default: 0] += overlap
        }
        guard let best = overlapBySpeaker.max(by: { $0.value < $1.value }) else {
            return "話者不明"
        }
        return "話者\(best.key + 1)"
    }

    private func broadcast(_ message: TranscriptMessage) {
        guard let data = try? JSONEncoder().encode(message), let text = String(data: data, encoding: .utf8) else { return }
        for connection in connections {
            WebSocketIO.send(text, on: connection)
        }
    }

    private func sendCurrentStatus(to connection: NWConnection) {
        let status = modelReady ? (isRecording ? "recording" : "ready") : "modelLoading"
        guard let data = try? JSONEncoder().encode(TranscriptMessage(type: "status", status: status)),
              let text = String(data: data, encoding: .utf8) else { return }
        WebSocketIO.send(text, on: connection)
        if let modelLoadError {
            guard let errData = try? JSONEncoder().encode(TranscriptMessage(type: "error", message: "モデルの読み込みに失敗しました: \(modelLoadError)")),
                  let errText = String(data: errData, encoding: .utf8) else { return }
            WebSocketIO.send(errText, on: connection)
        }
    }
}
