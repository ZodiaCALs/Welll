import AppKit
import Darwin

struct EnergyUser: Identifiable, Equatable {
    let id: pid_t
    let name: String
    let icon: NSImage?
    /// Average watts since the last sample, when macOS bills energy (Apple silicon).
    let watts: Double?
    let cpuPercent: Double

    var label: String {
        if let watts { return String(format: "%.1f W", watts) }
        return String(format: "%.0f%% CPU", cpuPercent)
    }
}

/// Finds the apps using significant energy from the energy macOS bills to each process, like
/// the battery menu does. It samples only while the window is open, so it costs nothing
/// otherwise.
@MainActor
final class EnergyMonitor: ObservableObject {
    @Published private(set) var users: [EnergyUser] = []
    /// False until two samples exist to compare.
    @Published private(set) var ready = false

    /// Apps averaging at least this much count as significant.
    static let wattsThreshold = 1.0
    static let cpuThreshold = 25.0

    private struct Sample {
        let energy: UInt64
        let cpu: UInt64
        let time: UInt64
    }

    private var previous: [pid_t: Sample] = [:]
    private let ticksToSeconds: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    func sample() {
        let now = mach_absolute_time()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var next: [pid_t: Sample] = [:]
        var found: [EnergyUser] = []
        var compared = false

        for app in NSWorkspace.shared.runningApplications where app.activationPolicy != .prohibited {
            let pid = app.processIdentifier
            guard pid > 0, pid != ownPID, let usage = Self.usage(of: pid) else { continue }
            let current = Sample(energy: usage.energy, cpu: usage.cpu, time: now)
            next[pid] = current
            guard let before = previous[pid], current.time > before.time else { continue }
            let seconds = Double(current.time - before.time) * ticksToSeconds
            guard seconds > 0.2 else { continue }
            compared = true

            let joules = current.energy >= before.energy ? Double(current.energy - before.energy) / 1_000_000_000 : 0
            let cpuSeconds = current.cpu >= before.cpu ? Double(current.cpu - before.cpu) * ticksToSeconds : 0
            let watts = joules / seconds
            let cpuPercent = cpuSeconds / seconds * 100
            let billsEnergy = current.energy > 0
            guard billsEnergy ? watts >= Self.wattsThreshold : cpuPercent >= Self.cpuThreshold else { continue }
            found.append(EnergyUser(id: pid, name: app.localizedName ?? "Unknown", icon: app.icon,
                                    watts: billsEnergy ? watts : nil, cpuPercent: cpuPercent))
        }

        previous = next
        if compared { ready = true }
        let sorted = found.sorted { ($0.watts ?? $0.cpuPercent / 25) > ($1.watts ?? $1.cpuPercent / 25) }
        if sorted != users { users = sorted }
    }

    /// Forget old samples, so a reopened window doesn't average over the time it was closed.
    func reset() {
        previous = [:]
        ready = false
    }

    /// Billed energy (nanojoules) and CPU time (Mach ticks) for one process.
    private static func usage(of pid: pid_t) -> (energy: UInt64, cpu: UInt64)? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
            }
        }
        guard result == 0 else { return nil }
        return (info.ri_billed_energy, info.ri_user_time + info.ri_system_time)
    }
}
