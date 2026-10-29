import Foundation
import IOKit.ps
import WelllCore

/// Owns the hardware and runs the policy whenever something changes.
final class ChargeController {
    private let hardware = PowerHardware()
    private(set) var settings: WelllSettings
    private var state = PolicyState()
    private var lastActions: ChargeActions?
    private var lastBattery: BatterySnapshot?
    private var lastError: String?
    private var appliedLED: LEDColor?
    private var appliedBCLM: Int?
    private var asleepSince: Date?
    /// Set by `restoreSystemDefaults`. Welll stops managing until a setting or mode changes.
    private var suspended = false
    /// Developer manual control: the policy leaves the switches alone until this time.
    private var manualUntil: Date?
    private var lastVerboseLog = Date.distantPast
    /// Maximum Capacity and Condition as System Settings shows them.
    private var systemHealth: SystemBatteryReport.Health?
    private var lastHealthCheck = Date.distantPast
    private var healthCheckRunning = false
    private let sleepAssertion = SleepAssertion()
    private let sleepMonitor = SleepMonitor()
    private var timer: Timer?

    init() {
        settings = SettingsStore.load()
    }

    private var capabilities: Capabilities {
        Capabilities(pauseCharging: hardware.canPauseCharging,
                     cutAdapter: hardware.canCutAdapter,
                     macOSLimit: hardware.native != nil,
                     bclm: hardware.hasBCLM,
                     led: hardware.hasLED,
                     forced: settings.forcedMethod)
    }

    func start() {
        // Never begin with wall power off: an earlier crash could have left it that way.
        if hardware.canCutAdapter { try? hardware.setAdapterCut(false) }
        if let paused = try? hardware.isChargingPaused() { state.holding = paused }

        sleepMonitor.onWillSleep = { [weak self] in self?.systemWillSleep() }
        sleepMonitor.onDidWake = { [weak self] in self?.systemDidWake() }
        sleepMonitor.start()
        observePowerSources()
        scheduleTimer()

        evaluate()
        Log.event("Started; using \(capabilities.method.title)")
    }

    /// Re-checks on a timer too, because not every battery change sends a notification.
    private func scheduleTimer() {
        timer?.invalidate()
        let interval = TimeInterval(settings.checkIntervalSeconds)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.evaluate()
        }
        timer.tolerance = interval / 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func observePowerSources() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            Unmanaged<ChargeController>.fromOpaque(context).takeUnretainedValue().evaluate()
        }
        guard let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() else {
            Log.event("Couldn't subscribe to power source changes")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    // MARK: - Evaluation

    func evaluate() {
        if let since = asleepSince {
            // A missed wake notification must not freeze the limiter.
            guard Date().timeIntervalSince(since) > 30 else { return }
            asleepSince = nil
        }
        if !hardware.canPauseCharging { hardware.probeNative() }

        guard var battery = BatteryReader.read() else {
            lastBattery = nil
            lastActions = nil
            return
        }
        refreshSystemHealthIfNeeded()
        battery.reportedHealthPercent = systemHealth?.maximumCapacity
        battery.condition = systemHealth?.condition
        lastBattery = battery
        guard !suspended else { return }

        if let until = manualUntil {
            if Date() < until {
                keepManualControlSafe(battery)
                return
            }
            manualUntil = nil
            Log.event("Manual control ended")
        }

        let adapterCut = hardware.canCutAdapter ? ((try? hardware.isAdapterCut()) ?? false) : false
        let input = PolicyInput(battery: battery, settings: settings, capabilities: capabilities,
                                adapterCutActive: adapterCut, now: Date())
        let actions = ChargePolicy(input).evaluate(&state)
        apply(actions)
        lastActions = actions

        if settings.verboseLogging && Date().timeIntervalSince(lastVerboseLog) >= 5 {
            lastVerboseLog = Date()
            Log.event("Check: \(battery.percent)%, \(battery.isCharging ? "charging" : "not charging"), \(actions.headline)")
        }
    }

    /// System Settings' health figures change slowly and take a second to read, so they're
    /// fetched in the background every half hour.
    private func refreshSystemHealthIfNeeded() {
        guard !healthCheckRunning, Date().timeIntervalSince(lastHealthCheck) > 30 * 60 else { return }
        healthCheckRunning = true
        lastHealthCheck = Date()
        DispatchQueue.global(qos: .utility).async {
            let health = SystemBatteryReport.read()
            DispatchQueue.main.async {
                self.healthCheckRunning = false
                if let health { self.systemHealth = health }
            }
        }
    }

    /// Manual control never lets the battery run below the floor on battery power.
    private func keepManualControlSafe(_ battery: BatterySnapshot) {
        guard battery.percent <= settings.dischargeFloor, hardware.canCutAdapter,
              (try? hardware.isAdapterCut()) == true else { return }
        try? hardware.setAdapterCut(false)
        Log.event("Manual control: wall power back on at \(battery.percent)%")
    }

    private func apply(_ actions: ChargeActions) {
        var problems: [String] = []

        // 1. Charging first, so wall power coming back on never starts an unwanted charge.
        if hardware.canPauseCharging {
            do {
                if try hardware.isChargingPaused() != actions.pauseCharging {
                    try hardware.setChargingPaused(actions.pauseCharging)
                    Log.event(actions.pauseCharging ? "Charging paused" : "Charging allowed")
                }
            } catch {
                problems.append("\(error)")
            }
        }

        // 2. macOS's own limit, before wall power: switching wall power off is ignored while
        //    macOS is draining the battery toward its limit.
        if capabilities.method == .macOSLimit, let native = hardware.native {
            if let limit = actions.macOSLimit {
                native.ensure(limit)
            } else {
                native.restoreOriginal()
            }
            if let error = native.lastError { problems.append(error) }
        }

        // 3. Wall power.
        if hardware.canCutAdapter {
            do {
                if try hardware.isAdapterCut() != actions.cutAdapter {
                    try hardware.setAdapterCut(actions.cutAdapter)
                    Log.event(actions.cutAdapter ? "Wall power switched off" : "Wall power switched on")
                }
            } catch {
                problems.append("\(error)")
            }
        }

        // 4. Intel firmware ceiling.
        if hardware.hasBCLM && appliedBCLM != actions.bclmCeiling {
            do {
                try hardware.setBCLM(actions.bclmCeiling)
                appliedBCLM = actions.bclmCeiling
            } catch {
                problems.append("\(error)")
            }
        }

        // 5. MagSafe light. Cosmetic, so failures are only logged.
        if hardware.hasLED && appliedLED != actions.led {
            do {
                try hardware.setLED(actions.led)
            } catch {
                Log.daemon.debug("MagSafe light: \(String(describing: error), privacy: .public)")
            }
            appliedLED = actions.led
        }

        sleepAssertion.set(actions.preventSleep)
        lastError = problems.isEmpty ? nil : problems.joined(separator: "\n")
    }

    // MARK: - Sleep

    private func systemWillSleep() {
        asleepSince = Date()
        if manualUntil != nil {
            manualUntil = nil
            Log.event("Manual control ended for sleep")
        }
        guard !suspended, var actions = lastActions else {
            if hardware.canCutAdapter { try? hardware.setAdapterCut(false) }
            return
        }
        // Nothing watches the battery during sleep, so wall power always goes back on.
        actions.cutAdapter = false
        if settings.stopChargingWhenAsleep && settings.limiterEnabled
            && hardware.canPauseCharging && state.mode == .normal {
            actions.pauseCharging = true
        }
        actions.preventSleep = false
        apply(actions)
        Log.daemon.info("Prepared for sleep")
    }

    private func systemDidWake() {
        asleepSince = nil
        evaluate()
    }

    // MARK: - Requests

    func update(settings newValue: WelllSettings) {
        let previousInterval = settings.checkIntervalSeconds
        settings = newValue.validated()
        SettingsStore.save(settings)
        suspended = false
        if settings.checkIntervalSeconds != previousInterval { scheduleTimer() }
        evaluate()
    }

    /// Operations for the app's password-protected developer page. Only these fixed
    /// commands exist; nothing here writes arbitrary SMC keys.
    func developerCommand(_ command: String, value: String) -> (output: String?, error: String?) {
        switch command {
        case "evaluate":
            evaluate()
            return ("Checked again: \(lastActions?.headline ?? "no battery reading")", nil)
        case "manual":
            if value == "on" {
                manualUntil = Date().addingTimeInterval(15 * 60)
                Log.event("Manual control on for 15 minutes")
                return ("Manual control is on for 15 minutes.", nil)
            }
            manualUntil = nil
            Log.event("Manual control off")
            evaluate()
            return ("Manual control is off. Welll manages charging again.", nil)
        case "pauseCharging", "cutAdapter", "led":
            guard let until = manualUntil, Date() < until else {
                return (nil, "Turn on manual control first.")
            }
            do {
                switch command {
                case "pauseCharging":
                    guard hardware.canPauseCharging else { return (nil, "This Mac can't pause charging.") }
                    try hardware.setChargingPaused(value == "on")
                case "cutAdapter":
                    guard hardware.canCutAdapter else { return (nil, "This Mac can't switch wall power off.") }
                    try hardware.setAdapterCut(value == "on")
                default:
                    guard hardware.hasLED, let color = LEDColor(name: value) else {
                        return (nil, "This Mac has no MagSafe light Welll can set.")
                    }
                    try hardware.setLED(color)
                    appliedLED = color
                }
            } catch {
                return (nil, "\(error)")
            }
            Log.event("Manual control: \(command) \(value)")
            return ("Done.", nil)
        default:
            return (nil, "Unknown developer command “\(command)”.")
        }
    }

    /// Returns a reason when the mode can't start.
    func request(mode: ChargeMode) -> String? {
        let caps = capabilities
        switch mode {
        case .normal, .topUp:
            break
        case .discharge:
            guard ChargePolicy.canDischarge(caps, limit: settings.chargeLimit) else {
                return "This Mac can't run on battery while plugged in."
            }
            if let battery = lastBattery,
               ChargePolicy.effectivePercent(battery, settings) <= settings.chargeLimit {
                return "The battery is already at or below \(settings.chargeLimit)%."
            }
        case .calibration:
            guard caps.cutAdapter else {
                return "Calibration needs to switch wall power off, which this Mac doesn't allow."
            }
        }
        suspended = false
        state.mode = mode
        state.calibrationStep = mode == .calibration ? .chargeToFull : nil
        state.calibrationHoldUntil = nil
        state.topUpSawPower = false
        if mode == .normal { state.autoDischarging = false }
        evaluate()
        return nil
    }

    /// Gives everything back to macOS. Used by the uninstaller and `welllctl restore`.
    func restoreSystemDefaults() {
        suspended = true
        state = PolicyState()
        if hardware.canCutAdapter { try? hardware.setAdapterCut(false) }
        if hardware.canPauseCharging { try? hardware.setChargingPaused(false) }
        if hardware.hasBCLM {
            try? hardware.setBCLM(100)
            appliedBCLM = 100
        }
        if hardware.hasLED {
            try? hardware.setLED(.system)
            appliedLED = .system
        }
        hardware.native?.restoreOriginal()
        sleepAssertion.set(false)
        manualUntil = nil
        lastActions = nil
        lastError = nil
        Log.event("Restored macOS defaults")
    }

    /// Called when launchd stops the daemon. macOS's own limit and the Intel firmware limit
    /// stay in place on purpose: they keep protecting the battery while the helper is gone.
    func prepareForExit() {
        if hardware.canCutAdapter { try? hardware.setAdapterCut(false) }
        if hardware.canPauseCharging { try? hardware.setChargingPaused(false) }
        if hardware.hasLED { try? hardware.setLED(.system) }
        sleepAssertion.set(false)
    }

    // MARK: - Status

    func status() -> WelllStatus {
        let caps = capabilities
        var report = WelllStatus()
        report.battery = lastBattery
        report.settings = settings
        report.mode = state.mode
        report.calibrationStep = state.calibrationStep
        report.calibrationHoldUntil = state.calibrationHoldUntil
        report.effectivePercent = lastBattery.map { ChargePolicy.effectivePercent($0, settings) }
        report.effectiveLimit = lastActions?.effectiveLimit
        report.chargingPaused = lastActions?.pauseCharging ?? false
        report.adapterCutOff = lastActions?.cutAdapter ?? false
        report.heatPaused = state.heatPaused
        report.sleepPrevented = sleepAssertion.isHeld
        report.managing = !suspended
        report.manualControlUntil = manualUntil
        if lastBattery == nil {
            report.headline = "No battery found"
            report.detail = "Welll only works on Macs with a battery."
        } else if suspended {
            report.headline = "Paused, macOS is in charge"
            report.detail = "Change any setting to hand charging back to Welll."
        } else {
            report.headline = lastActions?.headline ?? "Starting…"
            report.detail = lastActions?.detail
        }
        report.hardware = hardwareInfo(caps)
        report.features = features(caps)
        report.lastError = lastError ?? hardware.nativeProblem ?? hardware.smcError
        return report
    }

    private func hardwareInfo(_ caps: Capabilities) -> HardwareInfo {
        var info = HardwareInfo()
        info.method = caps.method
        info.chargeKeys = hardware.chargeKeyName
        info.adapterKey = hardware.adapterKeyName
        info.hasMagSafeLED = hardware.hasLED
        info.hasBCLM = hardware.hasBCLM
        if let native = hardware.native {
            let current = native.state
            info.macOSLimitSupported = true
            info.macOSLimitEnabled = current.enabled
            info.macOSLimitValue = current.limit
        }
        info.smcError = hardware.smcError
        return info
    }

    private func features(_ caps: Capabilities) -> FeatureSupport {
        var features = FeatureSupport()
        let method = caps.method
        let belowEighty = settings.allowAdapterCutOff && caps.cutAdapter
        if method == .macOSLimit && !belowEighty {
            features.minimumLimit = WelllConstants.macOSMinimumLimit
            features.limitStep = WelllConstants.macOSLimitStep
        }
        features.canDischarge = ChargePolicy.canDischarge(caps, limit: settings.chargeLimit)
        features.canCalibrate = caps.cutAdapter
        features.adapterCutOffOption = caps.cutAdapter && (method == .macOSLimit || method == .adapterCutOff)
        features.sailing = method == .smcGate || (features.adapterCutOffOption && settings.allowAdapterCutOff)
        features.heatProtection = method == .smcGate || method == .intelBCLM || method == .macOSLimit
        features.sleepOptions = method == .smcGate
        features.autoDischarge = caps.cutAdapter && (method == .smcGate || method == .intelBCLM)
        features.heldWhileAsleep = method == .macOSLimit || method == .intelBCLM
            || (method == .smcGate && settings.stopChargingWhenAsleep)
        return features
    }
}
