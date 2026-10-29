import Foundation
import WelllCore

/// `sudo wellld --self-test` checks the hardware and macOS's charge limit in the
/// foreground and prints what it finds, without starting the service.
enum SelfTest {
    static func run() -> Never {
        print("Welll helper self-test, version \(WelllConstants.version)")
        let hardware = PowerHardware()
        print("SMC: \(hardware.smcError ?? "opened")")
        print("  Pause charging: \(hardware.chargeKeyName ?? "not available")")
        print("  Wall power:     \(hardware.adapterKeyName ?? "not available")")
        print("  MagSafe light:  \(hardware.hasLED ? "available" : "not available")")
        print("  Intel limit:    \(hardware.hasBCLM ? "available" : "not available")")

        print("macOS Charge Limit (checked in a separate process):")
        switch PowerUIRunner.run(["state"]) {
        case .reply(let reply):
            let limit = reply.limit.map { "\($0)%" } ?? "unknown"
            print("  available: \(describe(reply.available)), supported: \(describe(reply.supported)), on: \(describe(reply.enabled)), limit: \(limit)")
        case .failed(let message):
            print("  \(message)")
        }

        if let battery = BatteryReader.read() {
            print("Battery: \(battery.percent)%, \(battery.isCharging ? "charging" : "not charging"), charger \(battery.externalConnected ? "connected" : "not connected")")
        } else {
            print("Battery: none found")
        }

        hardware.probeNative()
        let capabilities = Capabilities(pauseCharging: hardware.canPauseCharging,
                                        cutAdapter: hardware.canCutAdapter,
                                        macOSLimit: hardware.native != nil,
                                        bclm: hardware.hasBCLM,
                                        led: hardware.hasLED)
        print("Welll would use: \(capabilities.method.title)")
        exit(0)
    }

    private static func describe(_ flag: Int?) -> String {
        switch flag {
        case 1?: return "yes"
        case 0?: return "no"
        default: return "unknown"
        }
    }
}
