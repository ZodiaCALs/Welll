import Foundation

/// Reads the charge limit macOS's power daemon actually enforces (`pmset -g battlimit`).
public enum PMSet {
    public enum BatteryLimit: Equatable, Sendable {
        case unknown
        case none
        case percent(Int)
    }

    public static func batteryLimit() -> BatteryLimit {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "battlimit"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return .unknown
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else {
            return .unknown
        }

        if text.range(of: "no battery level limits", options: .caseInsensitive) != nil { return .none }
        var values: [Int] = []
        for line in text.split(separator: "\n") where line.contains("chargeSocLimitSoc") {
            if let digits = line.split(whereSeparator: { !$0.isNumber }).last, let value = Int(digits) {
                values.append(value)
            }
        }
        if let lowest = values.min() { return .percent(lowest) }
        return .unknown
    }
}
