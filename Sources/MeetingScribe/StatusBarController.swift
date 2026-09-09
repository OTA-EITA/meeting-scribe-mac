import AppKit
import Combine

/// メニューバー常駐アイコンとそのメニュー。メインウィンドウを閉じていても
/// ここから録音の開始/停止・字幕オーバーレイの表示切り替え・終了ができる。
@MainActor
final class StatusBarController {
    private let statusItem: NSStatusItem
    private let appState: AppState
    private weak var mainWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []

    init(appState: AppState, mainWindow: NSWindow) {
        self.appState = appState
        self.mainWindow = mainWindow
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "mic.circle", accessibilityDescription: "MeetingScribe")
        refreshMenu()

        appState.client.$isRecording
            .sink { [weak self] _ in self?.refreshMenu() }
            .store(in: &cancellables)
        appState.client.$isModelLoading
            .sink { [weak self] _ in self?.refreshMenu() }
            .store(in: &cancellables)
        appState.$showOverlay
            .sink { [weak self] _ in self?.refreshMenu() }
            .store(in: &cancellables)
    }

    private func refreshMenu() {
        let menu = NSMenu()

        let recordItem = NSMenuItem(
            title: appState.client.isRecording ? "停止する" : "録音を開始",
            action: #selector(toggleRecording),
            keyEquivalent: ""
        )
        recordItem.target = self
        recordItem.isEnabled = !appState.client.isModelLoading
        menu.addItem(recordItem)

        let overlayItem = NSMenuItem(
            title: appState.showOverlay ? "字幕オーバーレイを隠す" : "字幕オーバーレイを表示",
            action: #selector(toggleOverlay),
            keyEquivalent: ""
        )
        overlayItem.target = self
        menu.addItem(overlayItem)

        menu.addItem(.separator())

        let showWindowItem = NSMenuItem(title: "メインウィンドウを表示", action: #selector(showMainWindow), keyEquivalent: "")
        showWindowItem.target = self
        menu.addItem(showWindowItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "MeetingScribeを終了", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func toggleRecording() {
        appState.toggleRecording()
    }

    @objc private func toggleOverlay() {
        appState.toggleOverlay()
    }

    @objc private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
