import Foundation

/// Settings the user controls. The daemon stores them in
/// /Library/Application Support/Welll/settings.json.
public struct WelllSettings: Codable, Equatable, Sendable {
    public var limiterEnabled = true
    public var chargeLimit = 80
    public var sailingEnabled = false
    public var sailingRange = 5
    public var heatProtectionEnabled = false
    public var heatProtectionCelsius = 35.0
    public var autoDischarge = false
    /// Hold a limit by switching wall power off. Needed below 80% on new firmware.
    public var allowAdapterCutOff = false
    public var stopChargingWhenAsleep = false
    public var stayAwakeWhileCharging = true
    public var magSafeLEDControl = true
    public var useHardwarePercentage = false

    // Developer options.
    /// How often the helper re-checks the battery on its own, in seconds.
    public var checkIntervalSeconds = 15
    /// Writes every check to the helper's log.
    public var verboseLogging = false
    /// Use this control method instead of the one Welll picks, when the hardware has it.
    public var forcedMethod: LimitMethod?
    /// Wall power always comes back on at or below this charge.
    public var dischargeFloor = WelllConstants.dischargeFloor
    /// Heat protection lets charging resume this many °C below its threshold.
    public var heatResumeDrop = WelllConstants.heatHysteresis
    /// Smallest gap between switching wall power off and on again (adapter cut-off).
    public var adapterBand = WelllConstants.minimumAdapterBand
    public var calibrationHoldMinutes = Int(WelllConstants.calibrationHoldSeconds / 60)
    public var calibrationLowPercent = WelllConstants.calibrationLowPercent

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case limiterEnabled, chargeLimit, sailingEnabled, sailingRange
        case heatProtectionEnabled, heatProtectionCelsius, autoDischarge, allowAdapterCutOff
        case stopChargingWhenAsleep, stayAwakeWhileCharging, magSafeLEDControl, useHardwarePercentage
        case checkIntervalSeconds, verboseLogging, forcedMethod, dischargeFloor, heatResumeDrop
        case adapterBand, calibrationHoldMinutes, calibrationLowPercent
    }

    /// Missing keys keep their defaults, so settings written by older versions still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try c.decodeIfPresent(Bool.self, forKey: .limiterEnabled) { limiterEnabled = v }
        if let v = try c.decodeIfPresent(Int.self, forKey: .chargeLimit) { chargeLimit = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .sailingEnabled) { sailingEnabled = v }
        if let v = try c.decodeIfPresent(Int.self, forKey: .sailingRange) { sailingRange = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .heatProtectionEnabled) { heatProtectionEnabled = v }
        if let v = try c.decodeIfPresent(Double.self, forKey: .heatProtectionCelsius) { heatProtectionCelsius = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .autoDischarge) { autoDischarge = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .allowAdapterCutOff) { allowAdapterCutOff = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .stopChargingWhenAsleep) { stopChargingWhenAsleep = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .stayAwakeWhileCharging) { stayAwakeWhileCharging = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .magSafeLEDControl) { magSafeLEDControl = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .useHardwarePercentage) { useHardwarePercentage = v }
        if let v = try c.decodeIfPresent(Int.self, forKey: .checkIntervalSeconds) { checkIntervalSeconds = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .verboseLogging) { verboseLogging = v }
        // An unknown method from a newer version falls back to automatic.
        forcedMethod = (try? c.decodeIfPresent(LimitMethod.self, forKey: .forcedMethod)) ?? nil
        if let v = try c.decodeIfPresent(Int.self, forKey: .dischargeFloor) { dischargeFloor = v }
        if let v = try c.decodeIfPresent(Double.self, forKey: .heatResumeDrop) { heatResumeDrop = v }
        if let v = try c.decodeIfPresent(Int.self, forKey: .adapterBand) { adapterBand = v }
        if let v = try c.decodeIfPresent(Int.self, forKey: .calibrationHoldMinutes) { calibrationHoldMinutes = v }
        if let v = try c.decodeIfPresent(Int.self, forKey: .calibrationLowPercent) { calibrationLowPercent = v }
    }

    /// Puts the developer options back to their defaults, keeping everything else.
    public mutating func resetDeveloperOptions() {
        let defaults = WelllSettings()
        checkIntervalSeconds = defaults.checkIntervalSeconds
        verboseLogging = defaults.verboseLogging
        forcedMethod = defaults.forcedMethod
        dischargeFloor = defaults.dischargeFloor
        heatResumeDrop = defaults.heatResumeDrop
        adapterBand = defaults.adapterBand
        calibrationHoldMinutes = defaults.calibrationHoldMinutes
        calibrationLowPercent = defaults.calibrationLowPercent
    }

    /// A copy with every value clamped to a safe range.
    public func validated() -> WelllSettings {
        var copy = self
        copy.chargeLimit = min(max(copy.chargeLimit, WelllConstants.minimumLimit), WelllConstants.maximumLimit)
        copy.sailingRange = min(max(copy.sailingRange, 1), 30)
        if !copy.heatProtectionCelsius.isFinite { copy.heatProtectionCelsius = 35 }
        copy.heatProtectionCelsius = min(max(copy.heatProtectionCelsius, 25), 50)
        copy.checkIntervalSeconds = min(max(copy.checkIntervalSeconds, 2), 300)
        copy.dischargeFloor = min(max(copy.dischargeFloor, 5), 40)
        if !copy.heatResumeDrop.isFinite { copy.heatResumeDrop = WelllConstants.heatHysteresis }
        copy.heatResumeDrop = min(max(copy.heatResumeDrop, 0.5), 10)
        copy.adapterBand = min(max(copy.adapterBand, 1), 20)
        copy.calibrationHoldMinutes = min(max(copy.calibrationHoldMinutes, 0), 240)
        copy.calibrationLowPercent = min(max(copy.calibrationLowPercent, copy.dischargeFloor + 1), 50)
        return copy
    }
}

public enum ChargeMode: String, Codable, CaseIterable, Sendable {
    /// Hold the battery at the charge limit.
    case normal
    /// Charge to 100% once, then return to the limit after unplugging.
    case topUp
    /// Run from the battery while plugged in until it is down to the limit.
    case discharge
    /// Full charge, an hour at 100%, down to 15%, full again, then back to the limit.
    case calibration
}

public enum CalibrationStep: String, Codable, CaseIterable, Sendable {
    case chargeToFull, holdFull, dischargeToLow, rechargeToFull, holdFullAgain, dischargeToLimit

    public var number: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }

    public var summary: String {
        switch self {
        case .chargeToFull: return "Charging to 100%"
        case .holdFull: return "Holding at 100%"
        case .dischargeToLow: return "Running down to \(WelllConstants.calibrationLowPercent)%"
        case .rechargeToFull: return "Charging to 100% again"
        case .holdFullAgain: return "Holding at 100% again"
        case .dischargeToLimit: return "Running down to your limit"
        }
    }
}

/// How this Mac's charging is being controlled.
public enum LimitMethod: String, Codable, Sendable {
    case smcGate
    case macOSLimit
    case adapterCutOff
    case intelBCLM
    case unsupported

    public var title: String {
        switch self {
        case .smcGate: return "SMC charge control"
        case .macOSLimit: return "macOS Charge Limit"
        case .adapterCutOff: return "Adapter cut-off"
        case .intelBCLM: return "Intel firmware limit"
        case .unsupported: return "Not supported"
        }
    }
}

public struct HardwareInfo: Codable, Equatable, Sendable {
    public var method = LimitMethod.unsupported
    /// SMC keys in use, for diagnostics.
    public var chargeKeys: String?
    public var adapterKey: String?
    public var hasMagSafeLED = false
    public var hasBCLM = false
    public var macOSLimitSupported = false
    public var macOSLimitEnabled: Bool?
    public var macOSLimitValue: Int?
    public var smcError: String?

    public init() {}
}

/// What the current method can do. The app only shows controls that apply.
public struct FeatureSupport: Codable, Equatable, Sendable {
    public var minimumLimit = WelllConstants.minimumLimit
    public var limitStep = 1
    public var canDischarge = false
    public var canCalibrate = false
    public var sailing = false
    public var heatProtection = false
    public var sleepOptions = false
    public var autoDischarge = false
    public var adapterCutOffOption = false
    public var heldWhileAsleep = false

    public init() {}
}

public struct WelllStatus: Codable, Sendable {
    public var version = WelllConstants.version
    public var battery: BatterySnapshot?
    public var settings = WelllSettings()
    public var mode = ChargeMode.normal
    public var calibrationStep: CalibrationStep?
    public var calibrationHoldUntil: Date?
    public var effectivePercent: Int?
    public var effectiveLimit: Int?
    public var chargingPaused = false
    public var adapterCutOff = false
    public var heatPaused = false
    public var sleepPrevented = false
    public var managing = true
    /// Developer manual control: the helper leaves the switches alone until then.
    public var manualControlUntil: Date?
    public var headline = "Starting…"
    public var detail: String?
    public var hardware = HardwareInfo()
    public var features = FeatureSupport()
    public var lastError: String?

    public init() {}
}

public enum WelllCoding {
    public static func encode<T: Encodable>(_ value: T) -> Data? {
        try? JSONEncoder().encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
