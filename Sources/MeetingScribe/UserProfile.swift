import Foundation

/// 「自分」ラベルの代わりに表示するユーザー自身の名前。設定していなければ
/// 従来通り「自分」と表示する。AIやモデルを使わない、単純な文字列置き換え。
enum UserProfile {
    private static let key = "userDisplayName"

    static var displayName: String {
        get { UserDefaults.standard.string(forKey: key) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// 文字起こし結果に表示するラベル。名前が未設定なら「自分」。
    static var selfLabel: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "自分" : trimmed
    }
}
