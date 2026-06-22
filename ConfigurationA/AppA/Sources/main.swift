import Foundation
import AppKit
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
        guard validateCodeSignature(pid: connection.processIdentifier) else {
            Logger.log("requirement 不一致で拒否 pid=\(connection.processIdentifier)")
            return false
        }
        connection.exportedInterface = NSXPCInterface(with: XPCPingProtocol.self)
        connection.exportedObject = PingService()
        connection.remoteObjectInterface = NSXPCInterface(with: XPCCallbackProtocol.self)
        connection.interruptionHandler = { Logger.log("受信接続 interruption pid=\(connection.processIdentifier)") }
        connection.invalidationHandler = { Logger.log("受信接続 invalidation pid=\(connection.processIdentifier)") }
        connection.resume()
        return true
    }

    private func validateCodeSignature(pid: pid_t) -> Bool {
        #if DEBUG
        Logger.log("署名検査: DEBUG ビルドのため requirement チェックをスキップ")
        return true
        #else
        // Release 差分の観察用。実運用ではここで SecRequirement を評価して拒否理由を出す。
        let attributes = [kSecGuestAttributePid: pid] as CFDictionary
        var code: SecCode?
        let status = SecCodeCopyGuestWithAttributes(nil, attributes, [], &code)
        guard status == errSecSuccess, let code else {
            Logger.log("署名検査: SecCodeCopyGuestWithAttributes 失敗 status=\(status)")
            return false
        }
        let validityStatus = SecCodeCheckValidity(code, [], nil)
        Logger.log("署名検査: SecCodeCheckValidity status=\(validityStatus)")

        let requirementText = selectedRequirementText()
        var requirement: SecRequirement?
        let requirementStatus = SecRequirementCreateWithString(requirementText as CFString, [], &requirement)
        guard requirementStatus == errSecSuccess, let requirement else {
            Logger.log("署名検査: SecRequirementCreateWithString 失敗 status=\(requirementStatus) requirement=\(requirementText)")
            return false
        }
        let checkStatus = SecCodeCheckValidity(code, [], requirement)
        Logger.log("署名検査: requirement='\(requirementText)' status=\(checkStatus)")
        return checkStatus == errSecSuccess
        #endif
    }

    private func selectedRequirementText() -> String {
        #if USE_CORRECT_REQUIREMENT
        return #"anchor apple generic and certificate leaf[subject.OU] = "6WFKUJRXCU""#
        #else
        return #"anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"#
        #endif
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let args = Set(CommandLine.arguments.dropFirst())
    private let listener = NSXPCListener(machServiceName: "com.example.appA.service")
    private let listenerDelegate = ListenerDelegate()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        listener.delegate = listenerDelegate
        listener.resume()
        Logger.log("listener started service=com.example.appA.service")

        if args.contains("--call-peer") {
            callPeer(serviceName: "com.example.appB.service", exportCallback: args.contains("--variant=one-connection"))
        }

        if args.contains("--exit") {
            NSApp.terminate(nil)
        }
    }
}

let applicationDelegate = AppDelegate()
NSApplication.shared.delegate = applicationDelegate
NSApplication.shared.setActivationPolicy(.accessory)
NSApp.run()
