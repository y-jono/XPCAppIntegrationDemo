import Foundation
import AppKit
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
        guard validateCodeSignature(pid: connection.processIdentifier) else {
            Logger.log("requirement 不一致で拒否 pid=\(connection.processIdentifier)")
            return false
        }
        connection.exportedInterface = NSXPCInterface(with: SharedXPCProtocol.self)
        connection.exportedObject = SharedService()
        connection.remoteObjectInterface = NSXPCInterface(with: ClientCallbackProtocol.self)
        connection.interruptionHandler = { Logger.log("接続 interruption pid=\(connection.processIdentifier)") }
        connection.invalidationHandler = { Logger.log("接続 invalidation pid=\(connection.processIdentifier)") }
        connection.resume()
        return true
    }

    private func validateCodeSignature(pid: pid_t) -> Bool {
        #if DEBUG
        Logger.log("署名検査: DEBUG ビルドのため requirement チェックをスキップ")
        return true
        #else
        // Release 差分の観察用。実運用では Team ID や bundle id の requirement を評価する。
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
        return #"anchor apple generic and certificate leaf[subject.OU] = "EXAMPLE123""#
        #else
        return #"anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"#
        #endif
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let listener = NSXPCListener(machServiceName: "com.example.shared.service")
    private let listenerDelegate = ListenerDelegate()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        listener.delegate = listenerDelegate
        listener.resume()
        Logger.log("listener started service=com.example.shared.service")
    }
}

let applicationDelegate = AppDelegate()
NSApplication.shared.delegate = applicationDelegate
NSApplication.shared.setActivationPolicy(.accessory)
NSApp.run()
