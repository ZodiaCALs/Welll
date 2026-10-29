import AppKit
import SwiftUI
import WelllCore

/// The menu bar window, laid out like AlDente: the limiter switch and charge at the top, the
/// charge limit slider, quick toggles, the live power flow and the apps using significant
/// energy. Battery details and Settings open as pages.
struct PopoverView: View {
    @ObservedObject var model: AppModel
    @StateObject private var energy = EnergyMonitor()
    @State private var route = Route.main
    @State private var limitDraft: Double = 80
    @State private var editingLimit = false
    @State private var confirmCalibration = false

    enum Route {
        case main, battery, settings, developerGate, developer
    }

    var body: some View {
        Group {
            switch route {
            case .main:
                mainPage
            case .battery:
                batteryPage
            case .settings:
                settingsPage
            case .developerGate:
                DeveloperGate(onUnlock: {
                    model.unlockDeveloperOptions()
                    route = .developer
                }, onCancel: { route = .settings })
            case .developer:
                DeveloperView(model: model, onClose: { route = .settings })
            }
        }
        .padding(Space.l)
        .frame(width: 344)
        .onAppear {
            syncDraft()
            energy.sample()
        }
        .onChange(of: model.settings.chargeLimit) { _ in syncDraft() }
        .onChange(of: model.features) { _ in syncDraft() }
        .onChange(of: model.liveTick) { _ in
            if route == .main { energy.sample() }
        }
        .onChange(of: model.popoverVisible) { visible in
            if visible {
                energy.reset()
                energy.sample()
            } else {
                route = .main
            }
        }
    }

    // MARK: - Main page

    private var mainPage: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            titleBar
            statusHero
            if model.connectionProblem != nil {
                HelperProblemCard(model: model)
            } else if model.isConnected {
                limitCard
                modeTiles
                if confirmCalibration {
                    calibrationConfirmation
                }
                powerCard
                energyCard
            }
            notices
            footer
        }
    }

    private var titleBar: some View {
        HStack(spacing: Space.s) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 18, height: 18)
            Text("Welll").font(.uiSection)
            Spacer()
            if model.isConnected {
                Text(model.settings.limiterEnabled ? "Limiter on" : "Limiter off")
                    .font(.uiDetail)
                    .foregroundStyle(.secondary)
                Toggle("Charge limiter", isOn: binding(\.limiterEnabled))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
        }
    }

    private var statusHero: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(alignment: .center, spacing: Space.m) {
                Text(model.displayPercent.map { "\($0)%" } ?? "–")
                    .font(.uiReadout)
                    .monospacedDigit()
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(model.headline)
                        .font(.uiSection)
                        .lineLimit(1)
                    if let detail = model.detail {
                        Text(detail)
                            .font(.uiDetail)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            BatteryVessel(percent: model.displayPercent,
                          limit: model.status?.effectiveLimit,
                          tint: stateTint,
                          charging: model.isCharging)
        }
    }

    /// The colour of what's happening: charging, holding, discharging, paused for heat…
    private var stateTint: Color {
        guard let status = model.status else { return .orange }
        if status.heatPaused { return .red }
        switch status.mode {
        case .discharge: return .orange
        case .calibration: return .purple
        case .topUp: return .blue
        case .normal: break
        }
        if status.adapterCutOff { return .orange }
        if status.battery?.isCharging == true { return .green }
        if status.battery?.externalConnected == true { return .teal }
        if let percent = status.effectivePercent, percent <= 20 { return .red }
        return Color.primary.opacity(0.75)
    }

    private var limitCard: some View {
        let features = model.features
        return VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .firstTextBaseline) {
                Text("Charge limit").font(.uiSection)
                Spacer()
                Text("\(Int(limitDraft))%")
                    .font(.uiMetric)
                    .monospacedDigit()
            }
            Slider(value: $limitDraft,
                   in: Double(features.minimumLimit)...100,
                   step: Double(max(features.limitStep, 1)),
                   onEditingChanged: { editing in
                       editingLimit = editing
                       if !editing { commitLimit() }
                   })
                .tint(stateTint)
                .disabled(!model.settings.limiterEnabled)
            Text(limitCaption)
                .font(.uiDetail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Space.m)
        .cardSurface()
        .onChange(of: limitDraft) { _ in
            // Covers keyboard and accessibility adjustments, which don't report editing.
            if !editingLimit { commitLimit() }
        }
    }

    private var limitCaption: String {
        guard model.settings.limiterEnabled else { return "The limiter is off, so your Mac charges as usual." }
        switch model.hardware?.method {
        case .smcGate?:
            return "Charging pauses at the limit while the Mac keeps running on the charger."
        case .macOSLimit?:
            return model.features.minimumLimit < WelllConstants.macOSMinimumLimit
                ? "macOS holds 80% and up, even while asleep. Lower limits switch wall power off while the Mac is awake."
                : "macOS holds the limit in 5% steps, even while the Mac sleeps."
        case .adapterCutOff?:
            return "Wall power switches off at the limit. This only works while the Mac is awake."
        case .intelBCLM?:
            return "The firmware holds the limit, even while the Mac sleeps."
        case .unsupported?, nil:
            return "This Mac doesn't expose charging controls."
        }
    }

    private var modeTiles: some View {
        let features = model.features
        let settings = model.settings
        let mode = model.mode
        return GlassGroup(spacing: Space.s) {
            VStack(spacing: Space.s) {
                HStack(spacing: Space.s) {
                    ModeTile(title: "Discharge", state: mode == .discharge ? "Running" : "Off",
                             symbol: "arrow.down.to.line", tint: .orange, active: mode == .discharge,
                             enabled: features.canDischarge || mode == .discharge) {
                        model.toggle(.discharge)
                    }
                    ModeTile(title: "Top Up", state: mode == .topUp ? "To 100%" : "Off",
                             symbol: "bolt.fill", tint: .blue, active: mode == .topUp, enabled: true) {
                        model.toggle(.topUp)
                    }
                    ModeTile(title: "Calibrate", state: mode == .calibration ? calibrationState : "Off",
                             symbol: "arrow.triangle.2.circlepath", tint: .purple, active: mode == .calibration,
                             enabled: features.canCalibrate || mode == .calibration) {
                        if mode == .calibration {
                            model.setMode(.normal)
                        } else {
                            confirmCalibration = true
                        }
                    }
                }
                HStack(spacing: Space.s) {
                    ModeTile(title: "Sailing", state: settings.sailingEnabled ? "\(settings.sailingRange)% drift" : "Off",
                             symbol: "sailboat.fill", tint: .teal, active: settings.sailingEnabled,
                             enabled: features.sailing) {
                        model.update { $0.sailingEnabled.toggle() }
                    }
                    ModeTile(title: "Heat", state: settings.heatProtectionEnabled ? "Above \(Int(settings.heatProtectionCelsius))°" : "Off",
                             symbol: "thermometer.sun.fill", tint: .red, active: settings.heatProtectionEnabled,
                             enabled: features.heatProtection) {
                        model.update { $0.heatProtectionEnabled.toggle() }
                    }
                    ModeTile(title: "Sleep", state: settings.stopChargingWhenAsleep ? "No charging" : "Charges",
                             symbol: "moon.zzz.fill", tint: .indigo, active: settings.stopChargingWhenAsleep,
                             enabled: features.sleepOptions) {
                        model.update { $0.stopChargingWhenAsleep.toggle() }
                    }
                }
            }
        }
    }

    private var calibrationState: String {
        guard let step = model.status?.calibrationStep else { return "Starting" }
        return "Step \(step.number) of \(CalibrationStep.allCases.count)"
    }

    private var calibrationConfirmation: some View {
        VStack(alignment: .leading, spacing: Space.s + 2) {
            Text("Calibrate the battery?").font(.uiSection)
            Text("Welll charges to 100%, holds there, runs down to the calibration low point, charges to 100% again, then returns to your limit. It takes several hours. Keep the charger connected and the Mac awake.")
                .font(.uiDetail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { confirmCalibration = false }
                    .glassButton()
                Button("Start calibration") {
                    confirmCalibration = false
                    model.setMode(.calibration)
                }
                .glassButton(prominent: true)
                .tint(.purple)
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .padding(Space.m + 2)
        .cardSurface()
    }

    private var powerCard: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Space.xs + 2) {
                Text("Power flow").font(.uiSection)
                LiveDot(tick: model.liveTick)
                Spacer()
                updateSpeedMenu
            }
            if let battery = model.battery {
                PowerFlowView(battery: battery, wallPowerOff: model.status?.adapterCutOff == true)
            }
        }
    }

    private var updateSpeedMenu: some View {
        Menu {
            Picker("Update every", selection: $model.liveInterval) {
                ForEach(AppModel.liveIntervals, id: \.self) { seconds in
                    Text(AppModel.describe(interval: seconds)).tag(seconds)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Text("Every \(AppModel.describe(interval: model.liveInterval))")
                .font(.uiDetail)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("How often the readings refresh while this window is open")
    }

    private var energyCard: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("Using significant energy").font(.uiSection)
            VStack(alignment: .leading, spacing: 0) {
                if energy.users.isEmpty {
                    Text(energy.ready ? "No apps are using significant energy." : "Measuring…")
                        .font(.uiDetail)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Space.m)
                        .padding(.vertical, Space.s + 2)
                } else {
                    ForEach(energy.users.prefix(4)) { user in
                        if user.id != energy.users.first?.id {
                            InsetDivider()
                        }
                        EnergyRow(user: user)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
        }
    }

    private var footer: some View {
        HStack(spacing: Space.s) {
            FooterButton(title: "Battery", symbol: "heart.text.square") { route = .battery }
                .disabled(!model.isConnected)
            FooterButton(title: "Settings", symbol: "gearshape") { route = .settings }
                .disabled(!model.isConnected)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .glassButton()
                .controlSize(.small)
                .help("The limit keeps working after you quit. The helper runs in the background.")
        }
    }

    private func syncDraft() {
        guard !editingLimit else { return }
        let value = Double(snapped(model.settings.chargeLimit))
        if value != limitDraft { limitDraft = value }
    }

    private func commitLimit() {
        let value = snapped(Int(limitDraft.rounded()))
        guard value != snapped(model.settings.chargeLimit) else { return }
        model.update { $0.chargeLimit = value }
    }

    private func snapped(_ value: Int) -> Int {
        let features = model.features
        let step = max(features.limitStep, 1)
        let clamped = min(max(value, features.minimumLimit), 100)
        return clamped - (clamped - features.minimumLimit) % step
    }

    // MARK: - Battery page

    private var batteryPage: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            PageHeader(title: "Battery", onBack: { route = .main })
            if let battery = model.battery {
                HStack(spacing: 0) {
                    MetricColumn(title: "Health", value: battery.healthPercent.map { "\(Int($0.rounded()))%" } ?? "–")
                    Divider().frame(height: 28)
                    MetricColumn(title: "Cycles", value: battery.cycleCount.map { "\($0)" } ?? "–")
                    Divider().frame(height: 28)
                    MetricColumn(title: "Temperature",
                                 value: battery.temperatureCelsius.map { String(format: "%.0f °C", $0) } ?? "–")
                }
                .padding(.vertical, Space.m)
                .cardSurface()

                SettingsSection(title: "Details") {
                    if let condition = battery.condition {
                        InfoRow("Condition", condition)
                        InsetDivider()
                    }
                    InfoRow("Shown / actual", "\(battery.percent)% / "
                            + (battery.hardwarePercent.map { String(format: "%.1f%%", $0) } ?? "–"))
                    InsetDivider()
                    InfoRow("Capacity", capacityText(battery))
                    InsetDivider()
                    InfoRow("Voltage", battery.voltage.map { String(format: "%.2f V", $0) } ?? "–")
                    InsetDivider()
                    InfoRow("Charger", chargerText(battery))
                    if let minutes = battery.minutesRemaining, !battery.externalConnected {
                        InsetDivider()
                        InfoRow("Time remaining", String(format: "%ld:%02ld", minutes / 60, minutes % 60))
                    }
                }
            } else {
                Text("No battery information.")
                    .font(.uiRow)
                    .foregroundStyle(.secondary)
            }
            if let hardware = model.hardware {
                SettingsSection(title: "Control") {
                    InfoRow("Method", hardware.method.title)
                    InsetDivider()
                    InfoRow("SMC keys", smcKeysText(hardware))
                    if hardware.macOSLimitSupported {
                        InsetDivider()
                        InfoRow("macOS Charge Limit", macOSLimitText(hardware))
                    }
                }
            }
        }
    }

    private func chargerText(_ battery: BatterySnapshot) -> String {
        if model.status?.adapterCutOff == true { return "Connected, switched off" }
        guard battery.externalConnected else { return "Not connected" }
        var parts: [String] = []
        if let input = battery.systemPowerWatts { parts.append(String(format: "%.1f W in", input)) }
        if let rated = battery.adapterWatts { parts.append("\(rated) W adapter") }
        return parts.isEmpty ? "Connected" : parts.joined(separator: ", ")
    }

    private func capacityText(_ battery: BatterySnapshot) -> String {
        guard let full = battery.fullChargeCapacity else { return "–" }
        var text = "\(full) mAh"
        if let design = battery.designCapacity { text += " of \(design)" }
        return text
    }

    private func smcKeysText(_ hardware: HardwareInfo) -> String {
        let keys = [hardware.chargeKeys, hardware.adapterKey,
                    hardware.hasMagSafeLED ? "ACLC" : nil, hardware.hasBCLM ? "BCLM" : nil]
            .compactMap { $0 }
        return keys.isEmpty ? "None usable" : keys.joined(separator: ", ")
    }

    private func macOSLimitText(_ hardware: HardwareInfo) -> String {
        switch hardware.macOSLimitEnabled {
        case .some(false): return "Off"
        case .some(true): return hardware.macOSLimitValue.map { "\($0)%" } ?? "On"
        case .none: return "Unknown"
        }
    }

    // MARK: - Settings page

    private var settingsPage: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            PageHeader(title: "Settings", onBack: { route = .main })
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    chargingSettings
                    if model.features.sleepOptions {
                        SettingsSection(title: "Sleep") {
                            ToggleRow(symbol: "moon.zzz.fill", tint: .indigo, title: "Stop charging when asleep",
                                      subtitle: "Otherwise a sleeping Mac can charge past the limit.",
                                      isOn: binding(\.stopChargingWhenAsleep))
                            RowDivider()
                            ToggleRow(symbol: "cup.and.saucer.fill", tint: .brown, title: "Stay awake while charging",
                                      subtitle: "Prevents idle sleep until the limit is reached.",
                                      isOn: binding(\.stayAwakeWhileCharging))
                        }
                    }
                    displaySettings
                    updateSettings
                    generalSettings
                }
                .padding(.vertical, Space.xxs)
            }
            .frame(height: 440)
        }
    }

    private var chargingSettings: some View {
        let features = model.features
        let settings = model.settings
        let method = model.hardware?.method
        return SettingsSection(title: "Charging") {
            ToggleRow(symbol: "bolt.fill", tint: .green, title: "Charge limiter",
                      subtitle: "When off, your Mac charges as usual.", isOn: binding(\.limiterEnabled))
            if features.adapterCutOffOption {
                RowDivider()
                ToggleRow(symbol: "arrow.down.to.line", tint: .orange,
                          title: method == .macOSLimit ? "Allow limits below 80%" : "Limit with adapter cut-off",
                          subtitle: "Switches wall power off at the limit, while the Mac is awake.",
                          isOn: binding(\.allowAdapterCutOff))
            }
            if features.sailing {
                RowDivider()
                SettingRow(symbol: "sailboat.fill", tint: .teal, title: "Sailing range",
                           subtitle: "How far the charge may drift before charging again.") {
                    StepperValue(text: "\(settings.sailingRange)%") {
                        Stepper("Sailing range", value: binding(\.sailingRange), in: 1...20).labelsHidden()
                    }
                }
            }
            if features.heatProtection {
                RowDivider()
                SettingRow(symbol: "thermometer.sun.fill", tint: .red, title: "Heat threshold",
                           subtitle: "Heat protection pauses charging above this.") {
                    StepperValue(text: "\(Int(settings.heatProtectionCelsius)) °C") {
                        Stepper("Heat threshold", value: binding(\.heatProtectionCelsius), in: 25...50, step: 1)
                            .labelsHidden()
                    }
                }
            }
            if features.autoDischarge {
                RowDivider()
                ToggleRow(symbol: "arrow.down.circle.fill", tint: .orange, title: "Discharge automatically",
                          subtitle: "Run down to the limit when plugged in above it.", isOn: binding(\.autoDischarge))
            }
        }
    }

    private var displaySettings: some View {
        SettingsSection(title: "Menu bar and display") {
            ToggleRow(symbol: "percent", tint: .gray, title: "Percentage in menu bar",
                      subtitle: "Shown beside the battery, outside the icon.", isOn: $model.showPercentInMenuBar)
            RowDivider()
            ToggleRow(symbol: "ruler", tint: .gray, title: "Limit mark on the icon",
                      subtitle: "A thin notch in the menu bar battery.", isOn: $model.showLimitMarker)
            if model.hardware?.hasMagSafeLED == true {
                RowDivider()
                ToggleRow(symbol: "lightbulb.fill", tint: .yellow, title: "MagSafe light",
                          subtitle: "Green at the limit, orange while charging.", isOn: binding(\.magSafeLEDControl))
            }
            RowDivider()
            ToggleRow(symbol: "cpu", tint: .gray, title: "Hardware percentage",
                      subtitle: "The battery's own reading instead of the one macOS shows.",
                      isOn: binding(\.useHardwarePercentage))
        }
    }

    private var updateSettings: some View {
        SettingsSection(title: "Updates") {
            SettingRow(symbol: "speedometer", tint: .teal, title: "Power monitor",
                       subtitle: "While this window is open.") {
                Picker("Power monitor", selection: $model.liveInterval) {
                    ForEach(AppModel.liveIntervals, id: \.self) { seconds in
                        Text(AppModel.describe(interval: seconds)).tag(seconds)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            RowDivider()
            SettingRow(symbol: "clock.arrow.circlepath", tint: .indigo, title: "Menu bar",
                       subtitle: "In the background.") {
                Picker("Menu bar", selection: $model.backgroundInterval) {
                    ForEach(AppModel.backgroundIntervals, id: \.self) { seconds in
                        Text(AppModel.describe(interval: seconds)).tag(seconds)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
        }
    }

    private var generalSettings: some View {
        SettingsSection(title: "General") {
            ToggleRow(symbol: "power", tint: .gray, title: "Open at login",
                      isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            RowDivider()
            SettingRow(symbol: "checkmark.seal.fill", tint: .green, title: "Helper",
                       subtitle: model.status.map { "Version \($0.version), running" }) {
                Button("Restart") { model.restartHelper() }
                    .glassButton()
                    .controlSize(.small)
            }
            RowDivider()
            NavigationRow(symbol: model.developerUnlocked ? "lock.open.fill" : "lock.fill", tint: .gray,
                          title: "Developer options", trailing: model.developerUnlocked ? nil : "Locked") {
                route = model.developerUnlocked ? .developer : .developerGate
            }
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<WelllSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { newValue in model.update { $0[keyPath: keyPath] = newValue } }
        )
    }

    // MARK: - Notices

    @ViewBuilder private var notices: some View {
        if let error = model.status?.lastError {
            NoticeCard(systemImage: "exclamationmark.octagon.fill", tint: .red,
                       title: "A change didn't apply", message: error)
        }
        if let helperVersion = model.status?.version, helperVersion != WelllConstants.version {
            HStack(alignment: .center, spacing: Space.s + 2) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.blue)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text("The helper is version \(helperVersion)").font(.uiRow.weight(.semibold))
                    Text(model.canInstallHelper
                         ? "Update it to match this app, \(WelllConstants.version)."
                         : "Run install.sh again to update it.")
                        .font(.uiDetail)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if model.canInstallHelper {
                    Button("Update") { model.installHelper() }
                        .glassButton(prominent: true)
                        .controlSize(.small)
                }
            }
            .padding(Space.m)
            .messageSurface(.blue)
        }
        if let message = macOSLimitConflict {
            NoticeCard(systemImage: "info.circle.fill", tint: .blue, title: nil, message: message)
        }
        if let notice = model.notice {
            NoticeCard(systemImage: "info.circle.fill", tint: .blue, title: nil, message: notice)
        }
    }

    private var macOSLimitConflict: String? {
        guard let hardware = model.hardware, hardware.method == .smcGate,
              hardware.macOSLimitEnabled == true, let systemLimit = hardware.macOSLimitValue,
              model.settings.limiterEnabled, systemLimit < model.settings.chargeLimit else { return nil }
        return "macOS's own Charge Limit is set to \(systemLimit)%, so charging stops there first. Change it in System Settings › Battery."
    }
}
