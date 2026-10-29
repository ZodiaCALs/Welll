import Foundation

/// The SMC's live sensors: power rails, battery temperatures and the gauge's own figures.
/// macOS 27 dropped several of these from the battery's registry entry, and the registry's
/// power figures only change every so often, so the power monitor reads them here.
///
/// Only 4-byte floats are trusted (on Apple silicon the integer keys don't state their byte
/// order truthfully), and any reading outside a plausible range is ignored. Reading needs no
/// privileges.
public final class SensorReader {
    public static let shared = SensorReader()

    private let smc: SMC?
    private var isFloatKey: [String: Bool] = [:]
    private let lock = NSLock()

    private init() {
        smc = try? SMC()
    }

    /// The value of a `flt ` key, or nil when the key is missing or the value implausible.
    public func float(_ name: String, in range: ClosedRange<Double>) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard let smc else { return nil }
        let key = SMCKey(name)
        let known: Bool
        if let cached = isFloatKey[name] {
            known = cached
        } else {
            let info = smc.info(key)
            known = info?.size == 4 && info?.type == "flt "
            isFloatKey[name] = known
        }
        guard known, let bytes = try? smc.read(key), bytes.count == 4 else { return nil }
        let little = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        for bits in [little, little.byteSwapped] {
            let value = Double(Float(bitPattern: bits))
            if value.isFinite && range.contains(value) { return value }
        }
        return nil
    }

    /// The warmest plausible battery temperature, so heat is never understated.
    public func batteryTemperature() -> Double? {
        ["TB0T", "TB1T", "TB2T"].compactMap { float($0, in: 1...90) }.max()
    }
}

/// What System Settings shows for the battery (Maximum Capacity and Condition), read from
/// system_profiler. It takes about a second, so call it rarely and off the main thread.
public enum SystemBatteryReport {
    public struct Health: Equatable, Sendable {
        public var maximumCapacity: Double?
        public var condition: String?
    }

    public static func read() -> Health? {
        guard let output = CommandRunner.output("/usr/sbin/system_profiler", ["SPPowerDataType", "-json"], timeout: 30),
              let json = try? JSONSerialization.jsonObject(with: Data(output.utf8)) else { return nil }
        var health = Health()
        search(json, into: &health)
        return health.maximumCapacity == nil && health.condition == nil ? nil : health
    }

    private static func search(_ node: Any, into health: inout Health) {
        if let dictionary = node as? [String: Any] {
            for (key, value) in dictionary {
                if key == "sppower_battery_health_maximum_capacity", let text = value as? String {
                    health.maximumCapacity = Double(text.filter { $0.isNumber || $0 == "." })
                } else if key == "sppower_battery_health", let text = value as? String {
                    // system_profiler says "Good" where System Settings says "Normal".
                    health.condition = text == "Good" ? "Normal" : text
                } else {
                    search(value, into: &health)
                }
            }
        } else if let array = node as? [Any] {
            for item in array { search(item, into: &health) }
        }
    }
}

/// Runs a command and returns what it printed on standard output.
public enum CommandRunner {
    public static func output(_ path: String, _ arguments: [String], timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let group = DispatchGroup()
        var data = Data()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        guard group.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
