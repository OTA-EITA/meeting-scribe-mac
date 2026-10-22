import Foundation

/// ローカル WebSocket へ接続してよい相手を決める。
///
/// ブラウザの WebSocket には CORS の制限がかからず、開いているどのウェブサイトからも
/// ws://127.0.0.1 へ接続できてしまう。ブラウザは接続時に必ず Origin ヘッダーを
/// 付けるので、Origin を持つ接続は同梱の Chrome 拡張機能からのものだけを通す。
/// Origin を付けないアプリ内のクライアント(RawWebSocketClient)はそのまま通す。
enum OriginPolicy {
    /// chrome-extension/manifest.json の key から決まる拡張機能の ID
    static let chromeExtensionID = "pjkgdgbmgcoooolfkjjgkinidnccojhj"

    static func isAllowed(origin: String?) -> Bool {
        guard let origin else { return true }
        return origin == "chrome-extension://\(chromeExtensionID)"
    }

    static func origin(in headers: [(name: String, value: String)]) -> String? {
        headers.first { $0.name.caseInsensitiveCompare("Origin") == .orderedSame }?.value
    }
}
