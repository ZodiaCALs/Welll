import Foundation
import CWelll
import WelllCore

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("welllctl: \(message)\n".utf8))
    exit(1)
}

let usage = """
Usage: welllctl <command>

  status [--json]        What Welll is doing right now
  limit <20-100>         Set the charge limit (and turn the limiter on)
  on | off               Turn the charge limiter on or off
  discharge [stop]       Run on battery until the battery is down to the limit
  topup [stop]           Charge to 100% once
  calibrate [stop]       Run battery calibration
  set <setting> <value>  Change one setting (listed below)
  settings               Print all settings as JSON
  restore                Hand charging back to macOS (uninstall.sh runs this)
  probe                  Show which charging controls this Mac exposes
  doctor                 Find out why the app can't reach the helper

Settings for `set`:
  sailing <off|1-20>           heat <off|25-50>
  auto-discharge <on|off>      adapter-cutoff <on|off>
  sleep-stop <on|off>          stay-awake <on|off>
  led <on|off>                 hardware-percent <on|off>

"""

/// Collects one XPC reply (or its error) so a command can wait with a timeout.
final class ReplyBox {
    private let lock = NSLock()
    private var finished = false
    let done = DispatchSemaphore(value: 0)
    private(set) var result: Result<WelllStatus, Daemon.Failure> = .failure(.timedOut)

    func finish(_ value: Result<WelllStatus, Daemon.Failure>) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        result = value
        done.signal()
    }
}

/// XPC client for the daemon. Every request gives up after a timeout instead of hanging.
final class Daemon {
    enum Failure: Error {
        case unreachable(String)
        case timedOut
        case rejected(String)
        case badReply
    }

    private let connection: NSXPCConnection

    init() {
        connection = NSXPCConnection(machServiceName: WelllConstants.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: WelllDaemonXPC.self)
        connection.resume()
    }

    deinit {
        connection.invalidate()
    }

    func request(timeout: TimeInterval = 20,
                 _ body: (WelllDaemonXPC, @escaping (Data?, String?) -> Void) -> Void) -> Result<WelllStatus, Failure> {
        let box = ReplyBox()
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            box.finish(.failure(.unreachable(error.localizedDescription)))
        }
        guard let daemon = proxy as? WelllDaemonXPC else {
            return .failure(.unreachable("couldn't create an XPC proxy"))
        }
        body(daemon) { data, message in
            if let message {
                box.finish(.failure(.rejected(message)))
            } else if let status = WelllCoding.decode(WelllStatus.self, from: data) {
                box.finish(.success(status))
            } else {
                box.finish(.failure(.badReply))
            }
        }
        if box.done.wait(timeout: .now() + timeout) == .timedOut {
            return .failure(.timedOut)
        }
        return box.result
    }

    private func call(_ body: (WelllDaemonXPC, @escaping (Data?, String?) -> Void) -> Void) -> WelllStatus {
        switch request(body) {
        case .success(let status):
            return status
        case .failure(.unreachable(let message)):
            fail("can't reach the Welll helper (\(message)). Run welllctl doctor to see why.")
        case .failure(.timedOut):
            fail("the Welll helper didn't answer in time. Run welllctl doctor to see why.")
        case .failure(.rejected(let message)):
            fail(message)
        case .failure(.badReply):
            fail("couldn't read the helper's reply. The tool and the helper may be different versions; run install.sh again.")
        }
    }

    func status() -> WelllStatus {
        call { daemon, reply in daemon.fetchStatus { data in reply(data, nil) } }
    }

    func update(_ change: (inout WelllSettings) -> Void) -> WelllStatus {
        var settings = status().settings
        change(&settings)
        guard let data = WelllCoding.encode(settings) else { fail("couldn't encode the settings") }
        return call { daemon, reply in daemon.updateSettings(data, withReply: reply) }
    }

    func setMode(_ mode: ChargeMode) -> WelllStatus {
        call { daemon, reply in daemon.setMode(mode.rawValue, withReply: reply) }
    }

    func restore() -> WelllStatus {
        call { daemon, reply in daemon.restoreSystemDefaults(withReply: reply) }
    }
}

/// Explains why the helper can't be reached: files, launchd, the connection, the
/// signature, the helper's log and any crash reports.
func doctor() -> Never {
    print("Welll doctor, version \(WelllConstants.version)\n")
    let diagnosis = HelperDiagnostics.diagnose()
    for line in diagnosis.checks { print("  \(line)") }

    let ping = Daemon().request(timeout: 5) { daemon, reply in
        daemon.fetchStatus { data in reply(data, nil) }
    }
    var answered = false
    switch ping {
    case .success(let status):
        answered = true
        print("  ✓  The helper answers: \(status.headline)")
        if let error = status.lastError { print("  ✗  It reports a problem: \(error)") }
    case .failure(.unreachable(let message)):
        print("  ✗  The helper doesn't answer: \(message)")
    case .failure(.timedOut):
        print("  ✗  The helper took the connection but didn't answer within 5 seconds")
    case .failure(.rejected(let message)):
        print("  ✗  The helper refused the request: \(message)")
    case .failure(.badReply):
        print("  ✗  The helper's reply couldn't be read; the tool and the helper may be different versions")
    }

    if FileManager.default.fileExists(atPath: HelperDiagnostics.helperPath),
       let signature = HelperDiagnostics.run("/usr/bin/codesign", ["--verify", HelperDiagnostics.helperPath]) {
        if signature.status == 0 {
            print("  ✓  The helper's code signature is valid")
        } else {
            print("  ✗  The helper's code signature is broken: \(signature.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    print("\nLatest lines in \(HelperDiagnostics.logPath):")
    if let text = try? String(contentsOfFile: HelperDiagnostics.logPath, encoding: .utf8), !text.isEmpty {
        for line in text.split(separator: "\n").suffix(12) { print("  \(line)") }
    } else {
        print("  (empty or missing)")
    }

    let reports = HelperDiagnostics.crashReports()
    print("\nCrash reports:")
    if reports.isEmpty {
        print("  none")
    } else {
        for report in reports.prefix(3) {
            print("  \(report.path)")
            if let summary = report.summary { print("    \(summary)") }
        }
    }

    print("\nWhat to do:")
    if answered {
        print("  The helper works. If the app still shows a problem, quit it and open it again.")
    } else {
        print("  \(diagnosis.advice)")
        print("  To load it and see macOS's reason if it refuses, run:")
        print("    sudo \(HelperDiagnostics.loaderPath)")
        print("  To watch the helper start in the foreground, run:")
        print("    sudo \(HelperDiagnostics.helperPath) --self-test")
    }
    exit(answered ? 0 : 1)
}

func printStatus(_ status: WelllStatus) {
    print(status.headline)
    if let detail = status.detail { print("  \(detail)") }
    print("")
    if let battery = status.battery {
        var line = "Battery     \(battery.percent)%"
        if let hardware = battery.hardwarePercent { line += String(format: " (hardware %.1f%%)", hardware) }
        line += battery.isCharging ? ", charging" : ", not charging"
        if status.adapterCutOff {
            line += ", wall power switched off"
        } else if battery.externalConnected {
            line += battery.adapterWatts.map { ", \($0) W charger" } ?? ", charger connected"
        } else {
            line += ", on battery"
        }
        print(line)
        let health = battery.healthPercent.map { String(format: "%.0f%%", $0) } ?? "?"
        let cycles = battery.cycleCount.map { "\($0)" } ?? "?"
        let temperature = battery.temperatureCelsius.map { String(format: "%.1f °C", $0) } ?? "?"
        print("Health      \(health), \(cycles) cycles, \(temperature)")
        if let watts = battery.batteryWatts { print(String(format: "Power       %+.1f W", watts)) }
    }
    let settings = status.settings
    var limitLine = "Limit       " + (settings.limiterEnabled ? "\(settings.chargeLimit)%" : "off")
    if let effective = status.effectiveLimit, settings.limiterEnabled, effective != settings.chargeLimit {
        limitLine += " (in effect: \(effective)%)"
    }
    if settings.sailingEnabled { limitLine += ", sailing \(settings.sailingRange)%" }
    if settings.heatProtectionEnabled {
        limitLine += String(format: ", heat protection at %.0f °C", settings.heatProtectionCelsius)
    }
    print(limitLine)
    var modeLine = "Mode        \(status.mode.rawValue)"
    if let step = status.calibrationStep { modeLine += " (step \(step.number): \(step.summary))" }
    print(modeLine)
    let hardware = status.hardware
    print("Control     \(hardware.method.title)")
    let keys = [hardware.chargeKeys, hardware.adapterKey,
                hardware.hasMagSafeLED ? "ACLC" : nil, hardware.hasBCLM ? "BCLM" : nil].compactMap { $0 }
    print("SMC keys    \(keys.isEmpty ? "none usable" : keys.joined(separator: ", "))")
    if hardware.macOSLimitSupported {
        let state: String
        switch hardware.macOSLimitEnabled {
        case .some(true): state = hardware.macOSLimitValue.map { "\($0)%" } ?? "on"
        case .some(false): state = "off"
        case .none: state = "unknown"
        }
        print("macOS limit \(state)")
    }
    if let error = status.lastError { print("\nProblem: \(error)") }
}

func parseSwitch(_ value: String) -> Bool {
    switch value.lowercased() {
    case "on", "true", "yes", "1": return true
    case "off", "false", "no", "0": return false
    default: fail("expected on or off, got “\(value)”")
    }
}

func apply(setting name: String, value: String, to settings: inout WelllSettings) {
    func number(_ range: ClosedRange<Int>) -> Int {
        guard let parsed = Int(value), range.contains(parsed) else {
            fail("\(name) expects off or a number from \(range.lowerBound) to \(range.upperBound)")
        }
        return parsed
    }
    switch name {
    case "sailing":
        if value == "off" {
            settings.sailingEnabled = false
        } else {
            settings.sailingRange = number(1...20)
            settings.sailingEnabled = true
        }
    case "heat":
        if value == "off" {
            settings.heatProtectionEnabled = false
        } else {
            settings.heatProtectionCelsius = Double(number(25...50))
            settings.heatProtectionEnabled = true
        }
    case "limit": settings.chargeLimit = number(WelllConstants.minimumLimit...WelllConstants.maximumLimit)
    case "limiter": settings.limiterEnabled = parseSwitch(value)
    case "auto-discharge": settings.autoDischarge = parseSwitch(value)
    case "adapter-cutoff": settings.allowAdapterCutOff = parseSwitch(value)
    case "sleep-stop": settings.stopChargingWhenAsleep = parseSwitch(value)
    case "stay-awake": settings.stayAwakeWhileCharging = parseSwitch(value)
    case "led": settings.magSafeLEDControl = parseSwitch(value)
    case "hardware-percent": settings.useHardwarePercentage = parseSwitch(value)
    default: fail("unknown setting “\(name)”. Run welllctl help.")
    }
}

func describe(flag: Int32) -> String {
    switch flag {
    case 1: return "yes"
    case 0: return "no"
    default: return "unknown"
    }
}

/// Read-only look at the controls this Mac exposes. Works without the helper.
func probe() {
    print("SMC keys (read-only; the helper also checks that it can write them):")
    do {
        let smc = try SMC()
        let keys: [(String, String)] = [
            ("CHTE", "pause charging (macOS 15-26 firmware)"),
            ("CH0B", "pause charging (older firmware)"),
            ("CH0C", "pause charging (older firmware)"),
            ("CHIE", "switch wall power off"),
            ("CH0I", "switch wall power off (older firmware)"),
            ("ACLC", "MagSafe light"),
            ("BCLM", "charge limit (Intel)"),
        ]
        for (name, purpose) in keys {
            let padded = name.padding(toLength: 6, withPad: " ", startingAt: 0)
            guard let info = smc.info(SMCKey(name)) else {
                print("  \(padded)not available        \(purpose)")
                continue
            }
            let value: String
            do {
                value = try smc.read(SMCKey(name)).hexString
            } catch {
                value = "unreadable"
            }
            print("  \(padded)\(info.type) \(info.size) byte(s) = \(value)   \(purpose)")
        }
    } catch {
        print("  \(error)")
    }

    print("\nmacOS Charge Limit:")
    if CPUIAvailable() == 1 {
        let limit = CPUIGetLimit()
        print("  supported: \(describe(flag: CPUIIsSupported())), on: \(describe(flag: CPUIIsEnabled())), limit: \(limit > 0 ? "\(limit)%" : "unknown")")
    } else {
        print("  not available on this version of macOS")
    }
    switch PMSet.batteryLimit() {
    case .unknown: print("  pmset: no reading")
    case .none: print("  pmset: no limit enforced")
    case .percent(let value): print("  pmset: \(value)% enforced")
    }

    if let battery = BatteryReader.read() {
        print("\nBattery: \(battery.percent)%, \(battery.isCharging ? "charging" : "not charging"), charger \(battery.externalConnected ? "connected" : "not connected")")
    } else {
        print("\nNo battery found.")
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    print(usage, terminator: "")
    exit(0)
}
let argument = arguments.count > 1 ? arguments[1] : nil

switch command {
case "status":
    let status = Daemon().status()
    if arguments.contains("--json") {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(status), let text = String(data: data, encoding: .utf8) {
            print(text)
        }
    } else {
        printStatus(status)
    }
case "limit":
    guard let argument, let value = Int(argument),
          (WelllConstants.minimumLimit...WelllConstants.maximumLimit).contains(value) else {
        fail("usage: welllctl limit <\(WelllConstants.minimumLimit)-\(WelllConstants.maximumLimit)>")
    }
    printStatus(Daemon().update { $0.chargeLimit = value; $0.limiterEnabled = true })
case "on":
    printStatus(Daemon().update { $0.limiterEnabled = true })
case "off":
    printStatus(Daemon().update { $0.limiterEnabled = false })
case "discharge", "topup", "calibrate":
    let modes: [String: ChargeMode] = ["discharge": .discharge, "topup": .topUp, "calibrate": .calibration]
    let mode = argument == "stop" ? ChargeMode.normal : (modes[command] ?? .normal)
    printStatus(Daemon().setMode(mode))
case "set":
    guard let argument, arguments.count > 2 else { fail("usage: welllctl set <setting> <value>") }
    let value = arguments[2]
    printStatus(Daemon().update { settings in apply(setting: argument, value: value, to: &settings) })
case "settings":
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(Daemon().status().settings), let text = String(data: data, encoding: .utf8) {
        print(text)
    }
case "restore":
    printStatus(Daemon().restore())
case "probe":
    probe()
case "doctor":
    doctor()
case "help", "-h", "--help":
    print(usage, terminator: "")
default:
    fail("unknown command “\(command)”. Run welllctl help.")
}
