import Foundation
import AVFoundation
import CoreML
import WhisperKit

/// マイク入力に加えて、システムの出力音声(Google Meet等、イヤホン使用時でも
/// マイクには入らない相手の声)も合成してから文字起こしパイプラインに渡す
/// `AudioProcessing` 実装。
///
/// `AudioProcessor.startRecordingLive` 等は extension で定義されており継承では
/// 差し替えられないため、プロトコルを直接実装している。エネルギー計算(VAD用)は
/// `AudioProcessor` が公開している static ヘルパーをそのまま再利用する。
final class MixedAudioProcessor: NSObject, AudioProcessing {
    // MARK: - AudioProcessing (プロトコル要件の委譲。独自の録音経路では未使用)

    static func loadAudio(fromPath audioFilePath: String, channelMode: ChannelMode, startTime: Double?, endTime: Double?, maxReadFrameSize: AVAudioFrameCount?) throws -> AVAudioPCMBuffer {
        try AudioProcessor.loadAudio(fromPath: audioFilePath, channelMode: channelMode, startTime: startTime, endTime: endTime, maxReadFrameSize: maxReadFrameSize)
    }

    static func loadAudio(at audioPaths: [String], channelMode: ChannelMode) async -> [Result<[Float], Swift.Error>] {
        await AudioProcessor.loadAudio(at: audioPaths, channelMode: channelMode)
    }

    static func padOrTrimAudio(fromArray audioArray: [Float], startAt startIndex: Int, toLength frameLength: Int, saveSegment: Bool) -> MLMultiArray? {
        AudioProcessor.padOrTrimAudio(fromArray: audioArray, startAt: startIndex, toLength: frameLength, saveSegment: saveSegment)
    }

    func padOrTrim(fromArray audioArray: [Float], startAt startIndex: Int, toLength frameLength: Int) -> (any AudioProcessorOutputType)? {
        AudioProcessor.padOrTrimAudio(fromArray: audioArray, startAt: startIndex, toLength: frameLength, saveSegment: false)
    }

    // MARK: - State

    private(set) var audioSamples: ContiguousArray<Float> = []
    private var audioEnergy: [(rel: Float, avg: Float, max: Float, min: Float)] = []
    var relativeEnergyWindow: Int = 20
    var relativeEnergy: [Float] { audioEnergy.map { $0.rel } }
    private var audioBufferCallback: (([Float]) -> Void)?

    private let micEngine = AVAudioEngine()
    private let systemAudio: Any?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    private let bufferLock = NSLock()
    private var micBuffer: [Float] = []
    private var systemBuffer: [Float] = []
    private var mixTimer: DispatchSourceTimer?

    /// マイク/システム音声それぞれの時間帯ごとのエネルギーを記録しておき、
    /// 文字起こしセグメントが「自分(マイク)」か「相手(システム音声)」かを
    /// 声質の推定ではなく音源そのもので判定できるようにする。
    private var sourceEnergyTimeline: [(startTime: Float, endTime: Float, mic: Float, system: Float)] = []
    private var cumulativeSampleCount: Int = 0

    /// システム音声のキャプチャを開始できなかったときに呼ぶ。マイクだけで続けると
    /// 相手の声が丸ごと抜けるので、エンジンから画面へ知らせるために使う。
    var onSystemAudioFailure: ((Error) -> Void)?

    override init() {
        if #available(macOS 13.0, *) {
            systemAudio = SystemAudioCapture()
        } else {
            systemAudio = nil
        }
        super.init()
    }

    func purgeAudioSamples(keepingLast keep: Int) {
        if audioSamples.count > keep {
            audioSamples.removeFirst(audioSamples.count - keep)
        }
    }

    func startRecordingLive(inputDeviceID: DeviceID?, callback: (([Float]) -> Void)?) throws {
        audioSamples = []
        audioEnergy = []
        audioBufferCallback = callback
        micBuffer = []
        systemBuffer = []
        sourceEnergyTimeline = []
        cumulativeSampleCount = 0

        try startMic()
        startSystemAudio()
        startMixTimer()
    }

    /// 指定した時間範囲([start, end) 秒)で、マイクとシステム音声のどちらが
    /// より優勢だったかを返す。true ならマイク(自分)、false ならシステム音声
    /// (相手)。該当するデータが無ければ nil。
    func dominantSource(fromTime start: Float, toTime end: Float) -> Bool? {
        var micTotal: Float = 0
        var systemTotal: Float = 0
        var found = false
        for entry in sourceEnergyTimeline {
            guard entry.endTime > start, entry.startTime < end else { continue }
            micTotal += entry.mic
            systemTotal += entry.system
            found = true
        }
        guard found else { return nil }
        return micTotal >= systemTotal
    }

    func startStreamingRecordingLive(inputDeviceID: DeviceID?) -> (AsyncThrowingStream<[Float], Error>, AsyncThrowingStream<[Float], Error>.Continuation) {
        let (stream, continuation) = AsyncThrowingStream<[Float], Error>.makeStream(bufferingPolicy: .unbounded)
        continuation.onTermination = { [weak self] _ in
            self?.audioBufferCallback = nil
            self?.stopRecording()
        }
        do {
            try startRecordingLive(inputDeviceID: inputDeviceID) { floats in
                continuation.yield(floats)
            }
        } catch {
            continuation.finish(throwing: error)
        }
        return (stream, continuation)
    }

    func pauseRecording() {
        micEngine.pause()
    }

    func stopRecording() {
        stopMixTimer()
        micEngine.stop()
        micEngine.inputNode.removeTap(onBus: 0)
        if #available(macOS 13.0, *), let capture = systemAudio as? SystemAudioCapture {
            Task { await capture.stop() }
        }
    }

    func resumeRecordingLive(inputDeviceID: DeviceID?, callback: (([Float]) -> Void)?) throws {
        if let callback {
            audioBufferCallback = callback
        }
        try micEngine.start()
        startSystemAudio()
        startMixTimer()
    }

    // MARK: - Mic capture

    private func startMic() throws {
        let input = micEngine.inputNode
        // start/stop が短時間に連続すると、前回のタップが残ったまま次の
        // installTap が呼ばれてクラッシュする('nullptr == Tap()')ことがあるため、
        // 念のため必ず一度外してから付け直す。
        input.removeTap(onBus: 0)
        let inputFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw NSError(domain: "MixedAudioProcessor", code: 1,
                           userInfo: [NSLocalizedDescriptionKey: "オーディオコンバータを作成できませんでした"])
        }

        input.installTap(onBus: 0, bufferSize: 1600, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let outCapacity = AVAudioFrameCount(self.targetFormat.sampleRate * Double(buffer.frameLength) / inputFormat.sampleRate) + 16
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: self.targetFormat, frameCapacity: outCapacity) else { return }
            var error: NSError?
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            converter.convert(to: outBuffer, error: &error, withInputFrom: inputBlock)
            guard error == nil, let channelData = outBuffer.floatChannelData else { return }
            let frameLength = Int(outBuffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
            self.bufferLock.lock()
            self.micBuffer.append(contentsOf: samples)
            self.bufferLock.unlock()
        }

        micEngine.prepare()
        try micEngine.start()
    }

    // MARK: - System audio capture

    private func startSystemAudio() {
        guard #available(macOS 13.0, *), let capture = systemAudio as? SystemAudioCapture else { return }
        capture.onSamples = { [weak self] samples in
            guard let self else { return }
            self.bufferLock.lock()
            self.systemBuffer.append(contentsOf: samples)
            self.bufferLock.unlock()
        }
        Task {
            do {
                try await capture.start()
            } catch {
                // 画面収録権限が無い、または失敗した場合はマイクのみで続行する。
                debugLog("MixedAudioProcessor: システム音声キャプチャを開始できませんでした。マイクのみで続行します: \(error)")
                onSystemAudioFailure?(error)
            }
        }
    }

    // MARK: - Mixing

    private func startMixTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [weak self] in
            self?.mixAndFlush()
        }
        timer.resume()
        mixTimer = timer
    }

    private func stopMixTimer() {
        mixTimer?.cancel()
        mixTimer = nil
    }

    /// マイクとシステム音声、それぞれこの100msの間に貯まったサンプルを単純加算で
    /// 合成し、`processBuffer` 相当の処理(追加・VAD用エネルギー計算・コールバック)を行う。
    /// どちらか一方しか無い(相手が話していない/システム音声が使えない)場合もそのまま流す。
    private func mixAndFlush() {
        bufferLock.lock()
        let mic = micBuffer
        let system = systemBuffer
        micBuffer.removeAll()
        systemBuffer.removeAll()
        bufferLock.unlock()

        guard !mic.isEmpty || !system.isEmpty else { return }

        let count = max(mic.count, system.count)
        var mixed = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let micSample = i < mic.count ? mic[i] : 0
            let systemSample = i < system.count ? system[i] : 0
            mixed[i] = max(-1, min(1, micSample + systemSample))
        }

        let startTime = Float(cumulativeSampleCount) / Float(targetFormat.sampleRate)
        cumulativeSampleCount += count
        let endTime = Float(cumulativeSampleCount) / Float(targetFormat.sampleRate)
        let micEnergy = mic.isEmpty ? 0 : AudioProcessor.calculateAverageEnergy(of: mic)
        let systemEnergy = system.isEmpty ? 0 : AudioProcessor.calculateAverageEnergy(of: system)
        sourceEnergyTimeline.append((startTime, endTime, micEnergy, systemEnergy))

        processBuffer(mixed)
    }

    /// `AudioProcessor.processBuffer(_:)` と同じロジック(サンプル追加・エネルギー計算・
    /// コールバック呼び出し)を、公開されている static ヘルパーで再現している。
    private func processBuffer(_ buffer: [Float]) {
        audioSamples.append(contentsOf: buffer)

        let minAvgEnergy = audioEnergy.suffix(20).reduce(Float.infinity) { min($0, $1.avg) }
        let relative = AudioProcessor.calculateRelativeEnergy(of: buffer, relativeTo: minAvgEnergy)
        let signalEnergy = AudioProcessor.calculateEnergy(of: buffer)
        audioEnergy.append((relative, signalEnergy.avg, signalEnergy.max, signalEnergy.min))

        audioBufferCallback?(buffer)
    }
}
