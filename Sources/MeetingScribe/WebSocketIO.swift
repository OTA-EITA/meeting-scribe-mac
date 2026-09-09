import Foundation
import Network

/// NWConnection 上で WebSocket のテキストフレームを送受信する薄いヘルパー。
/// サーバー側(TranscriptionServer)とクライアント側(TranscriptClient)の両方から使う。
enum WebSocketIO {
    static func send(_ text: String, on connection: NWConnection) {
        guard let data = text.data(using: .utf8) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    static func receiveLoop(on connection: NWConnection, onText: @escaping (String) -> Void, onClose: @escaping () -> Void) {
        connection.receiveMessage { data, context, _, error in
            if error != nil {
                onClose()
                return
            }
            if let data, let context,
               let metadata = context.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata {
                switch metadata.opcode {
                case .text:
                    if let text = String(data: data, encoding: .utf8) {
                        onText(text)
                    }
                case .close:
                    onClose()
                    return
                default:
                    break
                }
            }
            receiveLoop(on: connection, onText: onText, onClose: onClose)
        }
    }
}
