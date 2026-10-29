import Foundation
import SystemConfiguration
import WelllCore

/// The exported XPC object. Every request hops to the main queue, where the controller lives.
final class DaemonService: NSObject, WelllDaemonXPC {
    private let controller: ChargeController

    init(controller: ChargeController) {
        self.controller = controller
    }

    func fetchStatus(withReply reply: @escaping (Data?) -> Void) {
        DispatchQueue.main.async {
            self.controller.evaluate()
            reply(WelllCoding.encode(self.controller.status()))
        }
    }

    func updateSettings(_ settings: Data, withReply reply: @escaping (Data?, String?) -> Void) {
        DispatchQueue.main.async {
            guard let decoded = WelllCoding.decode(WelllSettings.self, from: settings) else {
                reply(nil, "Welll couldn't read those settings.")
                return
            }
            self.controller.update(settings: decoded)
            reply(WelllCoding.encode(self.controller.status()), nil)
        }
    }

    func setMode(_ mode: String, withReply reply: @escaping (Data?, String?) -> Void) {
        DispatchQueue.main.async {
            guard let parsed = ChargeMode(rawValue: mode) else {
                reply(nil, "Unknown mode “\(mode)”.")
                return
            }
            let problem = self.controller.request(mode: parsed)
            reply(WelllCoding.encode(self.controller.status()), problem)
        }
    }

    func restoreSystemDefaults(withReply reply: @escaping (Data?, String?) -> Void) {
        DispatchQueue.main.async {
            self.controller.restoreSystemDefaults()
            reply(WelllCoding.encode(self.controller.status()), nil)
        }
    }

    func developerCommand(_ command: String, value: String, withReply reply: @escaping (String?, String?) -> Void) {
        DispatchQueue.main.async {
            let result = self.controller.developerCommand(command, value: value)
            reply(result.output, result.error)
        }
    }
}

/// Accepts connections from root and from the user logged in at the console.
final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service: DaemonService

    init(service: DaemonService) {
        self.service = service
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        let uid = newConnection.effectiveUserIdentifier
        if uid != 0, let console = Self.consoleUserID(), uid != console {
            Log.daemon.notice("Refused a connection from uid \(uid, privacy: .public)")
            return false
        }
        newConnection.exportedInterface = NSXPCInterface(with: WelllDaemonXPC.self)
        newConnection.exportedObject = service
        newConnection.resume()
        return true
    }

    private static func consoleUserID() -> uid_t? {
        var uid: uid_t = 0
        guard SCDynamicStoreCopyConsoleUser(nil, &uid, nil) != nil else { return nil }
        return uid
    }
}
