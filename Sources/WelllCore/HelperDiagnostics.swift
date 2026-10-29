import Foundation

/// Why the app can't reach the helper, worked out from the installed files and launchd.
public struct HelperDiagnosis: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case notInstalled, disabled, notLoaded, running, stopped, unknown
    }

    public var state: State
    public var summary: String
    public var advice: String
    /// One line per check, prefixed with ✓, ✗ or ?.
    public var checks: [String]

    /// Restarting only helps once the launch daemon file is installed.
    public var canRestart: Bool { state != .notInstalled }

    /// Login Items & Extensions decides whether macOS may load the helper at all.
    public var suggestsLoginItems: Bool { state == .disabled || state == .notLoaded || state == .unknown }
}

public enum HelperDiagnostics {
    public static let label = "local.welll.daemon"
    public static let plistPath = "/Library/LaunchDaemons/local.welll.daemon.plist"
    public static let helperPath = "/Library/PrivilegedHelperTools/local.welll.daemon"
    /// Root-owned script that loads the helper and explains a refusal (install.sh puts it there).
    public static let loaderPath = "/Library/PrivilegedHelperTools/local.welll.loader"
    public static let logPath = "/var/log/welll.log"

    public static func diagnose() -> HelperDiagnosis {
        let files = FileManager.default
        let hasPlist = files.fileExists(atPath: plistPath)
        let hasHelper = files.isExecutableFile(atPath: helperPath)
        var checks = [
            check(hasPlist, "Launch daemon file at \(plistPath)"),
            check(hasHelper, "Helper program at \(helperPath)"),
        ]
        guard hasPlist && hasHelper else {
            return HelperDiagnosis(state: .notInstalled,
                                   summary: "The helper isn't installed",
                                   advice: "Open Terminal in the Welll folder and run bash install.sh.",
                                   checks: checks)
        }
        if isQuarantined(plistPath) || isQuarantined(helperPath) {
            checks.append(check(false, "Free of the “downloaded from the internet” flag"))
        }
        if isDisabled() {
            checks.append(check(false, "Allowed to run in the background"))
            return HelperDiagnosis(state: .disabled,
                                   summary: "The helper is switched off",
                                   advice: "Turn Welll on in System Settings › General › Login Items & Extensions, or press Restart helper.",
                                   checks: checks)
        }
        guard let printed = run("/bin/launchctl", ["print", "system/\(label)"]) else {
            checks.append("?  Couldn't ask launchd about the helper")
            return HelperDiagnosis(state: .unknown,
                                   summary: "Welll can't reach its helper",
                                   advice: "Press Restart helper. If that doesn't help, run welllctl doctor in Terminal.",
                                   checks: checks)
        }
        if printed.status != 0 {
            if printed.output.contains("Could not find service") {
                checks.append(check(false, "Loaded by launchd"))
                return HelperDiagnosis(state: .notLoaded,
                                       summary: "macOS hasn't loaded the helper",
                                       advice: "Press Restart helper. It loads the helper and shows macOS's reason if it refuses. Also check that local.welll.daemon is switched on in Login Items & Extensions.",
                                       checks: checks)
            }
            let firstLine = printed.output.split(separator: "\n").first.map { String($0) } ?? "no details"
            checks.append("?  launchd said: \(firstLine)")
            return HelperDiagnosis(state: .unknown,
                                   summary: "Welll can't reach its helper",
                                   advice: "Press Restart helper. If that doesn't help, run welllctl doctor in Terminal.",
                                   checks: checks)
        }
        checks.append(check(true, "Loaded by launchd"))
        let state = field("state", in: printed.output) ?? "unknown"
        if state == "running" {
            checks.append(check(true, "Running (process \(field("pid", in: printed.output) ?? "?"))"))
            return HelperDiagnosis(state: .running,
                                   summary: "The helper is running but didn't answer",
                                   advice: "Press Try again. If it keeps happening, press Restart helper.",
                                   checks: checks)
        }
        var reason = state
        if let signal = field("last terminating signal", in: printed.output) {
            reason += ", last stopped by \(signal)"
        } else if let code = field("last exit code", in: printed.output) {
            reason += ", last exit code \(code)"
        }
        if let runs = field("runs", in: printed.output) { reason += ", started \(runs) times" }
        checks.append(check(false, "Running (\(reason))"))
        return HelperDiagnosis(state: .stopped,
                               summary: "The helper keeps stopping",
                               advice: "Install the latest version with bash install.sh. If it still stops, run welllctl doctor in Terminal and share what it prints.",
                               checks: checks)
    }

    /// Whether a file carries the quarantine flag macOS adds to downloads.
    public static func isQuarantined(_ path: String) -> Bool {
        getxattr(path, "com.apple.quarantine", nil, 0, 0, 0) >= 0
    }

    /// Whether the helper was switched off in Login Items & Extensions.
    public static func isDisabled() -> Bool {
        guard let result = run("/bin/launchctl", ["print-disabled", "system"]), result.status == 0 else { return false }
        for line in result.output.split(separator: "\n") where line.contains("\"\(label)\"") {
            return line.contains("disabled") || line.contains("true")
        }
        return false
    }

    public struct CrashReport: Sendable {
        public var path: String
        public var date: Date
        public var summary: String?
    }

    /// Crash reports macOS kept for the helper, newest first.
    public static func crashReports() -> [CrashReport] {
        var found: [CrashReport] = []
        for directory in ["/Library/Logs/DiagnosticReports", "/Library/Logs/DiagnosticReports/Retired"] {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { continue }
            for name in names where name.hasPrefix(label) || name.hasPrefix("wellld") {
                let path = directory + "/" + name
                let attributes = try? FileManager.default.attributesOfItem(atPath: path)
                let date = attributes?[.modificationDate] as? Date ?? .distantPast
                found.append(CrashReport(path: path, date: date, summary: summarize(path)))
            }
        }
        return found.sorted { $0.date > $1.date }
    }

    /// Runs a command and returns its exit status and combined output, or nil if it
    /// couldn't start or ran past `timeout`.
    public static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 5) -> (status: Int32, output: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return nil
        }
        let reader = OutputReader(pipe.fileHandleForReading)
        guard reader.wait(timeout: timeout) else {
            process.terminate()
            return nil
        }
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: reader.data, as: UTF8.self))
    }

    static func field(_ name: String, in text: String) -> String? {
        let prefix = name + " = "
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(prefix) {
                return String(trimmed.dropFirst(prefix.count))
            }
        }
        return nil
    }

    private static func check(_ ok: Bool, _ text: String) -> String {
        (ok ? "✓  " : "✗  ") + text
    }

    private static func summarize(_ path: String) -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return "Can't be read without sudo."
        }
        var parts: [String] = []
        let patterns = [
            #"Terminating app due to uncaught exception '([^']+)', reason: '([^']*)'"#,
            #""type"\s*:\s*"(EXC_[A-Z_]+)""#,
            #""signal"\s*:\s*"(SIG[A-Z]+)""#,
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { continue }
            var groups: [String] = []
            for index in 1..<match.numberOfRanges {
                if let range = Range(match.range(at: index), in: text) { groups.append(String(text[range])) }
            }
            parts.append(groups.joined(separator: ": "))
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

/// Collects a pipe's output on a background queue, so a stuck command can time out.
private final class OutputReader {
    private let group = DispatchGroup()
    private(set) var data = Data()

    init(_ handle: FileHandle) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            self.data = handle.readDataToEndOfFile()
            self.group.leave()
        }
    }

    func wait(timeout: TimeInterval) -> Bool {
        group.wait(timeout: .now() + timeout) == .success
    }
}
