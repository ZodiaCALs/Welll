import Foundation

public enum WelllConstants {
    public static let version = "2.0.0"
    /// Mach service the LaunchDaemon publishes for the app and the command-line tool.
    public static let machServiceName = "local.welll.daemon"

    public static let minimumLimit = 20
    public static let maximumLimit = 100
    /// macOS's own Charge Limit goes no lower than this, in steps of `macOSLimitStep`.
    public static let macOSMinimumLimit = 80
    public static let macOSLimitStep = 5

    /// Welll never runs the battery lower than this while plugged in.
    public static let dischargeFloor = 10
    public static let calibrationLowPercent = 15
    public static let calibrationHoldSeconds: TimeInterval = 60 * 60
    /// Charging resumes this many °C below the heat-protection threshold.
    public static let heatHysteresis = 2.0
    /// Smallest gap between switching wall power off and back on, to limit cycling.
    public static let minimumAdapterBand = 3
}
