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

    static let systemAudioWarning = "システム音声を取れていません。相手の声は文字起こしされません。システム設定の「画面とシステムオーディオの収録」で MeetingScribe を許可し、アプリを起動し直してください。"

    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var whisperKit: WhisperKit?
    private var speakerKit: SpeakerKit?
    private var audioStreamTranscriber: AudioStreamTranscriber?
    private var latestTranscriberState: AudioStreamTranscriber.State?
    private var isRecording = false
    private var modelReady = false
    private var isLoadingModel = false
    private var modelLoadError: String?

    /// 録音中に定期的に更新される話者分離結果。確定していればライブ配信にも
    /// 話者ラベルを反映する(停止後の最終結果はこれとは別に全体を再解析する)。
    /// これは「相手」側で複数人を区別するためだけに使い、自分か相手かの
    /// 一次判定はマイク/システム音声のどちらが優勢だったかで確実に行う
    /// (MixedAudioProcessor.dominantSource)。
    /// (internal: 単体テストから直接設定できるようにするため private にしていない)
    var latestDiarization: DiarizationResult?
    private var diarizationTask: Task<Void, Never>?

    /// pyannote の話者IDを「相手1」「相手2」…という表示用の番号に固定するための
    /// マッピング。セッション(録音)ごとにリセットする。
    private var otherSpeakerNumbering: [Int: Int] = [:]

    /// 同じ話者の発話が続く場合でも、これ以上の無音が空いたら改行する。
    private let pauseBreakThreshold: Float = 1.5

    func start() {
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        // ブラウザで開いた任意のサイトからの接続を、ハンドシェイクの時点で断る。
        wsOptions.setClientRequestHandler(.main) { _, headers in
            let origin = OriginPolicy.origin(in: headers)
            let allowed = OriginPolicy.isAllowed(origin: origin)
            if !allowed {
                print("TranscriptionServer: 許可していない接続元を拒否しました: \(origin ?? "")")
            }
            return NWProtocolWebSocket.Response(status: allowed ? .accept : .reject, subprotocol: nil)
        }
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
        parameters.allowLocalEndpointReuse = true
        // 文字起こし結果と録音の操作を同じ端末の外へ出さないよう、ループバックだけで待ち受ける。
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)

        do {
            let listener = try NWListener(using: parameters)
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
        // start(queue: .main) なので状態の通知はメインスレッドで届く。
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                self?.connection(connection, didChangeTo: state)
            }
        }
        connection.start(queue: .main)
    }

    /// 受信ループを始めた接続。.ready が二度届いても受信ループを重ねて始めないようにする。
    private var receivingConnections: Set<ObjectIdentifier> = []

    private func connection(_ connection: NWConnection, didChangeTo state: NWConnection.State) {
        let id = ObjectIdentifier(connection)
        switch state {
        case .ready:
            guard receivingConnections.insert(id).inserted else { return }
            WebSocketIO.receiveLoop(on: connection) { [weak self] text in
                Task { @MainActor in self?.handleIncoming(text) }
            } onClose: { [weak self] in
                Task { @MainActor in
                    connection.cancel()
                    self?.forget(connection)
                }
            }
            sendCurrentStatus(to: connection)
        case .failed, .cancelled:
            forget(connection)
        default:
            break
        }
    }

    private func forget(_ connection: NWConnection) {
        connections.removeAll { $0 === connection }
        receivingConnections.remove(ObjectIdentifier(connection))
    }

    private func handleIncoming(_ text: String) {
        guard let data = text.data(using: .utf8),
              let message = try? JSONDecoder().decode(TranscriptMessage.self, from: data),
              message.type == "control" else { return }
        switch message.action {
        case "start": startRecording()
        case "stop": stopRecording()
        case "reloadModel": reloadModel()
        default: break
        }
    }

    /// ModelSettings で選び直したモデルに差し替える。録音中と読み込み中は受け付けない。
    private func reloadModel() {
        guard !isRecording, !isLoadingModel else { return }
        whisperKit = nil
        modelReady = false
        modelLoadError = nil
        Task {
            await loadModel()
        }
    }

    private func loadModel() async {
        isLoadingModel = true
        defer { isLoadingModel = false }
        broadcast(TranscriptMessage(type: "status", status: "modelLoading"))
        do {
            // 既定は "small"。"base" は日本語の認識精度が低く、繰り返しや幻聴的な
            // 誤認識が目立ったため使わない。より高精度なモデルは画面から選べる。
            // audioProcessor は MixedAudioProcessor に差し替え、マイクだけでなく
            // システム出力音声(Meet相手の声など)も合成して文字起こし対象にする。
            let model = ModelSettings.current.modelName
            let pipe = try await WhisperKit(model: model, audioProcessor: MixedAudioProcessor(), load: true)
            whisperKit = pipe
            modelReady = true
            broadcast(TranscriptMessage(type: "status", status: "ready"))
        } catch {
            modelLoadError = error.localizedDescription
            broadcast(TranscriptMessage(type: "error", message: "モデルの読み込みに失敗しました: \(error.localizedDescription)"))
        }

        // 話者分離モデルはベストエフォート。読み込みに失敗しても文字起こし自体は
        // 続行できるようにし、その場合は話者ラベル無しのテキストにフォールバックする。
        // 文字起こしモデルを差し替えても話者分離モデルは使い回す。
        guard speakerKit == nil else { return }
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
        (whisperKit.audioProcessor as? MixedAudioProcessor)?.onSystemAudioFailure = { [weak self] _ in
            Task { @MainActor in
                self?.broadcast(TranscriptMessage(type: "warning", message: Self.systemAudioWarning))
            }
        }
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
                let unconfirmed = HallucinationFilter.filter(newState.unconfirmedSegments).map { $0.text }.joined()
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
    /// 録音が長くなるほど1回あたりの処理時間は伸びるので、間隔は
    /// DiarizationSchedule で前回の処理時間に応じて広げる。
    /// 話者分離モデルは文字起こしモデルより後に読み込み終わるので、録音開始の時点では
    /// まだ無いことがある。開始時には確かめず、やり直すたびに有無を見る。
    private func startPeriodicDiarization() {
        diarizationTask = Task { [weak self] in
            var delay = DiarizationSchedule.minimumDelay
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, self.isRecording,
                      let whisperKit = self.whisperKit, let speakerKit = self.speakerKit else { continue }
                let snapshot = Array(whisperKit.audioProcessor.audioSamples)
                guard snapshot.count > 16_000 else { continue } // 1秒未満はスキップ
                let started = ContinuousClock.now
                if let result = try? await speakerKit.diarize(audioArray: snapshot) {
                    self.latestDiarization = result
                }
                let elapsed = started.duration(to: .now)
                let runSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                delay = DiarizationSchedule.delay(afterRunTaking: runSeconds)
                debugLog("TranscriptionServer: 話者分離 \(snapshot.count / 16_000)秒分に\(String(format: "%.2f", runSeconds))秒。次は\(String(format: "%.1f", delay))秒後")
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
        let finalText = labelSegmentsHybrid(allSegments, timestamps: true)

        broadcast(TranscriptMessage(type: "transcript", confirmedText: finalText, unconfirmedText: ""))
        let exportedURL = exportTranscript(finalText)
        // 保存先を UI に伝え、相手の名前を付け替えたときに同じファイルを書き直せるようにする。
        broadcast(TranscriptMessage(type: "status", status: "stopped", message: exportedURL?.path))
    }

    /// 録音セッションの最終テキストを、設定された保存先フォルダへ議事録として自動書き出しする。
    /// 設定に応じて同じ名前の Markdown も書き出す。書き出した .txt の場所を返す。
    private func exportTranscript(_ text: String) -> URL? {
        guard !text.isEmpty else { return nil }
        let folder = ExportSettings.folderURL
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let fileURL = folder.appendingPathComponent("議事録_\(formatter.string(from: Date())).txt")
            try TranscriptFiles.write(text, to: fileURL)
            return fileURL
        } catch {
            print("TranscriptionServer: 議事録の自動書き出しに失敗しました: \(error)")
            return nil
        }
    }

    /// マイク/システム音声のどちらが優勢だったかで「自分」「相手」を確実に判定し、
    /// 「相手」側だけ話者分離で相手1・相手2…と区別する。音源の判定材料が無い
    /// (MixedAudioProcessor 以外を使っている等)場合は、話者分離のみによる
    /// 従来のラベル付けにフォールバックする。幻聴のセグメントは先に取り除く。
    /// timestamps が true なら、各行の頭に録音開始からの経過時間 [hh:mm:ss] を付ける。
    func labelSegmentsHybrid(_ segments: [TranscriptionSegment], timestamps: Bool = false) -> String {
        let segments = HallucinationFilter.filter(segments)
        guard !segments.isEmpty else { return "" }
        let mixedProcessor = whisperKit?.audioProcessor as? MixedAudioProcessor

        var result = ""
        var previousEnd: Float?
        var previousLabel: String?
        for segment in segments {
            let label = hybridLabel(for: segment, mixedProcessor: mixedProcessor)
            let gap = previousEnd.map { segment.start - $0 } ?? .infinity
            let timestamp = timestamps ? "[\(TranscriptFormatter.elapsed(segment.start))] " : ""
            if label != previousLabel {
                result += result.isEmpty ? "" : "\n"
                result += "\(timestamp)[\(label)] "
            } else if gap > pauseBreakThreshold {
                result += "\n\(timestamp)"
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
