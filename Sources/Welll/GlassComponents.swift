import AppKit
import SwiftUI
import WelllCore

// MARK: - Battery

/// The battery as a glass vessel: the liquid is the charge, the ridge marks the limit.
struct BatteryVessel: View {
    var percent: Int?
    var limit: Int?
    var tint: Color
    var charging: Bool

    var body: some View {
        GeometryReader { proxy in
            let inset: CGFloat = 4
            let height = max(proxy.size.height - inset * 2, 1)
            let track = max(proxy.size.width - inset * 2, 1)
            let level = CGFloat(min(max(percent ?? 0, 0), 100)) / 100
            ZStack(alignment: .leading) {
                if level > 0 {
                    Capsule(style: .continuous)
                        .fill(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.72)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: max(track * level, height), height: height)
                        .offset(x: inset)
                }
                if let limit, limit < 100 {
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(0.7))
                        .frame(width: 2, height: proxy.size.height - 2)
                        .offset(x: inset + track * CGFloat(limit) / 100 - 1)
                }
                if charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.white)
                        .shadow(color: Color.black.opacity(0.3), radius: 1.5)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
            .animation(.easeInOut(duration: 0.4), value: percent)
        }
        .frame(height: 30)
        .glassSurface(in: Capsule(style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(percent.map { "Battery at \($0) percent" } ?? "Battery level unknown")
    }
}

/// A round glass button with a caption, in the manner of Control Center.
struct ActionButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    let active: Bool
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        VStack(spacing: Space.s - 2) {
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(active ? Color.white : Color.primary)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassSurface(in: Circle(), tint: active ? tint : nil)
            Text(title)
                .font(.uiDetail.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}

/// A Fluent 2 compound toggle button made of Liquid Glass: a symbol, a title and the current
/// state. Tinted while on.
struct ModeTile: View {
    let title: String
    let state: String
    let symbol: String
    let tint: Color
    let active: Bool
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Space.s - 2) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(active ? Color.white : tint)
                    .frame(width: 24, height: 24)
                    .background(active ? Color.white.opacity(0.22) : tint.opacity(0.14), in: Circle())
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.uiRow.weight(.medium))
                        .lineLimit(1)
                    Text(state)
                        .font(.uiDetail)
                        .lineLimit(1)
                        .opacity(0.72)
                }
            }
            .foregroundStyle(active ? Color.white : Color.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.s + 2)
            .contentShape(RoundedRectangle(cornerRadius: Radius.toggle, style: .continuous))
        }
        .buttonStyle(.plain)
        .glassSurface(in: RoundedRectangle(cornerRadius: Radius.toggle, style: .continuous), tint: active ? tint : nil)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityValue(state)
    }
}

/// A small dot that glows each time a new reading arrives.
struct LiveDot: View {
    let tick: Int
    @State private var lit = false

    var body: some View {
        Circle()
            .fill(Color.green)
            .frame(width: 6, height: 6)
            .opacity(lit ? 1 : 0.3)
            .onChange(of: tick) { _ in
                withAnimation(.easeIn(duration: 0.12)) { lit = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    withAnimation(.easeOut(duration: 0.7)) { lit = false }
                }
            }
            .accessibilityHidden(true)
    }
}

/// One app in the significant-energy list.
struct EnergyRow: View {
    let user: EnergyUser

    var body: some View {
        HStack(spacing: Space.s + 2) {
            if let icon = user.icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 20, height: 20)
            } else {
                Image(systemName: "app.dashed")
                    .frame(width: 20, height: 20)
                    .foregroundStyle(.secondary)
            }
            Text(user.name)
                .font(.uiRow)
                .lineLimit(1)
            Spacer(minLength: Space.s)
            Text(user.label)
                .font(.uiRow)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s - 1)
    }
}

/// A back button and a title at the top of a sub-page.
struct PageHeader<Trailing: View>: View {
    let title: String
    let onBack: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        ZStack {
            Text(title).font(.uiSection)
            HStack {
                Button(action: onBack) {
                    HStack(spacing: Space.xxs) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Back").font(.uiRow)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                Spacer()
                trailing()
            }
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, onBack: @escaping () -> Void) {
        self.init(title: title, onBack: onBack, trailing: { EmptyView() })
    }
}

/// A small glass button with a symbol and a caption, for the window's footer.
struct FooterButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.uiDetail)
        }
        .glassButton()
        .controlSize(.small)
    }
}

// MARK: - Power flow

/// Where the power goes: from the charger to the Mac, and between the Mac and its battery.
struct PowerFlowView: View {
    let battery: BatterySnapshot
    let wallPowerOff: Bool

    private var batteryWatts: Double { battery.batteryWatts ?? 0 }
    private var chargerActive: Bool { battery.externalConnected && !wallPowerOff }
    private var batteryActive: Bool { abs(batteryWatts) > 0.3 }

    var body: some View {
        HStack(spacing: 0) {
            FlowColumn(symbol: "powerplug.fill", value: chargerValue, label: "Charger",
                       active: chargerActive, tint: .green)
            FlowChevron(pointsRight: true, active: chargerActive)
            FlowColumn(symbol: "laptopcomputer", value: Self.watts(battery.systemUsageWatts), label: "Mac",
                       active: true, tint: .primary)
            FlowChevron(pointsRight: batteryWatts > 0, active: batteryActive)
            FlowColumn(symbol: batteryWatts > 0.3 ? "battery.100percent.bolt" : "battery.75percent",
                       value: Self.signedWatts(battery.batteryWatts), label: "Battery",
                       active: batteryActive, tint: batteryWatts > 0 ? .green : .orange)
        }
        .padding(.vertical, Space.m)
        .cardSurface()
    }

    private var chargerValue: String {
        if wallPowerOff { return "Off" }
        guard battery.externalConnected else { return "None" }
        if let watts = battery.systemPowerWatts { return Self.watts(watts) }
        if let rated = battery.adapterWatts { return "\(rated) W max" }
        return "On"
    }

    static func watts(_ value: Double?) -> String {
        guard let value else { return "–" }
        return String(format: "%.1f W", value)
    }

    static func signedWatts(_ value: Double?) -> String {
        guard let value else { return "–" }
        if abs(value) < 0.05 { return "0 W" }
        return String(format: "%+.1f W", value)
    }
}

private struct FlowColumn: View {
    let symbol: String
    let value: String
    let label: String
    let active: Bool
    let tint: Color

    var body: some View {
        VStack(spacing: Space.xs - 1) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(active ? tint : Color.secondary)
                .frame(height: 18)
            Text(value)
                .font(.uiMetric)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.uiDetail)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct FlowChevron: View {
    let pointsRight: Bool
    let active: Bool

    var body: some View {
        Image(systemName: pointsRight ? "chevron.right" : "chevron.left")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(active ? .secondary : .quaternary)
    }
}

// MARK: - Rows and sections

/// A titled group of rows on one quiet layer.
struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs + 2) {
            Text(title)
                .font(.uiDetail.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, Space.xs)
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
        }
    }
}

/// A coloured symbol tile at the start of a row, like iOS and macOS Settings.
struct IconTile: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.white)
            .frame(width: 22, height: 22)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
    }
}

/// One settings row: an icon tile, a title with an optional explanation, and a control.
struct SettingRow<Accessory: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: Space.m - 2) {
            IconTile(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.uiRow)
                if let subtitle {
                    Text(subtitle)
                        .font(.uiDetail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Space.s)
            accessory()
        }
        .padding(.horizontal, Space.m - 2)
        .padding(.vertical, Space.s)
        .frame(minHeight: 40)
    }
}

struct ToggleRow: View {
    let symbol: String
    let tint: Color
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        SettingRow(symbol: symbol, tint: tint, title: title, subtitle: subtitle) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

/// A row that opens another page.
struct NavigationRow: View {
    let symbol: String
    let tint: Color
    let title: String
    var subtitle: String? = nil
    var trailing: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SettingRow(symbol: symbol, tint: tint, title: title, subtitle: subtitle) {
                HStack(spacing: Space.xs) {
                    if let trailing {
                        Text(trailing).font(.uiDetail).foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A value with the stepper that changes it.
struct StepperValue<Control: View>: View {
    let text: String
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(spacing: Space.s) {
            Text(text)
                .font(.uiRow)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            control()
        }
    }
}

/// Divider between rows that start with an icon tile.
struct RowDivider: View {
    var body: some View {
        Divider().padding(.leading, 42)
    }
}

/// Divider between plain rows.
struct InsetDivider: View {
    var body: some View {
        Divider().padding(.leading, Space.m)
    }
}

struct InfoRow: View {
    let title: String
    let value: String

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: Space.m)
            Text(value)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .textSelection(.enabled)
        }
        .font(.uiRow)
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s - 1)
    }
}

struct MetricColumn: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: Space.xxs) {
            Text(value)
                .font(.uiMetric)
                .monospacedDigit()
            Text(title)
                .font(.uiDetail)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// A collapsible block of monospaced text with a copy button (developer page).
struct DisclosureText: View {
    let title: String
    @Binding var isExpanded: Bool
    let text: String
    let onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: Space.xs + 2) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        Text(title).font(.uiRow)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                Button(action: onCopy) {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy")
            }
            if isExpanded {
                ScrollView {
                    Text(text.isEmpty ? "Nothing yet." : text)
                        .font(.uiCode)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 160)
                .padding(Space.s)
                .background(Color.primary.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            }
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
    }
}

// MARK: - Messages

struct NoticeCard: View {
    let systemImage: String
    let tint: Color
    let title: String?
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: Space.s + 2) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: Space.xxs) {
                if let title {
                    Text(title).font(.uiRow.weight(.semibold))
                }
                Text(message)
                    .font(.uiDetail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(Space.m)
        .messageSurface(tint)
    }
}

/// Shown instead of the controls when the app can't reach the helper.
struct HelperProblemCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let diagnosis = model.diagnosis
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.orange)
                Text(diagnosis?.summary ?? "Welll can't reach its helper")
                    .font(.uiSection)
            }
            Text(diagnosis?.advice ?? "Checking what's wrong…")
                .font(.uiDetail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let checks = diagnosis?.checks, !checks.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(checks, id: \.self) { line in
                        Text(line).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(.uiCode)
                .foregroundStyle(.secondary)
            }
            if let report = model.helperLoadReport {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("What macOS said").font(.uiDetail.weight(.semibold))
                    ScrollView {
                        Text(report)
                            .font(.uiCode)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 150)
                }
                .padding(Space.s + 2)
                .background(Color.primary.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            }
            HStack(spacing: Space.s) {
                if diagnosis?.state == .notInstalled && model.canInstallHelper {
                    Button("Install helper") { model.installHelper() }
                        .glassButton(prominent: true)
                        .tint(.accentColor)
                } else if diagnosis?.canRestart == true {
                    Button("Restart helper") { model.restartHelper() }
                        .glassButton(prominent: true)
                        .tint(.orange)
                }
                Button("Try again") { model.refresh() }
                    .glassButton()
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.helperLoadReport ?? "welllctl doctor", forType: .string)
                    model.show(model.helperLoadReport == nil
                               ? "Copied “welllctl doctor”. Paste it into Terminal for a full report."
                               : "Copied what macOS said.")
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .glassButton()
                .help("Copy the report, or a diagnostics command for Terminal")
            }
            if diagnosis?.suggestsLoginItems == true {
                Button("Open Login Items & Extensions") { model.openLoginItems() }
                    .buttonStyle(.link)
                    .font(.uiDetail)
            }
        }
        .padding(Space.m + 2)
        .messageSurface(.orange)
    }
}
