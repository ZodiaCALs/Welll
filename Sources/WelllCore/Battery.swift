import Foundation
import IOKit

/// One reading of the internal battery, from the AppleSmartBattery registry entry and the
/// SMC's sensors.
public struct BatterySnapshot: Codable, Equatable, Sendable {
    /// The percentage macOS shows in the menu bar.
    public var percent = 0
    /// The gauge's own state of charge, which can differ from `percent` by a few points.
    public var hardwarePercent: Double?
    public var isCharging = false
    /// False while Welll has switched wall power off, even with a charger connected.
    public var externalConnected = false
    public var fullyCharged = false
    public var temperatureCelsius: Double?
    public var cycleCount: Int?
    public var designCapacity: Int?
    public var fullChargeCapacity: Int?
    public var currentCapacity: Int?
    /// Maximum Capacity as System Settings shows it, when known.
    public var reportedHealthPercent: Double?
    /// Condition as System Settings shows it ("Normal", "Service Recommended"…).
    public var condition: String?
    public var voltage: Double?
    /// Amps; negative while discharging.
    public var amperage: Double?
    public var adapterWatts: Int?
    public var adapterName: String?
    public var minutesRemaining: Int?
    /// Watts arriving from the charger.
    public var systemPowerWatts: Double?
    /// Watts the Mac itself is using.
    public var systemLoadWatts: Double?
    /// Watts into (+) or out of (−) the battery, worked out from the SMC's power rails.
    public var measuredBatteryWatts: Double?

    public init() {}

    public var healthPercent: Double? {
        if let reportedHealthPercent { return reportedHealthPercent }
        guard let full = fullChargeCapacity, let design = designCapacity, design > 0 else { return nil }
        return min(Double(full) / Double(design) * 100, 100)
    }

    /// Watts flowing into (+) or out of (−) the battery.
    public var batteryWatts: Double? {
        if let measuredBatteryWatts { return measuredBatteryWatts }
        guard let voltage, let amperage else { return nil }
        return voltage * amperage
    }

    /// Watts the Mac uses, reported directly or worked out from the other two flows.
    public var systemUsageWatts: Double? {
        if let systemLoadWatts { return systemLoadWatts }
        guard let battery = batteryWatts else { return nil }
        if let input = systemPowerWatts { return max(input - battery, 0) }
        if !externalConnected { return max(-battery, 0) }
        return nil
    }
}

public enum BatteryReader {
    private static var cachedService: io_service_t = 0
    private static let lock = NSLock()

    /// Returns nil on Macs without a battery.
    public static func read() -> BatterySnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let properties = currentProperties() else { return nil }
        // macOS 27 moved the capacities into BatteryData; older versions keep them on top.
        let data = properties["BatteryData"] as? [String: Any] ?? [:]
        func value(_ key: String) -> Any? { properties[key] ?? data[key] }
        let sensors = SensorReader.shared

        var battery = BatterySnapshot()
        let current = integer(properties["CurrentCapacity"]) ?? 0
        let maximum = integer(properties["MaxCapacity"]) ?? 100
        if maximum == 100 || maximum <= 0 {
            battery.percent = current
        } else {
            battery.percent = Int((Double(current) / Double(maximum) * 100).rounded())
        }
        battery.percent = min(max(battery.percent, 0), 100)
        battery.isCharging = flag(properties["IsCharging"])
        battery.externalConnected = flag(properties["ExternalConnected"])
        battery.fullyCharged = flag(properties["FullyCharged"])
        battery.cycleCount = integer(value("CycleCount"))

        // Capacities. FccComp1 is the compensated figure System Settings bases health on.
        let rawMaximum = integer(value("AppleRawMaxCapacity")) ?? integer(data["FullChargeCapacity"])
        let rawCurrent = integer(value("AppleRawCurrentCapacity"))
        battery.designCapacity = integer(value("DesignCapacity"))
        battery.fullChargeCapacity = integer(data["FccComp1"]) ?? integer(value("NominalChargeCapacity")) ?? rawMaximum
        if let rawCurrent, let rawMaximum, rawMaximum > 0 {
            battery.hardwarePercent = min(max(Double(rawCurrent) / Double(rawMaximum) * 100, 0), 100)
        } else if let charge = sensors.float("SBAS", in: 0...100) {
            battery.hardwarePercent = charge
        } else if let charge = integer(data["StateOfCharge"]), (0...100).contains(charge) {
            battery.hardwarePercent = Double(charge)
        }
        battery.currentCapacity = rawCurrent ?? sensors.float("SBAR", in: 1...30_000).map { Int($0.rounded()) }

        // Temperature: the registry where it's still published, the SMC sensors otherwise.
        if let raw = integer(value("Temperature")), let degrees = celsius(fromRegistry: raw) {
            battery.temperatureCelsius = degrees
        } else {
            battery.temperatureCelsius = sensors.batteryTemperature()
        }

        if let millivolts = integer(properties["Voltage"]), millivolts > 0 {
            battery.voltage = Double(millivolts) / 1000
        } else if let millivolts = sensors.float("SBAV", in: 5000...30_000) {
            battery.voltage = millivolts / 1000
        }
        if let milliamps = integer(properties["InstantAmperage"]) ?? integer(properties["Amperage"]),
           abs(milliamps) < 30_000 {
            battery.amperage = Double(milliamps) / 1000
        }
        if let adapter = properties["AdapterDetails"] as? [String: Any] {
            battery.adapterWatts = integer(adapter["Watts"]).flatMap { $0 > 0 ? $0 : nil }
            battery.adapterName = adapter["Name"] as? String ?? adapter["Description"] as? String
        }
        if let minutes = integer(properties["TimeRemaining"]), minutes > 0, minutes < 65_535 {
            battery.minutesRemaining = minutes
        }

        // Live power from the SMC's rails; the registry's figures update only now and then.
        let load = sensors.float("PSTR", in: 0.05...1000)
        let input = sensors.float("PDTR", in: 0...1000)
        let telemetry = properties["PowerTelemetryData"] as? [String: Any] ?? [:]
        battery.systemLoadWatts = load ?? integer(telemetry["SystemLoad"]).map { Double($0) / 1000 }
        if battery.externalConnected {
            battery.systemPowerWatts = input ?? integer(telemetry["SystemPowerIn"]).map { Double($0) / 1000 }
            if let input, let load { battery.measuredBatteryWatts = input - load }
        } else {
            battery.systemPowerWatts = 0
            if let load { battery.measuredBatteryWatts = -load }
        }
        return battery
    }

    /// Every AppleSmartBattery property as sorted `key = value` lines, for the developer page.
    public static func rawDescription() -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let properties = currentProperties() else { return "This Mac has no AppleSmartBattery entry." }
        return properties.keys.sorted().map { "\($0) = \(describe(properties[$0]))" }.joined(separator: "\n")
    }

    /// The registry entry is looked up once and kept; it's dropped if reading it fails.
    private static func currentProperties() -> [String: Any]? {
        if cachedService == 0 {
            cachedService = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        }
        guard cachedService != 0 else { return nil }
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(cachedService, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties = unmanaged?.takeRetainedValue() as? [String: Any] else {
            IOObjectRelease(cachedService)
            cachedService = 0
            return nil
        }
        return properties
    }

    /// Registry temperatures are hundredths of a °C; some releases used tenths of a kelvin.
    private static func celsius(fromRegistry raw: Int) -> Double? {
        let plausible = 1.0...90.0
        let hundredths = Double(raw) / 100
        if plausible.contains(hundredths) { return hundredths }
        let fromKelvin = Double(raw) / 10 - 273.15
        return plausible.contains(fromKelvin) ? fromKelvin : nil
    }

    private static func describe(_ value: Any?) -> String {
        switch value {
        case let dictionary as [String: Any]:
            let inner = dictionary.keys.sorted().map { "\($0): \(describe(dictionary[$0]))" }
            return "{ " + inner.joined(separator: ", ") + " }"
        case let array as [Any]:
            return "[" + array.map { describe($0) }.joined(separator: ", ") + "]"
        case let data as Data:
            return "<\(data.count) bytes>"
        case let value?:
            return "\(value)"
        case nil:
            return "nil"
        }
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        // Signed values such as Amperage are stored as 64-bit two's complement.
        return Int(truncatingIfNeeded: number.int64Value)
    }

    private static func flag(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        return false
    }
}
