import AppKit
import Foundation

/// メインウィンドウ・字幕オーバーレイ・メニューバーが共有するアプリ全体の状態。
/// メインウィンドウを閉じてもこのインスタンス自体は生き続けるため、
/// メニューバーからいつでも録音・オーバーレイの状態を確認/操作できる。
@MainActor
final class AppState: ObservableObject {
    let client = TranscriptClient()
    @Published private(set) var showOverlay = false
    private var overlayWindow: CaptionOverlayWindow?

    func toggleOverlay() {
        setOverlayVisible(!showOverlay)
    }

    func setOverlayVisible(_ visible: Bool) {
        showOverlay = visible
        if visible {
            let window = overlayWindow ?? CaptionOverlayWindow(client: client)
            overlayWindow = window
            window.orderFrontRegardless()
        } else {
            overlayWindow?.orderOut(nil)
        }
    }

    func toggleRecording() {
        if client.isRecording {
            client.stopRecording()
        } else {
            client.startRecording()
        }
    }
}
