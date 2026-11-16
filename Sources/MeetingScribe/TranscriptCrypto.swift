import Foundation
import CryptoKit

/// 議事録を AES-GCM で暗号化する。ファイルの先頭に目印を置き、平文の議事録と見分ける。
/// 改ざんされたファイルや別の鍵で暗号化したファイルは open で失敗する。
enum TranscriptCrypto {
    enum Failure: Error {
        case notSealed
        case notUTF8
    }

    private static let magic = Data("MSCRIBE1".utf8)

    static func seal(_ text: String, using key: SymmetricKey) throws -> Data {
        let box = try AES.GCM.seal(Data(text.utf8), using: key)
        guard let combined = box.combined else { throw Failure.notSealed }
        return magic + combined
    }

    static func isSealed(_ data: Data) -> Bool {
        data.starts(with: magic)
    }

    static func open(_ data: Data, using key: SymmetricKey) throws -> String {
        guard isSealed(data) else { throw Failure.notSealed }
        let box = try AES.GCM.SealedBox(combined: Data(data.dropFirst(magic.count)))
        let plain = try AES.GCM.open(box, using: key)
        guard let text = String(data: plain, encoding: .utf8) else { throw Failure.notUTF8 }
        return text
    }
}
