import Foundation
import Security

// SharedService が単一 vendor になり、AppA/AppB は client として接続する。
@objc(SharedXPCProtocol)
protocol SharedXPCProtocol {
    func ping(_ clientName: String, message: String, withReply reply: @escaping (String) -> Void)
}

@objc(ClientCallbackProtocol)
protocol ClientCallbackProtocol {
    func callback(_ message: String, withReply reply: @escaping (String) -> Void)
}

final class Logger {
    static func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write(Data("[\(stamp)] [SharedService] \(message)\n".utf8))
    }
}

final class SharedService: NSObject, SharedXPCProtocol {
    func ping(_ clientName: String, message: String, withReply reply: @escaping (String) -> Void) {
        Logger.log("受信 ping client=\(clientName) message=\(message)")
        reply("SharedService pong to \(clientName): \(message)")
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        Logger.log("shouldAcceptNewConnection pid=\(connection.processIdentifier)")
        logCodeSignature(pid: connection.processIdentifier)
        connection.exportedInterface = NSXPCInterface(with: SharedXPCProtocol.self)
        connection.exportedObject = SharedService()
        connection.remoteObjectInterface = NSXPCInterface(with: ClientCallbackProtocol.self)
        connection.interruptionHandler = { Logger.log("接続 interruption pid=\(connection.processIdentifier)") }
        connection.invalidationHandler = { Logger.log("接続 invalidation pid=\(connection.processIdentifier)") }
        connection.resume()
        return true
    }

    private func logCodeSignature(pid: pid_t) {
        // Release 差分の観察用。実運用では Team ID や bundle id の requirement を評価する。
        let attributes = [kSecGuestAttributePid: pid] as CFDictionary
        var code: SecCode?
        let status = SecCodeCopyGuestWithAttributes(nil, attributes, [], &code)
        guard status == errSecSuccess, let code else {
            Logger.log("署名検査: SecCodeCopyGuestWithAttributes 失敗 status=\(status)")
            return
        }
        let validityStatus = SecCodeCheckValidity(code, [], nil)
        Logger.log("署名検査: SecCodeCheckValidity status=\(validityStatus)")
    }
}

let listener = NSXPCListener(machServiceName: "com.example.shared.service")
let delegate = ListenerDelegate()
listener.delegate = delegate
listener.resume()
Logger.log("listener started service=com.example.shared.service")
RunLoop.current.run()
