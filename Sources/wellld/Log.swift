import Foundation
import os

enum Log {
    static let daemon = Logger(subsystem: "local.welll", category: "daemon")

    /// Goes to the unified log and to the daemon's stderr (/var/log/welll.log), which
    /// `welllctl doctor` shows.
    static func event(_ message: String) {
        daemon.notice("\(message, privacy: .public)")
        FileHandle.standardError.write(Data("\(timestamp()) \(message)\n".utf8))
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }
}
