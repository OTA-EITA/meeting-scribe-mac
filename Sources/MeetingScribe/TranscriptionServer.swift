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

    /// 録音中に定期的に更新される話者分離結果。確定していればライブ配信にも
    /// 話者ラベルを反映する(停止後の最終結果はこれとは別に全体を再解析する)。
    /// これは「相手」側で複数人を区別するためだけに使い、自分か相手かの
    /// 一次判定はマイク/システム音声のどちらが優勢だったかで確実に行う
    /// (MixedAudioProcessor.dominantSource)。
    /// (internal: 単体テストから直接設定できるようにするため private にしていない)
    var latestDiarization: DiarizationResult?
    private var diarizationTask: Task<Void, Never>?
    private let diarizationInterval: UInt64 = 4_000_000_000 // 4秒ごと

    /// pyannote の話者IDを「相手1」「相手2」…という表示用の番号に固定するための
    /// マッピング。セッション(録音)ごとにリセットする。
    private var otherSpeakerNumbering: [Int: Int] = [:]

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
        latestDiarization = nil
        otherSpeakerNumbering = [:]
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
                let confirmed = self.labelSegmentsHybrid(newState.confirmedSegments)
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

        startPeriodicDiarization()
    }

    private func stopRecording() {
        guard isRecording, let transcriber = audioStreamTranscriber else { return }
        isRecording = false
        stopPeriodicDiarization()
        Task {
            await transcriber.stopStreamTranscription()
            await self.finalizeWithSpeakerLabels()
        }
    }

    /// 録音中、数秒おきに録音全体(その時点まで)に対して話者分離をやり直し、
    /// 結果を latestDiarization に反映する。次にAudioStreamTranscriberから
    /// コールバックが来た時点でライブ配信のテキストにも話者ラベルが付くようになる。
    /// 録音が長くなるほど1回あたりの処理時間は伸びるが、間隔を空けているため
    /// 通常の会議の長さでは実用上問題にならない想定。
    private func startPeriodicDiarization() {
        guard speakerKit != nil else { return }
        diarizationTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: self.diarizationInterval)
                guard !Task.isCancelled, self.isRecording,
                      let whisperKit = self.whisperKit, let speakerKit = self.speakerKit else { continue }
                let snapshot = Array(whisperKit.audioProcessor.audioSamples)
                guard snapshot.count > 16_000 else { continue } // 1秒未満はスキップ
                if let result = try? await speakerKit.diarize(audioArray: snapshot) {
                    self.latestDiarization = result
                }
            }
        }
    }

    private func stopPeriodicDiarization() {
        diarizationTask?.cancel()
        diarizationTask = nil
    }

    /// 停止後、録音全体に対して話者分離をやり直し、自分/相手のラベル付きの
    /// 最終テキストを配信・ローカルへ議事録として自動書き出しする。話者分離
    /// モデルが未ロード、もしくは失敗した場合も、自分/相手の判定はマイク/
    /// システム音声のどちらが優勢だったかで(話者分離とは独立に)行える。
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

        if let speakerKit {
            broadcast(TranscriptMessage(type: "status", status: "diarizing"))
            let fullAudio = Array(whisperKit.audioProcessor.audioSamples)
            do {
                latestDiarization = try await speakerKit.diarize(audioArray: fullAudio)
            } catch {
                print("TranscriptionServer: 話者分離に失敗しました: \(error)")
            }
        }
        let finalText = labelSegmentsHybrid(allSegments)

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

    /// マイク/システム音声のどちらが優勢だったかで「自分」「相手」を確実に判定し、
    /// 「相手」側だけ話者分離で相手1・相手2…と区別する。音源の判定材料が無い
    /// (MixedAudioProcessor 以外を使っている等)場合は、話者分離のみによる
    /// 従来のラベル付けにフォールバックする。
    func labelSegmentsHybrid(_ segments: [TranscriptionSegment]) -> String {
        guard !segments.isEmpty else { return "" }
        let mixedProcessor = whisperKit?.audioProcessor as? MixedAudioProcessor

        var result = ""
        var previousEnd: Float?
        var previousLabel: String?
        for segment in segments {
            let label = hybridLabel(for: segment, mixedProcessor: mixedProcessor)
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

    private func hybridLabel(for segment: TranscriptionSegment, mixedProcessor: MixedAudioProcessor?) -> String {
        guard let isSelf = mixedProcessor?.dominantSource(fromTime: segment.start, toTime: segment.end) else {
            // 音源情報が無ければ話者分離のみでのラベルにフォールバック
            guard let diarization = latestDiarization else { return "不明" }
            return dominantSpeakerLabel(for: segment, in: diarization)
        }
        guard !isSelf else { return UserProfile.selfLabel }

        guard let diarization = latestDiarization,
              let speakerId = dominantSpeakerId(for: segment, in: diarization) else {
            return "相手"
        }
        if let number = otherSpeakerNumbering[speakerId] {
            return "相手\(number)"
        }
        let number = otherSpeakerNumbering.count + 1
        otherSpeakerNumbering[speakerId] = number
        return "相手\(number)"
    }

    private func dominantSpeakerLabel(for segment: TranscriptionSegment, in diarization: DiarizationResult) -> String {
        guard let best = dominantSpeakerId(for: segment, in: diarization) else {
            return "話者不明"
        }
        return "話者\(best + 1)"
    }

    private func dominantSpeakerId(for segment: TranscriptionSegment, in diarization: DiarizationResult) -> Int? {
        var overlapBySpeaker: [Int: Float] = [:]
        for speakerSegment in diarization.segments {
            guard let speakerId = speakerSegment.speaker.speakerId else { continue }
            let overlapStart = max(segment.start, speakerSegment.startTime)
            let overlapEnd = min(segment.end, speakerSegment.endTime)
            let overlap = overlapEnd - overlapStart
            guard overlap > 0 else { continue }
            overlapBySpeaker[speakerId, default: 0] += overlap
        }
        return overlapBySpeaker.max(by: { $0.value < $1.value })?.key
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
