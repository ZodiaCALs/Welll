import Foundation
import IOKit
import IOKit.pwr_mgt

/// Delivers sleep and wake notifications on the main run loop.
final class SleepMonitor {
    var onWillSleep: (() -> Void)?
    var onDidWake: (() -> Void)?

    private var rootPort: io_connect_t = 0
    private var notificationPort: IONotificationPortRef?
    private var notifier: io_object_t = 0

    // IOKit defines these with function-like macros, which Swift can't import.
    private enum Message {
        static let canSystemSleep: UInt32 = 0xE000_0270
        static let systemWillSleep: UInt32 = 0xE000_0280
        static let systemWillNotSleep: UInt32 = 0xE000_0290
        static let systemHasPoweredOn: UInt32 = 0xE000_0300
    }

    func start() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(context, &notificationPort, { context, _, messageType, argument in
            guard let context else { return }
            Unmanaged<SleepMonitor>.fromOpaque(context).takeUnretainedValue().handle(messageType, argument)
        }, &notifier)
        guard rootPort != 0, let port = notificationPort else {
            Log.daemon.error("Couldn't register for sleep and wake notifications")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .commonModes)
    }

    private func handle(_ messageType: UInt32, _ argument: UnsafeMutableRawPointer?) {
        switch messageType {
        case Message.canSystemSleep:
            IOAllowPowerChange(rootPort, Int(bitPattern: argument))
        case Message.systemWillSleep:
            onWillSleep?()
            IOAllowPowerChange(rootPort, Int(bitPattern: argument))
        case Message.systemWillNotSleep, Message.systemHasPoweredOn:
            onDidWake?()
        default:
            break
        }
    }
}

/// Keeps the Mac from idle-sleeping while Welll needs to watch the battery.
final class SleepAssertion {
    private var assertionID: IOPMAssertionID = 0
    private(set) var isHeld = false

    func set(_ hold: Bool) {
        guard hold != isHeld else { return }
        if hold {
            var newID: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Welll is managing battery charging" as CFString,
                &newID)
            if result == kIOReturnSuccess {
                assertionID = newID
                isHeld = true
            }
        } else {
            IOPMAssertionRelease(assertionID)
            isHeld = false
        }
    }
}
