import Foundation
import Security

// Objective-C 互換の protocol として公開し、NSXPCInterface に渡す。
@objc(XPCPingProtocol)
protocol XPCPingProtocol {
    func ping(_ message: String, withReply reply: @escaping (String) -> Void)
}

@objc(XPCCallbackProtocol)
protocol XPCCallbackProtocol {
    func callback(_ message: String, withReply reply: @escaping (String) -> Void)
}

final class Logger {
    static func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write(Data("[\(stamp)] [AppA] \(message)\n".utf8))
    }
}

final class PingService: NSObject, XPCPingProtocol {
    func ping(_ message: String, withReply reply: @escaping (String) -> Void) {
        Logger.log("受信 ping: \(message)")
        reply("AppA pong: \(message)")
    }
}

final class CallbackService: NSObject, XPCCallbackProtocol {
    func callback(_ message: String, withReply reply: @escaping (String) -> Void) {
        Logger.log("受信 callback: \(message)")
        reply("AppA callback reply: \(message)")
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        Logger.log("shouldAcceptNewConnection pid=\(connection.processIdentifier)")
        logCodeSignature(pid: connection.processIdentifier)
        connection.exportedInterface = NSXPCInterface(with: XPCPingProtocol.self)
        connection.exportedObject = PingService()
        connection.remoteObjectInterface = NSXPCInterface(with: XPCCallbackProtocol.self)
        connection.interruptionHandler = { Logger.log("受信接続 interruption pid=\(connection.processIdentifier)") }
        connection.invalidationHandler = { Logger.log("受信接続 invalidation pid=\(connection.processIdentifier)") }
        connection.resume()
        return true
    }

    private func logCodeSignature(pid: pid_t) {
        // Release 差分の観察用。実運用ではここで SecRequirement を評価して拒否理由を出す。
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

func makeConnection(to serviceName: String, exportCallback: Bool) -> NSXPCConnection {
    // one-connection では outbound 接続にも exportedObject を載せて callback を許可する。
    let connection = NSXPCConnection(machServiceName: serviceName, options: [])
    connection.remoteObjectInterface = NSXPCInterface(with: XPCPingProtocol.self)
    if exportCallback {
        connection.exportedInterface = NSXPCInterface(with: XPCCallbackProtocol.self)
        connection.exportedObject = CallbackService()
    }
    connection.interruptionHandler = { Logger.log("送信接続 interruption service=\(serviceName)") }
    connection.invalidationHandler = { Logger.log("送信接続 invalidation service=\(serviceName)") }
    connection.resume()
    return connection
}

func callPeer(serviceName: String, exportCallback: Bool) {
    Logger.log("peer lookup 開始 service=\(serviceName) exportCallback=\(exportCallback)")
    let connection = makeConnection(to: serviceName, exportCallback: exportCallback)
    let proxy = connection.synchronousRemoteObjectProxyWithErrorHandler { error in
        Logger.log("同期 proxy error: \(error.localizedDescription)")
    } as? XPCPingProtocol
    guard let proxy else {
        Logger.log("proxy 生成失敗。MachServices 未登録、bootstrap domain 違い、署名拒否を確認してください")
        return
    }
    proxy.ping("hello from AppA") { reply in
        Logger.log("reply=\(reply)")
    }
    connection.invalidate()
}

let args = Set(CommandLine.arguments.dropFirst())
let listener = NSXPCListener(machServiceName: "com.example.appA.service")
let delegate = ListenerDelegate()
listener.delegate = delegate
listener.resume()
Logger.log("listener started service=com.example.appA.service")

if args.contains("--call-peer") {
    callPeer(serviceName: "com.example.appB.service", exportCallback: args.contains("--variant=one-connection"))
}

if args.contains("--listen-only") || !args.contains("--exit") {
    RunLoop.current.run()
}
