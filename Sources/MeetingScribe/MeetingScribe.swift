import SwiftUI
import AppKit

/// メインウィンドウを閉じてもアプリを終了させない(メニューバー常駐アプリとして
/// 動作させるため)。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct MeetingScribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private static let engine = TranscriptionServer()
    private static let appState = AppState()
    private static var mainWindow: NSWindow?
    private static var statusBarController: StatusBarController?

    init() {
        // SPM 実行ファイルには .app バンドルが無く、既定では Dock/Cmd+Tab に
        // 現れないバックグラウンド扱いになるため、明示的に通常アプリとして
        // 前面に出す。
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)

        Task { @MainActor in
            Self.engine.start()
            Self.appState.client.connect()
        }

        // メインウィンドウは SwiftUI の WindowGroup ではなく手動で保持する。
        // ウィンドウを閉じてもインスタンスを破棄せず(isReleasedWhenClosed = false)、
        // メニューバーからいつでも再表示できるようにするため。
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MeetingScribe"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentView(appState: Self.appState))
        window.center()
        window.makeKeyAndOrderFront(nil)
        Self.mainWindow = window

        Self.statusBarController = StatusBarController(appState: Self.appState, mainWindow: window)
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
