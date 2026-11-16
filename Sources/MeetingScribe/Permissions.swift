import Foundation
import AVFoundation

/// マイクとシステム音声の許可を、インストールして最初に起動したときにまとめて求める。
/// 録音を始めた瞬間に許可のダイアログが出ると、会議の冒頭が録れないため。
/// 一度許可すれば macOS が覚えているので、以後の起動では何も聞かない。
enum Permissions {
    private static let systemAudioAskedKey = "systemAudioPermissionAsked"

    @MainActor
    static func requestOnFirstLaunch() async {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }

        // システム音声の許可には、状態を調べる公開の API が無い。
        // タップを一度動かすと macOS がダイアログを出すので、初回だけ短く動かして止める
        guard !UserDefaults.standard.bool(forKey: systemAudioAskedKey) else { return }
        guard #available(macOS 14.2, *) else { return }
        let capture = ProcessTapAudioCapture()
        do {
            try await capture.start()
            try? await Task.sleep(for: .seconds(1))
            await capture.stop()
            UserDefaults.standard.set(true, forKey: systemAudioAskedKey)
        } catch {
            debugLog("Permissions: システム音声の許可を求められませんでした: \(error)")
        }
    }
}
