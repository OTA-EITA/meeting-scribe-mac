import Foundation

/// stdout の print() はTTY以外へリダイレクトするとブロックバッファされ、
/// プロセスが正常終了するまでファイルに書き出されないことがある。
/// デバッグ中はこちらを使い、標準エラーへ即座に書き込む。
func debugLog(_ message: String) {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
}
