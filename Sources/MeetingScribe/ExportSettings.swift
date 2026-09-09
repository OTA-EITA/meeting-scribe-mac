import Foundation

/// 議事録の自動書き出し先フォルダの設定。UserDefaults に保存し、
/// メインウィンドウ(UI)とエンジン(TranscriptionServer、同一プロセス内)の
/// 両方から参照する。
enum ExportSettings {
    private static let key = "exportFolderPath"

    static var folderURL: URL {
        get {
            if let path = UserDefaults.standard.string(forKey: key) {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            return defaultFolderURL
        }
        set {
            UserDefaults.standard.set(newValue.path, forKey: key)
        }
    }

    static var defaultFolderURL: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("MeetingScribe議事録", isDirectory: true)
    }
}
