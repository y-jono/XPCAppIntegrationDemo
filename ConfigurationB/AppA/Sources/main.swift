import Foundation

// AppA は listener を持たず、launchd 登録済み SharedService へ接続する。
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
        FileHandle.standardError.write(Data("[\(stamp)] [AppA] \(message)\n".utf8))
    }
}

final class CallbackService: NSObject, ClientCallbackProtocol {
    func callback(_ message: String, withReply reply: @escaping (String) -> Void) {
        Logger.log("受信 callback: \(message)")
        reply("AppA callback reply: \(message)")
    }
}

let args = Set(CommandLine.arguments.dropFirst())
let connection = NSXPCConnection(machServiceName: "com.example.shared.service", options: [])
connection.remoteObjectInterface = NSXPCInterface(with: SharedXPCProtocol.self)
if args.contains("--variant=one-connection") {
    connection.exportedInterface = NSXPCInterface(with: ClientCallbackProtocol.self)
    connection.exportedObject = CallbackService()
}
connection.interruptionHandler = { Logger.log("interruption service=com.example.shared.service") }
connection.invalidationHandler = { Logger.log("invalidation service=com.example.shared.service") }
connection.resume()

Logger.log("SharedService 呼び出し開始 variant=\(args.contains("--variant=one-connection") ? "one-connection" : "two-connection")")
let proxy = connection.synchronousRemoteObjectProxyWithErrorHandler { error in
    Logger.log("同期 proxy error: \(error.localizedDescription)")
} as? SharedXPCProtocol

guard let proxy else {
    Logger.log("proxy 生成失敗。LaunchAgent 登録、bootstrap domain、署名拒否を確認してください")
    exit(2)
}

proxy.ping("AppA", message: "hello") { reply in
    Logger.log("reply=\(reply)")
}
connection.invalidate()
