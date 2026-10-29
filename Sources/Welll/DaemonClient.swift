import Foundation
import WelllCore

/// Talks to the root daemon over XPC. Completions run on the main queue.
final class DaemonClient {
    enum Failure: Error {
        case unreachable(String)
        case rejected(String, WelllStatus?)
        case badReply
    }

    typealias Completion = (Result<WelllStatus, Failure>) -> Void

    private var connection: NSXPCConnection?

    func fetchStatus(_ completion: @escaping Completion) {
        send(completion) { daemon, reply in
            daemon.fetchStatus { data in reply(data, nil) }
        }
    }

    func updateSettings(_ settings: WelllSettings, _ completion: @escaping Completion) {
        guard let data = WelllCoding.encode(settings) else {
            completion(.failure(.badReply))
            return
        }
        send(completion) { daemon, reply in
            daemon.updateSettings(data, withReply: reply)
        }
    }

    func setMode(_ mode: ChargeMode, _ completion: @escaping Completion) {
        send(completion) { daemon, reply in
            daemon.setMode(mode.rawValue, withReply: reply)
        }
    }

    /// One of the helper's fixed developer operations; completes with a message or an error.
    func developerCommand(_ command: String, value: String, _ completion: @escaping (String?, String?) -> Void) {
        let once = OnceFlag()
        let finish: (String?, String?) -> Void = { output, error in
            guard once.claim() else { return }
            DispatchQueue.main.async { completion(output, error) }
        }
        let proxy = currentConnection().remoteObjectProxyWithErrorHandler { error in
            finish(nil, DaemonClient.describe(error))
        }
        guard let daemon = proxy as? WelllDaemonXPC else {
            finish(nil, "Couldn't reach the Welll helper.")
            return
        }
        daemon.developerCommand(command, value: value) { output, error in finish(output, error) }
    }

    private func send(_ completion: @escaping Completion,
                      _ request: (WelllDaemonXPC, @escaping (Data?, String?) -> Void) -> Void) {
        let once = OnceFlag()
        let finish: Completion = { result in
            guard once.claim() else { return }
            DispatchQueue.main.async { completion(result) }
        }
        let proxy = currentConnection().remoteObjectProxyWithErrorHandler { error in
            finish(.failure(.unreachable(DaemonClient.describe(error))))
        }
        guard let daemon = proxy as? WelllDaemonXPC else {
            finish(.failure(.unreachable("Couldn't reach the Welll helper.")))
            return
        }
        request(daemon) { data, message in
            let status = WelllCoding.decode(WelllStatus.self, from: data)
            if let message {
                finish(.failure(.rejected(message, status)))
            } else if let status {
                finish(.success(status))
            } else {
                finish(.failure(.badReply))
            }
        }
    }

    private func currentConnection() -> NSXPCConnection {
        if let connection { return connection }
        let newConnection = NSXPCConnection(machServiceName: WelllConstants.machServiceName, options: .privileged)
        newConnection.remoteObjectInterface = NSXPCInterface(with: WelllDaemonXPC.self)
        newConnection.invalidationHandler = { [weak self] in
            DispatchQueue.main.async { self?.connection = nil }
        }
        newConnection.resume()
        connection = newConnection
        return newConnection
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        // 4097: connection interrupted. 4099: connection invalid (nothing is listening).
        if nsError.domain == NSCocoaErrorDomain && (nsError.code == 4097 || nsError.code == 4099) {
            return "The Welll helper isn't running."
        }
        return error.localizedDescription
    }
}

/// Lets exactly one of an XPC reply and its error handler win.
private final class OnceFlag {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
