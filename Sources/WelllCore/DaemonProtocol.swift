import Foundation

/// XPC interface of the root daemon. Replies carry a JSON-encoded `WelllStatus`; the
/// optional string explains why a request was refused.
@objc public protocol WelllDaemonXPC {
    func fetchStatus(withReply reply: @escaping (Data?) -> Void)
    func updateSettings(_ settings: Data, withReply reply: @escaping (Data?, String?) -> Void)
    func setMode(_ mode: String, withReply reply: @escaping (Data?, String?) -> Void)
    func restoreSystemDefaults(withReply reply: @escaping (Data?, String?) -> Void)
    /// A fixed set of developer operations (see ChargeController.developerCommand). The reply
    /// carries a result message or an error.
    func developerCommand(_ command: String, value: String, withReply reply: @escaping (String?, String?) -> Void)
}
