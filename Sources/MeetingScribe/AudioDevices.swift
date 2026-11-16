import Foundation
import CoreAudio

/// Mac につながっている音声デバイス(マイク・スピーカー・イヤホンなど)
struct AudioDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
}

/// Core Audio から入力・出力のデバイスを引く
enum AudioDevices {
    static func inputs() -> [AudioDevice] { all().filter { channelCount($0.id, scope: kAudioObjectPropertyScopeInput) > 0 } }
    static func outputs() -> [AudioDevice] { all().filter { channelCount($0.id, scope: kAudioObjectPropertyScopeOutput) > 0 } }

    static func defaultInput() -> AudioDevice? { defaultDevice(kAudioHardwarePropertyDefaultInputDevice) }
    static func defaultOutput() -> AudioDevice? { defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) }

    /// UID からデバイスを探す。抜かれていれば nil
    static func device(uid: String) -> AudioDevice? {
        all().first { $0.uid == uid }
    }

    private static func all() -> [AudioDevice] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap(device(id:))
            // 相手の声を取るためにこのアプリが作る集約デバイスは選ばせない
            .filter { !$0.name.hasPrefix("MeetingScribe") }
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDevice? {
        var address = address(selector)
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr else { return nil }
        return device(id: id)
    }

    private static func device(id: AudioObjectID) -> AudioDevice? {
        guard let uid = string(id, kAudioDevicePropertyDeviceUID),
              let name = string(id, kAudioObjectPropertyName) else { return nil }
        return AudioDevice(id: id, uid: uid, name: name)
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func channelCount(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }
}

/// 録音に使うマイクと、相手の声を取る出力先の選択。UserDefaults に UID で保存する。
/// nil は「Mac の設定に従う」。選んだデバイスが抜かれていれば、Mac の設定に従う
enum AudioDeviceSettings {
    private static let inputKey = "inputDeviceUID"
    private static let outputKey = "outputDeviceUID"

    static var inputUID: String? {
        get { UserDefaults.standard.string(forKey: inputKey) }
        set { UserDefaults.standard.set(newValue, forKey: inputKey) }
    }

    static var outputUID: String? {
        get { UserDefaults.standard.string(forKey: outputKey) }
        set { UserDefaults.standard.set(newValue, forKey: outputKey) }
    }

    /// 録音に使うマイク。選んだものが無ければ Mac の既定
    static var input: AudioDevice? {
        inputUID.flatMap(AudioDevices.device(uid:)) ?? AudioDevices.defaultInput()
    }

    /// 相手の声を取る出力先。選んだものが無ければ Mac の既定
    static var output: AudioDevice? {
        outputUID.flatMap(AudioDevices.device(uid:)) ?? AudioDevices.defaultOutput()
    }

    /// 出力先を自分で選んでいて、そのデバイスがつながっているか
    static var hasChosenOutput: Bool {
        outputUID.flatMap(AudioDevices.device(uid:)) != nil
    }
}
