import Foundation
import WelllCore

struct SMCReading: Identifiable {
    let key: String
    let purpose: String
    let detail: String

    var id: String { key }
}

/// Reads SMC keys from the app for the developer page. Reading needs no privileges; only the
/// helper can write.
enum SMCInspector {
    private static let chargingKeys: [(String, String)] = [
        ("CHTE", "Pause charging (macOS 15 to 26 firmware)"),
        ("CH0B", "Pause charging (older firmware)"),
        ("CH0C", "Pause charging (older firmware)"),
        ("CHIE", "Switch wall power off"),
        ("CH0I", "Switch wall power off (older firmware)"),
        ("ACLC", "MagSafe light"),
        ("BCLM", "Charge limit (Intel)"),
    ]

    private static let sensorKeys: [(String, String)] = [
        ("PSTR", "System power, W"),
        ("PDTR", "Charger input, W"),
        ("PPBR", "Battery rail, W"),
        ("VD0R", "Charger voltage, V"),
        ("ID0R", "Charger current, A"),
        ("TB0T", "Battery temperature, °C"),
        ("TB1T", "Battery temperature, °C"),
        ("TB2T", "Battery temperature, °C"),
        ("SBAS", "Gauge charge, %"),
        ("SBAR", "Remaining capacity, mAh"),
        ("SBAV", "Battery voltage, mV"),
    ]

    static func readChargingKeys() -> [SMCReading] { read(chargingKeys, decodeFloats: false) }
    static func readSensors() -> [SMCReading] { read(sensorKeys, decodeFloats: true) }

    private static func read(_ keys: [(String, String)], decodeFloats: Bool) -> [SMCReading] {
        guard let smc = try? SMC() else {
            return keys.map { SMCReading(key: $0.0, purpose: $0.1, detail: "SMC unavailable") }
        }
        var readings: [SMCReading] = []
        for (name, purpose) in keys {
            let key = SMCKey(name)
            guard let info = smc.info(key) else {
                readings.append(SMCReading(key: name, purpose: purpose, detail: "not available"))
                continue
            }
            guard let bytes = try? smc.read(key) else {
                readings.append(SMCReading(key: name, purpose: purpose, detail: "\(info.type), unreadable"))
                continue
            }
            var detail = "\(info.type), \(info.size) B = \(bytes.hexString)"
            if decodeFloats, info.type == "flt ", bytes.count == 4 {
                let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
                detail = String(format: "%.2f", Double(Float(bitPattern: bits)))
            }
            readings.append(SMCReading(key: name, purpose: purpose, detail: detail))
        }
        return readings
    }
}
