import Foundation
import WelllCore

/// macOS's own Charge Limit (System Settings › Battery). Every call runs through
/// PowerUIRunner in a child process. The user's original setting is saved the first time
/// Welll changes it and put back when the limiter is switched off or Welll is removed.
final class NativeChargeLimit {
    private struct Original: Codable {
        var enabled: Bool?
        var limit: Int?
    }

    private static let originalURL = SettingsStore.directory
        .appendingPathComponent("macos-charge-limit-original.json")

    private var holdsOriginal: Bool
    private var target: Int?
    private var lastCheck = Date.distantPast
    private var attempts = 0
    private var cache: (enabled: Bool?, limit: Int?, time: Date)?
    private var failures = 0
    private(set) var lastError: String?
    /// Set after three crashes or hangs in a row. Welll then stops using macOS's limit.
    private(set) var isBroken = false

    private init(enabled: Bool?, limit: Int?) {
        holdsOriginal = FileManager.default.fileExists(atPath: Self.originalURL.path)
        cache = (enabled, limit, Date())
    }

    /// Checks whether macOS's Charge Limit exists on this Mac. The problem string is set
    /// when the private interface crashed or hung, so the caller can explain why.
    static func probe() -> (client: NativeChargeLimit?, problem: String?) {
        switch PowerUIRunner.run(["state"]) {
        case .reply(let reply):
            guard reply.available == 1, reply.supported == 1 else { return (nil, nil) }
            return (NativeChargeLimit(enabled: flag(reply.enabled), limit: reply.limit), nil)
        case .failed(let message):
            return (nil, message)
        }
    }

    /// On/off state and limit as PowerUI reports them, cached for a minute.
    var state: (enabled: Bool?, limit: Int?) {
        if let cache, Date().timeIntervalSince(cache.time) < 60 {
            return (cache.enabled, cache.limit)
        }
        switch PowerUIRunner.run(["state"]) {
        case .reply(let reply):
            failures = 0
            let current = (enabled: Self.flag(reply.enabled), limit: reply.limit)
            cache = (current.enabled, current.limit, Date())
            return current
        case .failed(let message):
            noteFailure(message)
            return (nil, nil)
        }
    }

    /// The limit in force; 100 when the feature is off.
    private var effectiveLimit: Int? {
        let current = state
        if current.enabled == false { return 100 }
        return current.limit
    }

    /// Makes macOS enforce `newTarget` (80...100 in 5% steps; 100 switches the limit off).
    /// Each change is checked against `pmset -g battlimit`, because PowerUI can accept a
    /// value that never reaches the power daemon.
    func ensure(_ newTarget: Int) {
        guard !isBroken else { return }
        saveOriginalIfNeeded()
        let now = Date()
        if newTarget != target {
            target = newTarget
            attempts = 0
            lastError = nil
        } else if now.timeIntervalSince(lastCheck) < (attempts == 0 && lastError == nil ? 600 : 60) {
            // A confirmed limit is checked again every ten minutes; a failing one every minute.
            return
        }
        lastCheck = now
        cache = nil

        if isInEffect(newTarget) {
            attempts = 0
            lastError = nil
            return
        }
        attempts += 1
        guard attempts <= 3 else {
            let current = effectiveLimit.map { "\($0)%" } ?? "an unknown value"
            lastError = "macOS kept its charge limit at \(current) instead of \(newTarget)%. Some Macs only accept the values offered in System Settings."
            return
        }
        if attempts >= 2 {
            // Switching the feature off and on makes the power daemon pick up a new value.
            _ = perform(["disable"])
        }
        apply(newTarget)
        cache = nil
    }

    /// Puts back whatever the user had before Welll took over.
    func restoreOriginal() {
        target = nil
        attempts = 0
        guard holdsOriginal else { return }
        defer {
            try? FileManager.default.removeItem(at: Self.originalURL)
            holdsOriginal = false
            cache = nil
        }
        guard let data = try? Data(contentsOf: Self.originalURL),
              let original = try? JSONDecoder().decode(Original.self, from: data) else { return }
        switch original.enabled {
        case .some(true):
            if let limit = original.limit, (80..<100).contains(limit) {
                _ = perform(["set", "\(limit)"])
            } else {
                _ = perform(["enable"])
            }
        case .some(false):
            _ = perform(["disable"])
        case .none:
            break
        }
        Log.event("Restored the original macOS charge limit")
    }

    private func isInEffect(_ value: Int) -> Bool {
        guard effectiveLimit == value else { return false }
        switch PMSet.batteryLimit() {
        case .unknown: return true
        case .none: return value >= 100
        case .percent(let enforced): return enforced == value
        }
    }

    private func apply(_ value: Int) {
        let command = value >= 100 ? ["disable"] : ["set", "\(value)"]
        if let message = perform(command) {
            lastError = value >= 100
                ? "Couldn't switch off macOS Charge Limit: \(message)"
                : "macOS refused a \(value)% charge limit: \(message)"
        } else {
            lastError = nil
        }
    }

    /// Runs one PowerUI command. Returns an error message, or nil on success.
    private func perform(_ command: [String]) -> String? {
        switch PowerUIRunner.run(command) {
        case .reply(let reply):
            failures = 0
            return reply.ok ? nil : (reply.message ?? "macOS rejected the change")
        case .failed(let message):
            noteFailure(message)
            return message
        }
    }

    private func noteFailure(_ message: String) {
        failures += 1
        lastError = message
        if failures >= 3 && !isBroken {
            isBroken = true
            Log.event("Stopped using macOS Charge Limit: \(message)")
        }
    }

    private func saveOriginalIfNeeded() {
        guard !holdsOriginal else { return }
        let current = state
        let original = Original(enabled: current.enabled, limit: current.limit)
        do {
            try FileManager.default.createDirectory(at: SettingsStore.directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(original).write(to: Self.originalURL, options: .atomic)
            holdsOriginal = true
        } catch {
            Log.event("Couldn't save the original macOS charge limit: \(error.localizedDescription)")
        }
    }

    private static func flag(_ value: Int?) -> Bool? {
        switch value {
        case 1?: return true
        case 0?: return false
        default: return nil
        }
    }
}
