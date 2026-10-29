import Foundation
import Combine
import IOKit.ps
import ServiceManagement
import WelllCore

struct MenuBarState: Equatable {
    var percent: Int?
    var limit: Int?
    var charging = false
    var pluggedIn = false
    var lowPower = false
    var problem = false
    var showPercent = true
    var showLimitMarker = false
    var tooltip = "Welll"
}

/// Everything the menu bar UI shows, kept in sync with the daemon.
final class AppModel: ObservableObject {
    @Published private(set) var status: WelllStatus?
    @Published private(set) var settings = WelllSettings()
    @Published private(set) var connectionProblem: String?
    @Published private(set) var diagnosis: HelperDiagnosis?
    /// What macOS said the last time the helper couldn't be loaded or installed.
    @Published private(set) var helperLoadReport: String?
    @Published private(set) var notice: String?
    @Published private(set) var menuBarState = MenuBarState()
    @Published private(set) var developerUnlocked = false
    /// The result of the last developer action.
    @Published private(set) var developerOutput: String?
    /// Counts the readings that arrive while the window is open, so views can follow along.
    @Published private(set) var liveTick = 0
    @Published private(set) var popoverVisible = false

    @Published var showPercentInMenuBar: Bool {
        didSet { save(showPercentInMenuBar, Keys.showPercent); refreshMenuBar() }
    }
    @Published var showLimitMarker: Bool {
        didSet { save(showLimitMarker, Keys.limitMarker); refreshMenuBar() }
    }
    /// Seconds between readings while the window is open (the power monitor).
    @Published var liveInterval: Double {
        didSet { save(liveInterval, Keys.liveInterval); schedulePolling() }
    }
    /// Seconds between readings in the background (the menu bar icon).
    @Published var backgroundInterval: Double {
        didSet { save(backgroundInterval, Keys.backgroundInterval); schedulePolling() }
    }

    static let liveIntervals: [Double] = [1, 2, 5, 10]
    static let backgroundIntervals: [Double] = [15, 30, 60, 120]

    static func describe(interval: Double) -> String {
        interval >= 60 ? "\(Int(interval / 60)) min" : "\(Int(interval)) s"
    }

    private enum Keys {
        static let showPercent = "showPercentInMenuBar"
        static let limitMarker = "showLimitMarker"
        static let liveInterval = "liveInterval"
        static let backgroundInterval = "backgroundInterval"
        static let all = [showPercent, limitMarker, liveInterval, backgroundInterval]
    }

    private let client = DaemonClient()
    private var timer: Timer?
    private var popoverOpen = false
    private var pendingSettingsWrites = 0
    private var diagnosing = false
    private var clearNotice: DispatchWorkItem?
    private var powerStateObserver: NSObjectProtocol?

    init() {
        let defaults = UserDefaults.standard
        showPercentInMenuBar = defaults.object(forKey: Keys.showPercent) as? Bool ?? true
        showLimitMarker = defaults.object(forKey: Keys.limitMarker) as? Bool ?? false
        liveInterval = defaults.object(forKey: Keys.liveInterval) as? Double ?? 2
        backgroundInterval = defaults.object(forKey: Keys.backgroundInterval) as? Double ?? 30
    }

    private func save(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    // MARK: - Derived values

    var isConnected: Bool { status != nil }
    var battery: BatterySnapshot? { status?.battery }
    var mode: ChargeMode { status?.mode ?? .normal }
    var features: FeatureSupport { status?.features ?? FeatureSupport() }
    var hardware: HardwareInfo? { status?.hardware }
    var displayPercent: Int? { status?.effectivePercent }
    var isCharging: Bool { battery?.isCharging ?? false }
    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    var headline: String {
        if connectionProblem != nil { return "The helper isn't running" }
        return status?.headline ?? "Connecting…"
    }

    var detail: String? { connectionProblem == nil ? status?.detail : nil }

    /// The installer inside the app bundle (builds made with Scripts/build-app.sh).
    private var bundledInstaller: String? {
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/install-helper.sh").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    var canInstallHelper: Bool { bundledInstaller != nil }

    var statusJSON: String {
        guard let status else { return "{}" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(status) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    func helperLogTail(lines: Int = 80) -> String {
        guard let text = try? String(contentsOfFile: HelperDiagnostics.logPath, encoding: .utf8) else {
            return "There's no log at \(HelperDiagnostics.logPath) yet."
        }
        return text.split(separator: "\n").suffix(lines).joined(separator: "\n")
    }

    // MARK: - Lifecycle

    func start() {
        refresh()
        schedulePolling()
        observePowerSources()
        powerStateObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshMenuBar()
        }
    }

    func popoverWillShow() {
        popoverOpen = true
        popoverVisible = true
        refresh()
        schedulePolling()
    }

    func popoverDidClose() {
        popoverOpen = false
        popoverVisible = false
        schedulePolling()
    }

    func refresh() {
        client.fetchStatus { [weak self] result in self?.handle(result) }
    }

    private func schedulePolling() {
        timer?.invalidate()
        let interval = popoverOpen ? liveInterval : backgroundInterval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.refresh() }
        timer.tolerance = interval / 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Refresh straight away when a charger is plugged in or removed.
    private func observePowerSources() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            Unmanaged<AppModel>.fromOpaque(context).takeUnretainedValue().refresh()
        }
        guard let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    // MARK: - Changes

    func update(_ change: (inout WelllSettings) -> Void) {
        var updated = settings
        change(&updated)
        guard updated != settings else { return }
        settings = updated
        pendingSettingsWrites += 1
        client.updateSettings(updated) { [weak self] result in
            guard let self else { return }
            self.pendingSettingsWrites -= 1
            self.handle(result)
        }
    }

    func setMode(_ newMode: ChargeMode) {
        client.setMode(newMode) { [weak self] result in self?.handle(result) }
    }

    func toggle(_ target: ChargeMode) {
        setMode(mode == target ? .normal : target)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            show("Couldn't change the login item: \(error.localizedDescription) Add Welll in System Settings › General › Login Items instead.")
        }
        objectWillChange.send()
    }

    func show(_ message: String) {
        notice = message
        clearNotice?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.notice = nil }
        clearNotice = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    func resetAppPreferences() {
        Keys.all.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        showPercentInMenuBar = true
        showLimitMarker = false
        liveInterval = 2
        backgroundInterval = 30
        show("App preferences are back to their defaults.")
    }

    // MARK: - Helper installation

    /// Loads the helper with launchd, through the root-owned loader. macOS asks for a password.
    @MainActor
    func restartHelper() {
        let command: String
        if FileManager.default.isExecutableFile(atPath: HelperDiagnostics.loaderPath) {
            command = Self.shellQuote(HelperDiagnostics.loaderPath)
        } else {
            // Installs from before the loader existed.
            let label = HelperDiagnostics.label
            let plist = HelperDiagnostics.plistPath
            command = "/bin/launchctl bootout system/\(label) 2>/dev/null; sleep 1; "
                + "/bin/launchctl enable system/\(label); "
                + "/bin/launchctl bootstrap system \(plist) || /bin/launchctl load -w \(plist); "
                + "sleep 1; /bin/launchctl print system/\(label) >/dev/null"
        }
        finishHelperChange(runPrivileged(command), success: "The helper is loaded.")
    }

    /// Installs or updates the helper from this app bundle (disk image builds).
    @MainActor
    func installHelper() {
        guard let installer = bundledInstaller else {
            helperLoadReport = "This copy of Welll doesn't include the helper. Build it with install.sh or release.sh."
            return
        }
        // Never run a modified bundle with administrator rights.
        let verify = HelperDiagnostics.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", Bundle.main.bundlePath],
                                           timeout: 30)
        guard verify?.status == 0 else {
            helperLoadReport = "Welll's app bundle changed after it was signed, so it won't install the helper from it. Download or build Welll again."
            return
        }
        finishHelperChange(runPrivileged(Self.shellQuote(installer)), success: "The helper is installed.")
    }

    @MainActor
    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    @MainActor
    private func finishHelperChange(_ result: PrivilegedResult, success: String) {
        switch result {
        case .success:
            helperLoadReport = nil
            show(success)
        case .cancelled:
            return
        case .failure(let message):
            helperLoadReport = message
        }
        diagnosis = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.refresh() }
    }

    enum PrivilegedResult {
        case success(String)
        case cancelled
        case failure(String)
    }

    /// Runs a shell command as root through the standard macOS password prompt.
    @MainActor
    private func runPrivileged(_ command: String) -> PrivilegedResult {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        var error: NSDictionary?
        let script = NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")
        let output = script?.executeAndReturnError(&error)
        if let error {
            // -128 means the password prompt was cancelled.
            if (error["NSAppleScriptErrorNumber"] as? Int) == -128 { return .cancelled }
            return .failure(error["NSAppleScriptErrorMessage"] as? String ?? "The command failed.")
        }
        return .success(output?.stringValue ?? "")
    }

    private static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Developer options

    func unlockDeveloperOptions() {
        developerUnlocked = true
    }

    func lockDeveloperOptions() {
        developerUnlocked = false
        developerOutput = nil
    }

    func developerCommand(_ command: String, _ value: String = "") {
        client.developerCommand(command, value: value) { [weak self] output, error in
            guard let self else { return }
            self.developerOutput = error ?? output
            self.refresh()
        }
    }

    /// Runs the helper's self-test as root and shows what it printed.
    @MainActor
    func runSelfTest() {
        switch runPrivileged(Self.shellQuote(HelperDiagnostics.helperPath) + " --self-test") {
        case .success(let output):
            developerOutput = output.isEmpty ? "The self-test printed nothing." : output
        case .cancelled:
            break
        case .failure(let message):
            developerOutput = message
        }
    }

    // MARK: - Replies

    private func handle(_ result: Result<WelllStatus, DaemonClient.Failure>) {
        switch result {
        case .success(let newStatus):
            accept(newStatus)
            if popoverOpen { liveTick &+= 1 }
        case .failure(.rejected(let message, let newStatus)):
            if let newStatus { accept(newStatus) }
            show(message)
        case .failure(.unreachable(let message)):
            status = nil
            connectionProblem = message
            diagnoseHelper()
        case .failure(.badReply):
            connectionProblem = "The app and the helper are different versions. Run install.sh again."
        }
        refreshMenuBar()
    }

    private func accept(_ newStatus: WelllStatus) {
        status = newStatus
        connectionProblem = nil
        diagnosis = nil
        helperLoadReport = nil
        if pendingSettingsWrites == 0 { settings = newStatus.settings }
    }

    /// Works out why the helper can't be reached, off the main thread.
    private func diagnoseHelper() {
        guard !diagnosing else { return }
        diagnosing = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = HelperDiagnostics.diagnose()
            DispatchQueue.main.async {
                guard let self else { return }
                self.diagnosing = false
                if self.connectionProblem != nil { self.diagnosis = result }
            }
        }
    }

    private func refreshMenuBar() {
        var state = MenuBarState()
        state.problem = connectionProblem != nil
        state.percent = displayPercent
        state.charging = isCharging
        state.pluggedIn = battery?.externalConnected == true || status?.adapterCutOff == true
        state.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        state.limit = status?.effectiveLimit
        state.showPercent = showPercentInMenuBar
        state.showLimitMarker = showLimitMarker
        state.tooltip = ["Welll", headline, detail].compactMap { $0 }.joined(separator: "\n")
        if state != menuBarState { menuBarState = state }
    }
}
