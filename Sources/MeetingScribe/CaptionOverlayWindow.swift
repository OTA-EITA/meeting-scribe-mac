import AppKit
import SwiftUI

/// 会議アプリの上に重ねて表示する、半透明・常に最前面のライブ字幕ウィンドウ。
/// タイトルバーなし・背景透過にして、フルスクリーンの会議アプリの上にも
/// 表示できるよう collectionBehavior を設定している。
final class CaptionOverlayWindow: NSWindow {
    init(client: TranscriptClient) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        hasShadow = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let hostingView = NSHostingView(rootView: CaptionOverlayView(client: client))
        // NSHostingView が SwiftUI コンテンツの理想サイズに合わせてウィンドウ自体を
        // 際限なく広げてしまう(字幕が伸び続ける)問題を避けるため、自動サイジングを止める。
        hostingView.sizingOptions = []
        contentView = hostingView

        if let screen = NSScreen.main {
            let x = screen.visibleFrame.midX - frame.width / 2
            let y = screen.visibleFrame.minY + 80
            setFrameOrigin(NSPoint(x: x, y: y))
        }
    }
}

struct CaptionOverlayView: View {
    @ObservedObject var client: TranscriptClient

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if client.confirmedText.isEmpty && client.unconfirmedText.isEmpty {
                        Text(client.isRecording ? "聞き取り中…" : "録音を開始すると字幕が表示されます")
                            .foregroundColor(.white.opacity(0.7))
                    } else {
                        if !client.confirmedText.isEmpty {
                            Text(client.confirmedText)
                                .foregroundColor(.white)
                        }
                        if !client.unconfirmedText.isEmpty {
                            // 今まさに話されている(未確定の)部分は太字にして
                            // ライブで文字起こしされている感じを出す。
                            Text(client.unconfirmedText)
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .id("bottom")
            }
            .onChange(of: client.confirmedText + client.unconfirmedText) { _, _ in
                withAnimation {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
        .font(.system(size: 20))
        .padding(16)
        .frame(width: 680, height: 168)
        .background(Color.black.opacity(client.overlayOpacity))
        .cornerRadius(14)
        .padding(20)
    }
}
