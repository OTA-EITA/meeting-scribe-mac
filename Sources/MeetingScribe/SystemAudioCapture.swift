import Foundation
import ScreenCaptureKit
import AVFoundation

/// macOSの「画面収録」権限を使って、システムの出力音声(Google Meet等の
/// 相手の声を含む、スピーカー/イヤホンに送られる音声)をキャプチャする。
/// Bluetooth/有線イヤホン使用時はマイクだけでは相手の声を拾えないため、
/// マイク入力と合成して文字起こしできるようにするために用意した。
@available(macOS 13.0, *)
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    var onSamples: (([Float]) -> Void)?

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw NSError(domain: "SystemAudioCapture", code: 1,
                           userInfo: [NSLocalizedDescriptionKey: "画面収録可能なディスプレイが見つかりませんでした"])
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 16_000
        config.channelCount = 1
        config.excludesCurrentProcessAudio = true
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "SystemAudioCapture.audio"))
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        self.stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        guard let samples = Self.floatSamples(from: sampleBuffer) else { return }
        onSamples?(samples)
    }

    private static func floatSamples(from sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let formatDescription = sampleBuffer.formatDescription,
              let asbd = formatDescription.audioStreamBasicDescription else { return nil }

        var blockBuffer: CMBlockBuffer?
        var audioBufferList = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let mData = audioBufferList.mBuffers.mData else { return nil }

        let byteCount = Int(audioBufferList.mBuffers.mDataByteSize)
        if asbd.mFormatID == kAudioFormatLinearPCM, asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            let count = byteCount / MemoryLayout<Float>.size
            let pointer = mData.bindMemory(to: Float.self, capacity: count)
            return Array(UnsafeBufferPointer(start: pointer, count: count))
        } else if asbd.mFormatID == kAudioFormatLinearPCM, asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0 {
            let count = byteCount / MemoryLayout<Int16>.size
            let pointer = mData.bindMemory(to: Int16.self, capacity: count)
            return UnsafeBufferPointer(start: pointer, count: count).map { Float($0) / Float(Int16.max) }
        }
        return nil
    }
}
