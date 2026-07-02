import Foundation
import AppKit

// AppB は listener を持たず、launchd 登録済み SharedService へ接続する。
final class Logger {
    static func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write(Data("[\(stamp)] [AppB] \(message)\n".utf8))
    }
}

// テストスクリプト側の環境変数から渡されるテストパラメータを読み取る。
// AppA にも同じ定義があるが、他ターゲット（SharedService）は使わないためここに閉じる。
enum TestParameters {
    static func readRequiredDouble(envKey: String, logger: (String) -> Void) -> Double? {
        guard let raw = ProcessInfo.processInfo.environment[envKey] else {
            logger("環境変数 \(envKey) が未設定です。テストスクリプトから起動してください")
            return nil
        }
        guard let value = Double(raw) else {
            logger("環境変数 \(envKey) の値が不正です: \(raw)")
            return nil
        }
        return value
    }
}

// SharedService からの push を受け取る側。実処理は AppDelegate.finish() に委譲する。
final class CallbackReceiver: NSObject, ClientCallbackProtocol {
    private let onReceive: (GreetingCard) -> Void

    init(onReceive: @escaping (GreetingCard) -> Void) {
        self.onReceive = onReceive
    }

    func receive(_ card: GreetingCard, withReply reply: @escaping () -> Void) {
        Logger.log("push 受信 from=\(card.from) text=\(card.text)")
        onReceive(card)
        reply()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let myName = "AppB"
    private let peerName = "AppA"
    // push を受け取れる猶予時間、および送信前の待機時間。値はテストスクリプトが環境変数で渡す。
    private var waitSeconds: TimeInterval = 0
    private var sendDelaySeconds: TimeInterval = 0
    private var connection: NSXPCConnection?
    private var finished = false
    // 「自分の送信が完了」かつ「相手からの push を受信」の両方が揃うまでは、
    // push を受け取った瞬間に終了しない（自分の送信がまだなら打ち切ってしまうため）。
    private var didSend = false
    private var didReceive = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)

        guard
            let waitSeconds = TestParameters.readRequiredDouble(envKey: "APPCOMM_WAIT_SECONDS", logger: Logger.log),
            let sendDelaySeconds = TestParameters.readRequiredDouble(envKey: "APPCOMM_SEND_DELAY_SECONDS", logger: Logger.log)
        else {
            NSApp.terminate(nil)
            return
        }
        self.waitSeconds = waitSeconds
        self.sendDelaySeconds = sendDelaySeconds

        let connection = NSXPCConnection(machServiceName: "com.example.shared.service", options: [])
        self.connection = connection
        connection.remoteObjectInterface = makeSharedXPCInterface()
        connection.exportedInterface = makeClientCallbackInterface()
        connection.exportedObject = CallbackReceiver { [weak self] _ in
            DispatchQueue.main.async {
                self?.didReceive = true
                self?.finishIfExchangeComplete()
            }
        }
        connection.interruptionHandler = { Logger.log("interruption service=com.example.shared.service") }
        connection.invalidationHandler = { Logger.log("invalidation service=com.example.shared.service") }
        connection.resume()

        let proxy = connection.synchronousRemoteObjectProxyWithErrorHandler { error in
            Logger.log("同期 proxy error: \(error.localizedDescription)")
        } as? SharedXPCProtocol

        guard let proxy else {
            Logger.log("proxy 生成失敗。LaunchAgent 登録、bootstrap domain、署名拒否を確認してください")
            NSApp.terminate(nil)
            return
        }

        proxy.register(clientName: myName) { ok in
            Logger.log("register結果 ok=\(ok)")
        }

        // 相手がまだ register 中かもしれないので、送信は少し待ってから行う。
        DispatchQueue.main.asyncAfter(deadline: .now() + sendDelaySeconds) {
            let card = GreetingCard(from: self.myName, to: self.peerName, text: "hello from \(self.myName)")
            proxy.send(card) { delivered in
                Logger.log("送信結果 to=\(self.peerName) delivered=\(delivered)")
                self.didSend = true
                self.finishIfExchangeComplete()
            }
        }

        Timer.scheduledTimer(withTimeInterval: waitSeconds, repeats: false) { [weak self] _ in
            Logger.log("待機タイムアウト（\(String(format: "%.1f", self?.waitSeconds ?? 0))秒）")
            self?.finish()
        }
    }

    private func finishIfExchangeComplete() {
        guard didSend, didReceive else { return }
        finish()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        connection?.invalidate()
        NSApp.terminate(nil)
    }
}

let applicationDelegate = AppDelegate()
NSApplication.shared.delegate = applicationDelegate
NSApplication.shared.setActivationPolicy(.accessory)
NSApp.run()
