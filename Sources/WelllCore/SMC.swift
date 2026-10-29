import Foundation
import CWelll

/// A four-character SMC key such as "CHTE".
public struct SMCKey: Hashable, CustomStringConvertible, Sendable {
    public let name: String
    public let code: UInt32

    public init(_ name: String) {
        precondition(name.utf8.count == 4, "SMC keys have exactly four characters")
        self.name = name
        self.code = name.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    public var description: String { name }
}

public struct SMCError: Error, CustomStringConvertible {
    public let operation: String
    public let key: String?
    public let status: Int32

    public var description: String {
        let reason: String
        switch status {
        case CSMC_ERR_NOT_FOUND: reason = "key not available"
        case CSMC_ERR_BAD_ARGUMENT: reason = "unexpected size"
        case CSMC_ERR_NOT_PRIVILEGED: reason = "not permitted (locked by this firmware, or not running as root)"
        case CSMC_ERR_SMC: reason = "rejected by the SMC"
        default: reason = "I/O error"
        }
        if let key { return "SMC \(operation) \(key): \(reason)" }
        return "SMC \(operation): \(reason)"
    }
}

/// Minimal client for the AppleSMC user client. Reads work for any user; writes need root.
public final class SMC {
    public struct KeyInfo {
        public let size: Int
        public let type: String
    }

    private let connection: io_connect_t

    public init() throws {
        var newConnection: io_connect_t = 0
        let status = CSMCOpen(&newConnection)
        guard status == CSMC_OK else { throw SMCError(operation: "open", key: nil, status: status) }
        connection = newConnection
    }

    deinit {
        CSMCClose(connection)
    }

    public func info(_ key: SMCKey) -> KeyInfo? {
        var raw = CSMCKeyInfo()
        guard CSMCGetKeyInfo(connection, key.code, &raw) == CSMC_OK else { return nil }
        return KeyInfo(size: Int(raw.dataSize), type: SMC.typeName(raw.dataType))
    }

    public func read(_ key: SMCKey) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: 32)
        var size: UInt32 = 0
        let connection = self.connection
        let status = buffer.withUnsafeMutableBufferPointer { pointer -> Int32 in
            CSMCReadKey(connection, key.code, pointer.baseAddress, UInt32(pointer.count), &size)
        }
        guard status == CSMC_OK else { throw SMCError(operation: "read", key: key.name, status: status) }
        return Array(buffer.prefix(Int(size)))
    }

    public func write(_ key: SMCKey, _ bytes: [UInt8]) throws {
        let connection = self.connection
        let status = bytes.withUnsafeBufferPointer { pointer -> Int32 in
            CSMCWriteKey(connection, key.code, pointer.baseAddress, UInt32(pointer.count))
        }
        guard status == CSMC_OK else { throw SMCError(operation: "write", key: key.name, status: status) }
    }

    static func typeName(_ code: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

public extension Array where Element == UInt8 {
    var hexString: String { map { String(format: "%02X", $0) }.joined() }
}
