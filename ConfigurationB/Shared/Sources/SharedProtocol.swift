import Foundation

// AppA/AppB/SharedService の3ターゲットにそれぞれコンパイルされる共有ソース。
// XPC で受け渡すには @objc + NSSecureCoding が必要。
@objc(GreetingCard)
final class GreetingCard: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }

    let from: String
    let to: String
    let text: String

    init(from: String, to: String, text: String) {
        self.from = from
        self.to = to
        self.text = text
    }

    required init?(coder: NSCoder) {
        guard
            let from = coder.decodeObject(of: NSString.self, forKey: "from") as String?,
            let to = coder.decodeObject(of: NSString.self, forKey: "to") as String?,
            let text = coder.decodeObject(of: NSString.self, forKey: "text") as String?
        else { return nil }
        self.from = from
        self.to = to
        self.text = text
    }

    func encode(with coder: NSCoder) {
        coder.encode(from as NSString, forKey: "from")
        coder.encode(to as NSString, forKey: "to")
        coder.encode(text as NSString, forKey: "text")
    }
}

// client -> SharedService
@objc(SharedXPCProtocol)
protocol SharedXPCProtocol {
    // 自分の名前で push 宛先として登録する。
    func register(clientName: String, withReply reply: @escaping (Bool) -> Void)
    // clientName 宛てに即時 push する。相手が接続中でなければ delivered=false。
    func send(_ card: GreetingCard, withReply reply: @escaping (_ delivered: Bool) -> Void)
}

// SharedService -> client（push の呼び返し）
@objc(ClientCallbackProtocol)
protocol ClientCallbackProtocol {
    func receive(_ card: GreetingCard, withReply reply: @escaping () -> Void)
}

// GreetingCard は独自クラスなので、やり取りする箇所ごとに許可クラスを明示する必要がある。
private func allowedClasses() -> Set<AnyHashable> {
    NSSet(array: [GreetingCard.self]) as! Set<AnyHashable>
}

func makeSharedXPCInterface() -> NSXPCInterface {
    let interface = NSXPCInterface(with: SharedXPCProtocol.self)
    interface.setClasses(allowedClasses(), for: #selector(SharedXPCProtocol.send(_:withReply:)), argumentIndex: 0, ofReply: false)
    return interface
}

func makeClientCallbackInterface() -> NSXPCInterface {
    let interface = NSXPCInterface(with: ClientCallbackProtocol.self)
    interface.setClasses(allowedClasses(), for: #selector(ClientCallbackProtocol.receive(_:withReply:)), argumentIndex: 0, ofReply: false)
    return interface
}
