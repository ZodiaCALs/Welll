import Foundation
import WelllCore

/// What this Mac's hardware lets Welll do.
struct Capabilities {
    var pauseCharging = false
    var cutAdapter = false
    var macOSLimit = false
    var bclm = false
    var led = false
    /// Developer override, used only when the hardware supports it.
    var forced: LimitMethod? = nil

    var method: LimitMethod {
        if let forced, supports(forced) { return forced }
        if pauseCharging { return .smcGate }
        if bclm { return .intelBCLM }
        if macOSLimit { return .macOSLimit }
        if cutAdapter { return .adapterCutOff }
        return .unsupported
    }

    func supports(_ method: LimitMethod) -> Bool {
        switch method {
        case .smcGate: return pauseCharging
        case .intelBCLM: return bclm
        case .macOSLimit: return macOSLimit
        case .adapterCutOff: return cutAdapter
        case .unsupported: return true
        }
    }
}

struct PolicyInput {
    var battery: BatterySnapshot
    var settings: WelllSettings
    var capabilities: Capabilities
    /// Whether Welll currently has wall power switched off.
    var adapterCutActive: Bool
    var now: Date
}

/// State carried from one evaluation to the next.
struct PolicyState {
    var mode = ChargeMode.normal
    var calibrationStep: CalibrationStep?
    var calibrationHoldUntil: Date?
    /// SMC: charging stays paused until the battery falls to the resume level.
    var holding = false
    /// Adapter cut-off: wall power stays off until the battery falls to the resume level.
    var adapterHolding = false
    var autoDischarging = false
    var heatPaused = false
    var topUpSawPower = false
}

/// What the controller should do to the hardware.
struct ChargeActions: Equatable {
    var pauseCharging = false
    var cutAdapter = false
    /// macOS Charge Limit to enforce; nil gives macOS back the user's own setting.
    var macOSLimit: Int?
    var bclmCeiling = 100
    var preventSleep = false
    var led = LEDColor.system
    var effectiveLimit: Int?
    var headline = ""
    var detail: String?
}

/// The charge-limiting rules, free of side effects.
struct ChargePolicy {
    private let battery: BatterySnapshot
    private let settings: WelllSettings
    private let caps: Capabilities
    private let method: LimitMethod
    private let percent: Int
    private let full: Bool
    private let plugged: Bool
    private let now: Date

    init(_ input: PolicyInput) {
        battery = input.battery
        settings = input.settings
        caps = input.capabilities
        method = input.capabilities.method
        percent = Self.effectivePercent(input.battery, input.settings)
        full = input.battery.fullyCharged || input.battery.percent >= 100
        plugged = input.battery.externalConnected || input.adapterCutActive
        now = input.now
    }

    static func effectivePercent(_ battery: BatterySnapshot, _ settings: WelllSettings) -> Int {
        if settings.useHardwarePercentage, let hardware = battery.hardwarePercent {
            return Int(hardware.rounded())
        }
        return battery.percent
    }

    /// macOS only takes 80–100% in 5% steps. Round down so the limit is never exceeded.
    static func macOSStep(_ value: Int) -> Int {
        let clamped = min(max(value, WelllConstants.macOSMinimumLimit), 100)
        return clamped - clamped % WelllConstants.macOSLimitStep
    }

    static func canDischarge(_ caps: Capabilities, limit: Int) -> Bool {
        // macOS's own limit drains a battery that sits above it, without adapter control.
        caps.cutAdapter || (caps.method == .macOSLimit && limit >= WelllConstants.macOSMinimumLimit)
    }

    func evaluate(_ state: inout PolicyState) -> ChargeActions {
        updateHeat(&state)
        advanceMode(&state)

        var actions = ChargeActions()
        switch state.mode {
        case .normal: normal(&actions, &state)
        case .topUp: topUp(&actions)
        case .discharge: discharge(&actions, to: settings.chargeLimit)
        case .calibration: calibrate(&actions, state)
        }
        applyHeat(&actions, state)
        if actions.cutAdapter && (!caps.cutAdapter || battery.percent <= settings.dischargeFloor) {
            actions.cutAdapter = false
        }
        actions.led = ledColor(for: actions)
        return actions
    }

    // MARK: - Heat protection

    private func updateHeat(_ state: inout PolicyState) {
        guard settings.heatProtectionEnabled, let celsius = battery.temperatureCelsius else {
            state.heatPaused = false
            return
        }
        if state.heatPaused {
            if celsius <= settings.heatProtectionCelsius - settings.heatResumeDrop {
                state.heatPaused = false
            }
        } else if celsius >= settings.heatProtectionCelsius {
            state.heatPaused = true
        }
    }

    private func applyHeat(_ actions: inout ChargeActions, _ state: PolicyState) {
        guard state.heatPaused, !actions.cutAdapter else { return }
        switch method {
        case .smcGate:
            actions.pauseCharging = true
        case .intelBCLM:
            actions.bclmCeiling = min(actions.bclmCeiling, max(battery.percent, 20))
        case .macOSLimit:
            // macOS can't pause below 80%. Above it, drop the limit to the current step.
            guard battery.percent >= WelllConstants.macOSMinimumLimit else { return }
            actions.macOSLimit = min(actions.macOSLimit ?? 100, Self.macOSStep(battery.percent))
        case .adapterCutOff, .unsupported:
            return
        }
        if state.mode != .calibration { actions.preventSleep = false }
        let temperature = battery.temperatureCelsius.map { String(format: "%.1f °C", $0) } ?? "warm"
        let resume = Int(settings.heatProtectionCelsius - settings.heatResumeDrop)
        actions.headline = "Charging paused, battery is \(temperature)"
        actions.detail = "Charging resumes below \(resume) °C."
    }

    // MARK: - Modes

    private func advanceMode(_ state: inout PolicyState) {
        switch state.mode {
        case .normal:
            break
        case .topUp:
            if plugged {
                state.topUpSawPower = true
            } else if state.topUpSawPower {
                finish(&state)
            }
        case .discharge:
            if percent <= settings.chargeLimit
                || battery.percent <= settings.dischargeFloor
                || !Self.canDischarge(caps, limit: settings.chargeLimit) {
                finish(&state)
            }
        case .calibration:
            advanceCalibration(&state)
        }
    }

    private func finish(_ state: inout PolicyState) {
        state.mode = .normal
        state.calibrationStep = nil
        state.calibrationHoldUntil = nil
        state.topUpSawPower = false
        state.holding = true
    }

    private func advanceCalibration(_ state: inout PolicyState) {
        guard caps.cutAdapter else {
            finish(&state)
            return
        }
        let hold = TimeInterval(settings.calibrationHoldMinutes) * 60
        switch state.calibrationStep ?? .chargeToFull {
        case .chargeToFull:
            state.calibrationStep = .chargeToFull
            if full {
                state.calibrationStep = .holdFull
                state.calibrationHoldUntil = now.addingTimeInterval(hold)
            }
        case .holdFull:
            if now >= (state.calibrationHoldUntil ?? now) {
                state.calibrationStep = .dischargeToLow
                state.calibrationHoldUntil = nil
            }
        case .dischargeToLow:
            if battery.percent <= settings.calibrationLowPercent {
                state.calibrationStep = .rechargeToFull
            }
        case .rechargeToFull:
            if full {
                state.calibrationStep = .holdFullAgain
                state.calibrationHoldUntil = now.addingTimeInterval(hold)
            }
        case .holdFullAgain:
            if now >= (state.calibrationHoldUntil ?? now) {
                state.calibrationHoldUntil = nil
                if settings.limiterEnabled && settings.chargeLimit < 100 {
                    state.calibrationStep = .dischargeToLimit
                } else {
                    finish(&state)
                }
            }
        case .dischargeToLimit:
            if percent <= settings.chargeLimit {
                finish(&state)
            }
        }
    }

    // MARK: - Normal mode

    private func normal(_ actions: inout ChargeActions, _ state: inout PolicyState) {
        state.topUpSawPower = false
        let limit = settings.chargeLimit

        guard settings.limiterEnabled else {
            resetLatches(&state)
            actions.macOSLimit = nil
            actions.headline = idleHeadline
            actions.detail = "The charge limiter is off."
            return
        }
        guard limit < 100 else {
            resetLatches(&state)
            actions.macOSLimit = 100
            actions.effectiveLimit = 100
            actions.headline = idleHeadline
            actions.detail = "The limit is set to 100%."
            return
        }

        switch method {
        case .smcGate: holdWithSMC(&actions, &state, limit: limit)
        case .intelBCLM: holdWithBCLM(&actions, &state, limit: limit)
        case .macOSLimit: holdWithMacOS(&actions, &state, limit: limit)
        case .adapterCutOff: holdWithAdapterOnly(&actions, &state, limit: limit)
        case .unsupported:
            actions.headline = "Charge control isn't available"
            actions.detail = "This Mac exposes no charging controls Welll can use."
        }
    }

    private func resetLatches(_ state: inout PolicyState) {
        state.holding = false
        state.adapterHolding = false
        state.autoDischarging = false
    }

    private var idleHeadline: String {
        if !plugged { return "On battery" }
        if full { return "Fully charged" }
        return battery.isCharging ? "Charging" : "Plugged in, not charging"
    }

    /// SMC charge switch: pause at the limit, resume at the limit minus the sailing range.
    private func holdWithSMC(_ actions: inout ChargeActions, _ state: inout PolicyState, limit: Int) {
        let resumeAt = settings.sailingEnabled ? max(limit - settings.sailingRange, 0) : limit - 1
        if percent >= limit {
            state.holding = true
        } else if percent <= resumeAt {
            state.holding = false
        }
        actions.pauseCharging = state.holding
        actions.bclmCeiling = limit
        actions.effectiveLimit = limit
        autoDischarge(&actions, &state, limit: limit)

        if actions.cutAdapter {
            actions.headline = "Discharging to \(limit)%"
            actions.detail = "Running on battery while plugged in."
        } else if !plugged {
            actions.headline = "On battery"
        } else if actions.pauseCharging {
            describeHold(&actions, limit: limit, resumeAt: settings.sailingEnabled ? resumeAt : nil)
        } else {
            actions.headline = full ? "Fully charged" : "Charging to \(limit)%"
            actions.preventSleep = settings.stayAwakeWhileCharging && !full
        }
    }

    private func describeHold(_ actions: inout ChargeActions, limit: Int, resumeAt: Int?) {
        if percent > limit {
            actions.headline = "Not charging, above \(limit)%"
            actions.detail = caps.cutAdapter
                ? "Press Discharge to bring it down to \(limit)%."
                : "Charging resumes below \(limit)%."
        } else if percent == limit {
            actions.headline = "Holding at \(limit)%"
            actions.detail = resumeAt.map { "Charging resumes at \($0)%." }
        } else {
            actions.headline = "Sailing at \(percent)%"
            actions.detail = resumeAt.map { "Charging resumes at \($0)%." }
        }
    }

    private func autoDischarge(_ actions: inout ChargeActions, _ state: inout PolicyState, limit: Int) {
        guard settings.autoDischarge, caps.cutAdapter else {
            state.autoDischarging = false
            return
        }
        if state.autoDischarging {
            if percent <= limit || battery.percent <= settings.dischargeFloor {
                state.autoDischarging = false
                state.holding = true
            }
        } else if battery.externalConnected && percent > limit + 1 {
            state.autoDischarging = true
        }
        if state.autoDischarging {
            actions.cutAdapter = true
            actions.pauseCharging = true
            actions.preventSleep = true
        }
    }

    /// Intel: the firmware stops at BCLM by itself, including while asleep.
    private func holdWithBCLM(_ actions: inout ChargeActions, _ state: inout PolicyState, limit: Int) {
        state.holding = false
        actions.bclmCeiling = limit
        actions.effectiveLimit = limit
        autoDischarge(&actions, &state, limit: limit)
        if actions.cutAdapter {
            actions.headline = "Discharging to \(limit)%"
            actions.detail = "Running on battery while plugged in."
        } else if !plugged {
            actions.headline = "On battery"
        } else if battery.isCharging {
            actions.headline = "Charging to \(limit)%"
        } else {
            describeHold(&actions, limit: limit, resumeAt: nil)
        }
        if actions.detail == nil { actions.detail = "Held by the firmware, also while asleep." }
    }

    /// macOS 26.4+: hand the limit to macOS, which holds it during sleep too and drains a
    /// battery that sits above it. Below 80% this needs adapter cut-off, which is opt-in.
    private func holdWithMacOS(_ actions: inout ChargeActions, _ state: inout PolicyState, limit: Int) {
        state.holding = false
        state.autoDischarging = false

        if limit >= WelllConstants.macOSMinimumLimit {
            state.adapterHolding = false
            let step = Self.macOSStep(limit)
            actions.macOSLimit = step
            actions.effectiveLimit = step
            if !plugged {
                actions.headline = "On battery"
            } else if battery.isCharging {
                actions.headline = "Charging to \(step)%"
            } else if percent > step + 1 {
                actions.headline = "Draining to \(step)%"
            } else {
                actions.headline = "Holding at \(step)%"
            }
            actions.detail = step == limit
                ? "Held by macOS, also while the Mac sleeps."
                : "macOS uses 5% steps, so \(limit)% becomes \(step)%."
            return
        }

        actions.macOSLimit = WelllConstants.macOSMinimumLimit
        if settings.allowAdapterCutOff && caps.cutAdapter {
            holdWithAdapter(&actions, &state, limit: limit)
            actions.detail = [actions.detail, "macOS holds 80% while the Mac sleeps."]
                .compactMap { $0 }
                .joined(separator: " ")
        } else {
            state.adapterHolding = false
            actions.effectiveLimit = WelllConstants.macOSMinimumLimit
            if !plugged {
                actions.headline = "On battery"
            } else {
                actions.headline = battery.isCharging ? "Charging to 80%" : "Holding at 80%"
            }
            actions.detail = caps.cutAdapter
                ? "macOS can't hold below 80%. Turn on “Allow limits below 80%” in Settings."
                : "macOS can't hold below 80% on this Mac."
        }
    }

    /// Adapter cut-off: wall power goes off at the limit and comes back a few points lower,
    /// so the Mac runs on battery in between. Only enforced while the Mac is awake.
    private func holdWithAdapter(_ actions: inout ChargeActions, _ state: inout PolicyState, limit: Int) {
        let band = max(settings.sailingEnabled ? settings.sailingRange : 0, settings.adapterBand)
        let resumeAt = max(limit - band, settings.dischargeFloor + 1)
        if state.adapterHolding {
            if percent <= resumeAt || battery.percent <= settings.dischargeFloor {
                state.adapterHolding = false
            }
        } else if plugged && percent >= limit {
            state.adapterHolding = true
        }
        actions.cutAdapter = state.adapterHolding
        actions.effectiveLimit = limit
        if actions.cutAdapter {
            actions.headline = "On battery at the \(limit)% limit"
            actions.detail = "Wall power comes back at \(resumeAt)%."
        } else if !plugged {
            actions.headline = "On battery"
        } else {
            actions.headline = full ? "Fully charged" : "Charging to \(limit)%"
            actions.detail = "Wall power switches off at \(limit)%."
        }
    }

    private func holdWithAdapterOnly(_ actions: inout ChargeActions, _ state: inout PolicyState, limit: Int) {
        state.holding = false
        state.autoDischarging = false
        guard settings.allowAdapterCutOff else {
            state.adapterHolding = false
            actions.headline = idleHeadline
            actions.detail = "This Mac only lets Welll switch wall power off. Turn on “Limit with adapter cut-off” in Settings to limit charging that way."
            return
        }
        holdWithAdapter(&actions, &state, limit: limit)
    }

    // MARK: - Top up, discharge, calibration

    private func topUp(_ actions: inout ChargeActions) {
        actions.macOSLimit = 100
        actions.bclmCeiling = 100
        actions.effectiveLimit = 100
        actions.preventSleep = method == .smcGate && plugged && !full && settings.stayAwakeWhileCharging
        if full {
            actions.headline = "Topped up to 100%"
        } else if plugged {
            actions.headline = "Topping up to 100%"
        } else {
            actions.headline = "Top up starts when you plug in"
        }
        actions.detail = "Your \(settings.chargeLimit)% limit comes back after you unplug."
    }

    private func discharge(_ actions: inout ChargeActions, to target: Int) {
        actions.preventSleep = true
        actions.effectiveLimit = target
        actions.headline = "Discharging to \(target)%"
        actions.detail = "Running on battery while plugged in."
        if method == .macOSLimit {
            if target >= WelllConstants.macOSMinimumLimit {
                let step = Self.macOSStep(target)
                actions.macOSLimit = step
                actions.effectiveLimit = step
                actions.headline = "Discharging to \(step)%"
                actions.detail = "macOS drains the battery down to its limit."
            } else {
                actions.macOSLimit = WelllConstants.macOSMinimumLimit
                actions.cutAdapter = true
            }
        } else {
            actions.pauseCharging = true
            actions.cutAdapter = true
            actions.bclmCeiling = target
        }
    }

    private func calibrate(_ actions: inout ChargeActions, _ state: PolicyState) {
        let step = state.calibrationStep ?? .chargeToFull
        switch step {
        case .chargeToFull, .holdFull, .rechargeToFull, .holdFullAgain:
            actions.macOSLimit = 100
            actions.bclmCeiling = 100
            actions.effectiveLimit = 100
        case .dischargeToLow:
            actions.pauseCharging = true
            actions.cutAdapter = true
            // Wall power can only be switched off while macOS's own limit is off.
            actions.macOSLimit = 100
            actions.effectiveLimit = settings.calibrationLowPercent
        case .dischargeToLimit:
            discharge(&actions, to: settings.chargeLimit)
        }
        actions.preventSleep = true
        actions.headline = "Calibrating, step \(step.number) of \(CalibrationStep.allCases.count)"
        var detail = step == .dischargeToLow ? "Running down to \(settings.calibrationLowPercent)%" : step.summary
        if let until = state.calibrationHoldUntil, step == .holdFull || step == .holdFullAgain {
            let minutes = max(Int(until.timeIntervalSince(now) / 60), 0)
            detail += " for \(minutes) more min"
        }
        actions.detail = detail + ". Keep the charger connected."
    }

    // MARK: - MagSafe light

    private func ledColor(for actions: ChargeActions) -> LEDColor {
        guard settings.magSafeLEDControl, caps.led, plugged, !actions.cutAdapter else { return .system }
        return battery.isCharging ? .orange : .green
    }
}
