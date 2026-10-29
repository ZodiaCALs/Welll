import Foundation
import WelllCore

/// MagSafe LED colours (SMC key ACLC).
enum LEDColor: UInt8 {
    case system = 0x00
    case green = 0x03
    case orange = 0x04

    init?(name: String) {
        switch name {
        case "system": self = .system
        case "green": self = .green
        case "orange": self = .orange
        default: return nil
        }
    }
}

/// The SMC switches this Mac actually exposes. A key only counts when it has the expected
/// size and its current value can be read and written back: firmware from mid-2026
/// (macOS 27, 26.7 and 15.8) keeps some keys as empty placeholders or refuses writes, even
/// from root.
final class PowerHardware {
    enum ChargeSwitch {
        case chte
        case ch0b(withCH0C: Bool)
    }

    enum AdapterSwitch {
        case chie
        case ch0i
    }

    private enum Key {
        static let chte = SMCKey("CHTE")
        static let ch0b = SMCKey("CH0B")
        static let ch0c = SMCKey("CH0C")
        static let chie = SMCKey("CHIE")
        static let ch0i = SMCKey("CH0I")
        static let aclc = SMCKey("ACLC")
        static let bclm = SMCKey("BCLM")
    }

    private let smc: SMC?
    let smcError: String?
    private(set) var chargeSwitch: ChargeSwitch?
    private(set) var adapterSwitch: AdapterSwitch?
    private(set) var hasLED = false
    private(set) var hasBCLM = false
    private var nativeClient: NativeChargeLimit?
    /// Why macOS's Charge Limit isn't used, when its interface crashed or hung.
    private(set) var nativeProblem: String?
    private var lastNativeProbe = Date.distantPast
    private var nativeProbesLeft = 20

    init() {
        do {
            smc = try SMC()
            smcError = nil
        } catch {
            smc = nil
            smcError = "\(error)"
        }
        probeSMC()
    }

    var canPauseCharging: Bool { chargeSwitch != nil }
    var canCutAdapter: Bool { adapterSwitch != nil }

    /// macOS's own Charge Limit, unless it's missing here or stopped responding.
    var native: NativeChargeLimit? {
        guard let nativeClient, !nativeClient.isBroken else { return nil }
        return nativeClient
    }

    var chargeKeyName: String? {
        switch chargeSwitch {
        case .chte: return "CHTE"
        case .ch0b(let withCH0C): return withCH0C ? "CH0B+CH0C" : "CH0B"
        case nil: return nil
        }
    }

    var adapterKeyName: String? {
        switch adapterSwitch {
        case .chie: return "CHIE"
        case .ch0i: return "CH0I"
        case nil: return nil
        }
    }

    private func probeSMC() {
        guard let smc else { return }
        func usable(_ key: SMCKey, size: Int) -> Bool {
            guard smc.info(key)?.size == size,
                  let current = try? smc.read(key), current.count == size else { return false }
            // Writing the current value back changes nothing but proves the key is writable.
            return (try? smc.write(key, current)) != nil
        }
        if usable(Key.chte, size: 4) {
            chargeSwitch = .chte
        } else if usable(Key.ch0b, size: 1) {
            chargeSwitch = .ch0b(withCH0C: usable(Key.ch0c, size: 1))
        }
        if usable(Key.chie, size: 1) {
            adapterSwitch = .chie
        } else if usable(Key.ch0i, size: 1) {
            adapterSwitch = .ch0i
        }
        hasLED = usable(Key.aclc, size: 1)
        hasBCLM = usable(Key.bclm, size: 1)
    }

    /// Checks for macOS's Charge Limit (in a child process). PowerUIAgent may not be ready
    /// when the daemon starts at boot, so a failed check is retried for a while.
    func probeNative() {
        if let nativeClient {
            if nativeClient.isBroken {
                nativeProblem = "macOS Charge Limit stopped responding: \(nativeClient.lastError ?? "unknown error")"
            }
            return
        }
        guard nativeProbesLeft > 0, Date().timeIntervalSince(lastNativeProbe) >= 30 else { return }
        lastNativeProbe = Date()
        nativeProbesLeft -= 1
        let result = NativeChargeLimit.probe()
        nativeClient = result.client
        nativeProblem = result.problem
        if nativeClient != nil {
            Log.event("macOS Charge Limit is available")
        } else if let problem = result.problem {
            Log.event("macOS Charge Limit check failed: \(problem)")
        }
    }

    func isChargingPaused() throws -> Bool {
        guard let smc, let chargeSwitch else { return false }
        switch chargeSwitch {
        case .chte: return try smc.read(Key.chte).contains { $0 != 0 }
        case .ch0b: return try smc.read(Key.ch0b).contains { $0 != 0 }
        }
    }

    func setChargingPaused(_ paused: Bool) throws {
        guard let smc, let chargeSwitch else { return }
        switch chargeSwitch {
        case .chte:
            try smc.write(Key.chte, paused ? [0x01, 0x00, 0x00, 0x00] : [0x00, 0x00, 0x00, 0x00])
        case .ch0b(let withCH0C):
            let value: UInt8 = paused ? 0x02 : 0x00
            try smc.write(Key.ch0b, [value])
            if withCH0C { try smc.write(Key.ch0c, [value]) }
        }
    }

    func isAdapterCut() throws -> Bool {
        guard let smc, let adapterSwitch else { return false }
        switch adapterSwitch {
        case .chie: return try smc.read(Key.chie).contains { $0 != 0 }
        case .ch0i: return try smc.read(Key.ch0i).contains { $0 != 0 }
        }
    }

    func setAdapterCut(_ cut: Bool) throws {
        guard let smc, let adapterSwitch else { return }
        switch adapterSwitch {
        case .chie: try smc.write(Key.chie, [cut ? 0x08 : 0x00])
        case .ch0i: try smc.write(Key.ch0i, [cut ? 0x01 : 0x00])
        }
    }

    func setLED(_ color: LEDColor) throws {
        guard let smc, hasLED else { return }
        try smc.write(Key.aclc, [color.rawValue])
    }

    func setBCLM(_ percent: Int) throws {
        guard let smc, hasBCLM else { return }
        try smc.write(Key.bclm, [UInt8(min(max(percent, 20), 100))])
    }
}
