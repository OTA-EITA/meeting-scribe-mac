import Foundation
import Darwin

/// 生のBSDソケットで実装したWebSocketクライアント。
/// このマシンではFortiClientのVPN用NetworkExtensionがローカルループバックの
/// NWConnection通信を中断させてしまう(ECONNABORTED)ため、Network.framework
/// を経由しない実装にしている。サーバー側(NWListener)は問題なく動作するため
/// クライアント側のみをこの実装に置き換えている。
final class RawWebSocketClient {
    private var socketFD: Int32 = -1
    private let stateLock = NSLock()
    private var isRunning = false
    private let host: String
    private let port: UInt16

    var onText: ((String) -> Void)?
    var onClose: (() -> Void)?

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    /// 接続とハンドシェイクを行い、成功したらバックグラウンドスレッドで受信を開始する。
    func connect() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr(host)

        let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else {
            Darwin.close(fd)
            return false
        }
        socketFD = fd

        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let request = "GET / HTTP/1.1\r\nHost: \(host):\(port)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
        guard let requestData = request.data(using: .utf8), sendRaw(requestData) else {
            Darwin.close(fd)
            socketFD = -1
            return false
        }
        guard readHandshakeResponse() != nil else {
            Darwin.close(fd)
            socketFD = -1
            return false
        }

        stateLock.lock()
        isRunning = true
        stateLock.unlock()

        let thread = Thread { [weak self] in
            self?.readLoop()
        }
        thread.name = "RawWebSocketClient.readLoop"
        thread.start()
        return true
    }

    func send(text: String) {
        stateLock.lock()
        let running = isRunning
        stateLock.unlock()
        guard running, let payload = text.data(using: .utf8) else { return }

        var frame = Data()
        frame.append(0x81) // FIN + text opcode
        let length = payload.count
        let maskKey: [UInt8] = (0..<4).map { _ in UInt8.random(in: 0...255) }
        if length < 126 {
            frame.append(UInt8(0x80 | length))
        } else if length < 65536 {
            frame.append(0x80 | 126)
            frame.append(UInt8((length >> 8) & 0xFF))
            frame.append(UInt8(length & 0xFF))
        } else {
            frame.append(0x80 | 127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((length >> shift) & 0xFF))
            }
        }
        frame.append(contentsOf: maskKey)
        var maskedPayload = [UInt8](payload)
        for i in 0..<maskedPayload.count {
            maskedPayload[i] ^= maskKey[i % 4]
        }
        frame.append(contentsOf: maskedPayload)
        _ = sendRaw(frame)
    }

    func disconnect() {
        stateLock.lock()
        isRunning = false
        stateLock.unlock()
        if socketFD >= 0 {
            Darwin.close(socketFD)
            socketFD = -1
        }
    }

    private func sendRaw(_ data: Data) -> Bool {
        var totalSent = 0
        let ok: Bool = data.withUnsafeBytes { (rawBuf: UnsafeRawBufferPointer) in
            guard let base = rawBuf.bindMemory(to: UInt8.self).baseAddress else { return false }
            while totalSent < data.count {
                let n = Darwin.send(socketFD, base + totalSent, data.count - totalSent, 0)
                if n <= 0 { return false }
                totalSent += n
            }
            return true
        }
        return ok
    }

    private func readExact(_ count: Int) -> Data? {
        guard count > 0 else { return Data() }
        var buffer = Data()
        var remaining = count
        var tmp = [UInt8](repeating: 0, count: count)
        while remaining > 0 {
            let n = tmp.withUnsafeMutableBytes { ptr -> Int in
                Darwin.recv(socketFD, ptr.baseAddress, remaining, 0)
            }
            if n <= 0 { return nil }
            buffer.append(contentsOf: tmp[0..<n])
            remaining -= n
        }
        return buffer
    }

    private func readHandshakeResponse() -> String? {
        var responseBytes = [UInt8]()
        var byte: UInt8 = 0
        while true {
            let n = withUnsafeMutablePointer(to: &byte) { ptr -> Int in
                Darwin.recv(socketFD, ptr, 1, 0)
            }
            if n <= 0 { return nil }
            responseBytes.append(byte)
            if responseBytes.count >= 4, responseBytes.suffix(4).elementsEqual([13, 10, 13, 10]) {
                break
            }
            if responseBytes.count > 8192 { return nil }
        }
        return String(bytes: responseBytes, encoding: .utf8)
    }

    private func readLoop() {
        while true {
            stateLock.lock()
            let running = isRunning
            stateLock.unlock()
            guard running else { break }

            guard let header = readExact(2) else { break }
            let b2 = header[1]
            let opcode = header[0] & 0x0F
            let masked = (b2 & 0x80) != 0
            var length = Int(b2 & 0x7F)
            if length == 126 {
                guard let ext = readExact(2) else { break }
                length = Int(ext[0]) << 8 | Int(ext[1])
            } else if length == 127 {
                guard let ext = readExact(8) else { break }
                length = ext.reduce(0) { ($0 << 8) | Int($1) }
            }
            var maskKey: [UInt8] = []
            if masked {
                guard let m = readExact(4) else { break }
                maskKey = Array(m)
            }
            guard let payload = readExact(length) else { break }
            var bytes = Array(payload)
            if masked {
                for i in 0..<bytes.count {
                    bytes[i] ^= maskKey[i % 4]
                }
            }
            if opcode == 0x8 {
                break
            } else if opcode == 0x1, let text = String(bytes: bytes, encoding: .utf8) {
                onText?(text)
            }
        }
        stateLock.lock()
        isRunning = false
        stateLock.unlock()
        if socketFD >= 0 {
            Darwin.close(socketFD)
            socketFD = -1
        }
        onClose?()
    }
}
