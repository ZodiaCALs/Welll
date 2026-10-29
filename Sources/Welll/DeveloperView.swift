import AppKit
import SwiftUI
import WelllCore

/// Asks for the developer password before showing the developer page.
struct DeveloperGate: View {
    let onUnlock: () -> Void
    let onCancel: () -> Void

    @State private var password = ""
    @State private var wrong = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: Space.m) {
            Image(systemName: "lock.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .glassSurface(in: Circle())
            VStack(spacing: Space.xxs) {
                Text("Developer options").font(.uiSection)
                Text("Enter the developer password to continue.")
                    .font(.uiDetail)
                    .foregroundStyle(.secondary)
            }
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .focused($focused)
                .onSubmit(check)
            if wrong {
                Text("That password isn't right.")
                    .font(.uiDetail)
                    .foregroundStyle(Color.red)
            }
            HStack(spacing: Space.s) {
                Button("Cancel", action: onCancel)
                    .glassButton()
                Button("Unlock", action: check)
                    .glassButton(prominent: true)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.xl)
        .onAppear { focused = true }
    }

    private func check() {
        if DeveloperLock.matches(password) {
            onUnlock()
        } else {
            wrong = true
            password = ""
        }
    }
}

/// Every developer option: helper tuning, policy constants, manual hardware control, live
/// SMC readings, raw data and resets.
struct DeveloperView: View {
    @ObservedObject var model: AppModel
    let onClose: () -> Void

    @State private var smcReadings: [SMCReading] = []
    @State private var sensorReadings: [SMCReading] = []
    @State private var rawBattery = ""
    @State private var helperLog = ""
    @State private var showRawBattery = false
    @State private var showLog = false
    @State private var confirmReset = false

    private static let methods: [LimitMethod] = [.smcGate, .macOSLimit, .adapterCutOff, .intelBCLM, .unsupported]
    private static let checkIntervals = [5, 10, 15, 30, 60]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    if let output = model.developerOutput {
                        NoticeCard(systemImage: "terminal.fill", tint: .blue, title: "Result", message: output)
                    }
                    aboutSection
                    helperSection
                    tuningSection
                    manualSection
                    smcSection
                    sensorSection
                    dataSection
                    resetSection
                }
                .padding(.vertical, Space.xxs)
            }
            .frame(height: 470)
        }
        .onAppear(perform: reload)
    }

    private var header: some View {
        ZStack {
            Text("Developer").font(.uiSection)
            HStack {
                Button(action: onClose) {
                    HStack(spacing: Space.xxs) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Settings").font(.uiRow)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                Spacer()
                Button("Lock") {
                    model.lockDeveloperOptions()
                    onClose()
                }
                .glassButton()
                .controlSize(.small)
            }
        }
    }

    // MARK: - Sections

    private var aboutSection: some View {
        SettingsSection(title: "This build") {
            InfoRow("App", WelllConstants.version)
            InsetDivider()
            InfoRow("Helper", model.status?.version ?? "Not connected")
            InsetDivider()
            InfoRow("Control", model.hardware?.method.title ?? "–")
            InsetDivider()
            InfoRow("Manual control", manualText)
            InsetDivider()
            InfoRow("Settings file", "/Library/Application Support/Welll/settings.json")
        }
    }

    private var manualActive: Bool {
        guard let until = model.status?.manualControlUntil else { return false }
        return until > Date()
    }

    private var manualText: String {
        guard manualActive, let until = model.status?.manualControlUntil else { return "Off" }
        return "On, \(Int(until.timeIntervalSinceNow / 60) + 1) min left"
    }

    private var helperSection: some View {
        SettingsSection(title: "Helper") {
            SettingRow(symbol: "timer", tint: .blue, title: "Check every",
                       subtitle: "How often the helper re-checks on its own.") {
                Picker("Check every", selection: binding(\.checkIntervalSeconds)) {
                    ForEach(Self.checkIntervals, id: \.self) { seconds in
                        Text("\(seconds) s").tag(seconds)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            RowDivider()
            ToggleRow(symbol: "text.alignleft", tint: .gray, title: "Verbose logging",
                      subtitle: "Writes every check to the helper's log.", isOn: binding(\.verboseLogging))
            RowDivider()
            SettingRow(symbol: "switch.2", tint: .purple, title: "Control method",
                       subtitle: "Force one method when the hardware has it.") {
                Picker("Control method", selection: binding(\.forcedMethod)) {
                    Text("Automatic").tag(LimitMethod?.none)
                    ForEach(Self.methods, id: \.self) { method in
                        Text(method == .unsupported ? "Observe only" : method.title).tag(LimitMethod?.some(method))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            RowDivider()
            HStack(spacing: Space.s) {
                Button("Check now") { model.developerCommand("evaluate") }
                Button("Self-test") { model.runSelfTest() }
                Button("Restart") { model.restartHelper() }
                Spacer()
            }
            .glassButton()
            .controlSize(.small)
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s)
        }
    }

    private var tuningSection: some View {
        let settings = model.settings
        return SettingsSection(title: "Policy tuning") {
            Group {
                SettingRow(symbol: "battery.25percent", tint: .red, title: "Lowest charge on battery",
                           subtitle: "Wall power always comes back on here.") {
                    StepperValue(text: "\(settings.dischargeFloor)%") {
                        Stepper("Lowest charge", value: binding(\.dischargeFloor), in: 5...40).labelsHidden()
                    }
                }
                RowDivider()
                SettingRow(symbol: "thermometer.snowflake", tint: .teal, title: "Heat resume drop") {
                    StepperValue(text: String(format: "%.1f °C", settings.heatResumeDrop)) {
                        Stepper("Heat resume drop", value: binding(\.heatResumeDrop), in: 0.5...10, step: 0.5)
                            .labelsHidden()
                    }
                }
                RowDivider()
                SettingRow(symbol: "arrow.up.and.down", tint: .orange, title: "Adapter cut-off band") {
                    StepperValue(text: "\(settings.adapterBand)%") {
                        Stepper("Adapter band", value: binding(\.adapterBand), in: 1...20).labelsHidden()
                    }
                }
            }
            Group {
                RowDivider()
                SettingRow(symbol: "hourglass", tint: .purple, title: "Calibration hold") {
                    StepperValue(text: "\(settings.calibrationHoldMinutes) min") {
                        Stepper("Calibration hold", value: binding(\.calibrationHoldMinutes), in: 0...240, step: 15)
                            .labelsHidden()
                    }
                }
                RowDivider()
                SettingRow(symbol: "arrow.down.to.line", tint: .purple, title: "Calibration low point") {
                    StepperValue(text: "\(settings.calibrationLowPercent)%") {
                        Stepper("Calibration low point", value: binding(\.calibrationLowPercent), in: 5...50)
                            .labelsHidden()
                    }
                }
                RowDivider()
                HStack {
                    Spacer()
                    Button("Reset tuning") { model.update { $0.resetDeveloperOptions() } }
                        .glassButton()
                        .controlSize(.small)
                }
                .padding(.horizontal, Space.m)
                .padding(.vertical, Space.s)
            }
        }
    }

    private var manualSection: some View {
        let active = manualActive
        return SettingsSection(title: "Manual control") {
            ToggleRow(symbol: "hand.raised.fill", tint: .red, title: "Manual control",
                      subtitle: "Welll stops managing charging for 15 minutes. Wall power still comes back on before sleep and at the lowest charge.",
                      isOn: Binding(get: { active }, set: { model.developerCommand("manual", $0 ? "on" : "off") }))
            if active {
                RowDivider()
                SettingRow(symbol: "pause.fill", tint: .orange, title: "Charging") {
                    HStack(spacing: Space.xs) {
                        Button("Pause") { model.developerCommand("pauseCharging", "on") }
                        Button("Allow") { model.developerCommand("pauseCharging", "off") }
                    }
                    .glassButton()
                    .controlSize(.small)
                }
                RowDivider()
                SettingRow(symbol: "powerplug.fill", tint: .green, title: "Wall power") {
                    HStack(spacing: Space.xs) {
                        Button("Off") { model.developerCommand("cutAdapter", "on") }
                        Button("On") { model.developerCommand("cutAdapter", "off") }
                    }
                    .glassButton()
                    .controlSize(.small)
                }
                RowDivider()
                SettingRow(symbol: "lightbulb.fill", tint: .yellow, title: "MagSafe light") {
                    HStack(spacing: Space.xs) {
                        Button("Auto") { model.developerCommand("led", "system") }
                        Button("Green") { model.developerCommand("led", "green") }
                        Button("Orange") { model.developerCommand("led", "orange") }
                    }
                    .glassButton()
                    .controlSize(.small)
                }
            }
        }
    }

    private var smcSection: some View {
        readingsSection(title: "SMC charging keys", readings: smcReadings,
                        note: "Read live. Only the helper can write.") {
            smcReadings = SMCInspector.readChargingKeys()
        }
    }

    private var sensorSection: some View {
        readingsSection(title: "SMC sensors", readings: sensorReadings,
                        note: "Power, temperature and gauge readings the power monitor uses.") {
            sensorReadings = SMCInspector.readSensors()
        }
    }

    private func readingsSection(title: String, readings: [SMCReading], note: String,
                                 refresh: @escaping () -> Void) -> some View {
        SettingsSection(title: title) {
            ForEach(readings) { reading in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(reading.key).font(.system(size: 12, weight: .semibold, design: .monospaced))
                        Spacer()
                        Text(reading.detail)
                            .font(.uiCode)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Text(reading.purpose)
                        .font(.uiDetail)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, Space.m)
                .padding(.vertical, Space.xs + 2)
            }
            InsetDivider()
            HStack {
                Text(note)
                    .font(.uiDetail)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Refresh", action: refresh)
                    .glassButton()
                    .controlSize(.small)
            }
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s)
        }
    }

    private var dataSection: some View {
        SettingsSection(title: "Raw data") {
            DisclosureText(title: "Battery properties", isExpanded: $showRawBattery, text: rawBattery) {
                copy(rawBattery)
            }
            InsetDivider()
            DisclosureText(title: "Helper log", isExpanded: $showLog, text: helperLog) {
                copy(helperLog)
            }
            InsetDivider()
            HStack(spacing: Space.s) {
                Button("Copy status") { copy(model.statusJSON) }
                Button("Copy doctor command") { copy("welllctl doctor") }
                Spacer()
                Button("Reload") { reload() }
            }
            .glassButton()
            .controlSize(.small)
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s)
        }
    }

    private var resetSection: some View {
        SettingsSection(title: "Reset") {
            if confirmReset {
                VStack(alignment: .leading, spacing: Space.s) {
                    Text("Reset every Welll setting, including the charge limit?").font(.uiRow)
                    HStack {
                        Spacer()
                        Button("Cancel") { confirmReset = false }
                            .glassButton()
                        Button("Reset") {
                            confirmReset = false
                            model.update { $0 = WelllSettings() }
                        }
                        .glassButton(prominent: true)
                        .tint(.red)
                    }
                    .controlSize(.small)
                }
                .padding(Space.m)
            } else {
                HStack(spacing: Space.s) {
                    Button("Reset all settings…") { confirmReset = true }
                    Button("Reset app preferences") { model.resetAppPreferences() }
                    Spacer()
                }
                .glassButton()
                .controlSize(.small)
                .padding(.horizontal, Space.m)
                .padding(.vertical, Space.s)
            }
        }
    }

    // MARK: - Helpers

    private func reload() {
        smcReadings = SMCInspector.readChargingKeys()
        sensorReadings = SMCInspector.readSensors()
        rawBattery = BatteryReader.rawDescription()
        helperLog = model.helperLogTail()
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        model.show("Copied.")
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<WelllSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { newValue in model.update { $0[keyPath: keyPath] = newValue } }
        )
    }
}
