import Foundation
import CoreAudio
import AVFoundation

/// システムの出力音声(会議の相手の声を含む)を Core Audio のプロセスタップで取る。
///
/// ScreenCaptureKit は「画面とシステムオーディオの収録」の許可が要り、macOS 15 以降は
/// その許可を定期的に確かめ直してくる。プロセスタップは「システムオーディオ録音のみ」の
/// 許可で済み、一度許可すれば聞き直されない。音はイヤホンへ送られる前に取るので、
/// イヤホンをしていても相手の声が入る。
@available(macOS 14.2, *)
final class ProcessTapAudioCapture: SystemAudioSource {
    var onSamples: (([Float]) -> Void)?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "ProcessTapAudioCapture.audio")
    // 音声の受け取りは queue で動くので、開始・停止は別のロックで順番を守る。
    // 同じ queue で AudioDeviceStop を待つと、受け取り中の処理と待ち合って止まる
    private let controlLock = NSLock()
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    func start() async throws {
        try controlLock.withLock { try startTap() }
    }

    func stop() async {
        controlLock.withLock { stopTap() }
    }

    private func startTap() throws {
        guard ioProcID == nil else { return }

        // 自分の出す音は取らない(ScreenCaptureKit の excludesCurrentProcessAudio と同じ)
        let excluded = Self.ownProcessObject().map { [$0] } ?? []
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.uuid = UUID()
        description.name = "MeetingScribe"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        // 出力先を選んでいれば、そのデバイスへ送られる音だけを取る
        let output = AudioDeviceSettings.output
        if AudioDeviceSettings.hasChosenOutput, let output {
            description.deviceUID = output.uid
        }

        try check(AudioHardwareCreateProcessTap(description, &tapID), "プロセスタップを作れませんでした")

        do {
            var format = try Self.property(tapID, kAudioTapPropertyFormat, as: AudioStreamBasicDescription())
            guard let tapFormat = AVAudioFormat(streamDescription: &format),
                  let converter = AVAudioConverter(from: tapFormat, to: targetFormat) else {
                throw Self.error("タップの音声形式を扱えませんでした")
            }

            // タップは集約デバイスに組み込んで読む。主デバイスには出力先を使う
            guard let outputUID = output?.uid else { throw Self.error("出力先のデバイスが見つかりませんでした") }
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "MeetingScribe Tap",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                ]],
            ]
            try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "集約デバイスを作れませんでした")

            try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { [weak self] _, inputData, _, _, _ in
                self?.receive(inputData, format: tapFormat, converter: converter)
            }, "音声の受け取りを始められませんでした")
            try check(AudioDeviceStart(aggregateID, ioProcID), "音声の受け取りを始められませんでした")
        } catch {
            stopTap()
            throw error
        }
    }

    private func stopTap() {
        if aggregateID != kAudioObjectUnknown, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func receive(_ inputData: UnsafePointer<AudioBufferList>, format: AVAudioFormat, converter: AVAudioConverter) {
        guard let input = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData, deallocator: nil),
              input.frameLength > 0 else { return }
        let capacity = AVAudioFrameCount(targetFormat.sampleRate * Double(input.frameLength) / format.sampleRate) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, let channel = output.floatChannelData else { return }
        onSamples?(Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength))))
    }

    // MARK: - Core Audio の小道具

    private static func ownProcessObject() -> AudioObjectID? {
        var pid = ProcessInfo.processInfo.processIdentifier
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    private static func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, as initial: T) throws -> T {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { throw error("音声デバイスの情報を読めませんでした (\(status))") }
        return value
    }

    private func check(_ status: OSStatus, _ message: String) throws {
        guard status == noErr else { throw Self.error("\(message) (\(status))") }
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "ProcessTapAudioCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
