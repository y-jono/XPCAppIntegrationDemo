import Foundation
import AppKit

// SharedService が単一 vendor になり、AppA/AppB は client として接続する。
// AppA/AppB 間のやり取りは、ここが持つ「接続中の client 一覧」への即時 push で行う（永続化はしない）。
final class Logger {
    static func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write(Data("[\(stamp)] [SharedService] \(message)\n".utf8))
    }
}

final class ConnectionRegistry {
    private let lock = NSLock()
    private var connections: [String: NSXPCConnection] = [:]

    func register(name: String, connection: NSXPCConnection) {
        lock.lock(); connections[name] = connection; lock.unlock()
        Logger.log("register clientName=\(name)")
    }

    func unregister(connection: NSXPCConnection) {
        lock.lock()
        if let name = connections.first(where: { $0.value === connection })?.key {
            connections.removeValue(forKey: name)
            Logger.log("unregister clientName=\(name)")
        }
        lock.unlock()
    }

    func connection(for name: String) -> NSXPCConnection? {
        lock.lock(); defer { lock.unlock() }
        return connections[name]
    }
}

// 1接続ごとに生成される。SharedXPCProtocol の実処理は ConnectionRegistry へ委譲する。
final class ClientSession: NSObject, SharedXPCProtocol {
    private weak var connection: NSXPCConnection?
    private let registry: ConnectionRegistry

    init(connection: NSXPCConnection, registry: ConnectionRegistry) {
        self.connection = connection
        self.registry = registry
    }

    func register(clientName: String, withReply reply: @escaping (Bool) -> Void) {
        guard let connection else { reply(false); return }
        registry.register(name: clientName, connection: connection)
        reply(true)
    }

    func send(_ card: GreetingCard, withReply reply: @escaping (Bool) -> Void) {
        guard let target = registry.connection(for: card.to) else {
            Logger.log("push 失敗: \(card.to) は未接続")
            reply(false)
            return
        }
        let proxy = target.remoteObjectProxyWithErrorHandler { error in
            Logger.log("push error to=\(card.to): \(error.localizedDescription)")
        } as? ClientCallbackProtocol
        guard let proxy else {
            reply(false)
            return
        }
        Logger.log("push 送信 from=\(card.from) to=\(card.to) text=\(card.text)")
        proxy.receive(card) {
            Logger.log("push 到達確認 to=\(card.to)")
        }
        reply(true)
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let registry = ConnectionRegistry()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        Logger.log("shouldAcceptNewConnection pid=\(connection.processIdentifier)")
        connection.exportedInterface = makeSharedXPCInterface()
        connection.exportedObject = ClientSession(connection: connection, registry: registry)
        connection.remoteObjectInterface = makeClientCallbackInterface()
        connection.interruptionHandler = { Logger.log("接続 interruption pid=\(connection.processIdentifier)") }
        connection.invalidationHandler = { [registry] in
            Logger.log("接続 invalidation pid=\(connection.processIdentifier)")
            registry.unregister(connection: connection)
        }
        connection.resume()
        return true
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
