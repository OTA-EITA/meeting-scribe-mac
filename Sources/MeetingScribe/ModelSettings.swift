import Foundation

/// 文字起こしに使う Whisper モデルの選択。UserDefaults に保存し、
/// メインウィンドウ(UI)とエンジン(TranscriptionServer、同一プロセス内)の
/// 両方から参照する。
enum WhisperModelOption: String, CaseIterable, Identifiable {
    case small
    case medium
    case largeV3Turbo = "large-v3-v20240930_turbo"

    var id: String { rawValue }

    /// WhisperKit に渡すモデル名。whisperkit-coreml リポジトリのフォルダ名の末尾と一致させる。
    var modelName: String { rawValue }

    var displayName: String {
        switch self {
        case .small: return "small (速い・約500MB)"
        case .medium: return "medium (高精度・約1.5GB)"
        case .largeV3Turbo: return "large-v3 turbo (最高精度・約1.6GB)"
        }
    }
}

enum ModelSettings {
    private static let key = "whisperModel"

    static var current: WhisperModelOption {
        get {
            UserDefaults.standard.string(forKey: key).flatMap(WhisperModelOption.init(rawValue:)) ?? .small
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
        }
    }
}
