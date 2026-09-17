import Foundation
import IOKit
import IOKit.pwr_mgt

/// Tells the daemon when the Mac actually slept, rather than inferring it from a
/// gap in the wall clock.
///
/// The clock heuristic cannot do this job alone. Measured on a real machine, the
/// daemon's own scheduling stalls reached 99 seconds while genuine sleeps started
/// at 121, so no threshold separates them. Guessing too eagerly throws away real
/// Easy-Switch presses; guessing too late pushes the mouse after a wake.
public final class SleepMonitor {
    /// IOMessage.h builds these with a macro Swift cannot import. The values were
    /// taken from the SDK headers by compiling them, not written from memory.
    private enum PowerMessage {
        static let canSystemSleep: UInt32 = 0xE000_0270
        static let systemWillSleep: UInt32 = 0xE000_0280
        static let systemHasPoweredOn: UInt32 = 0xE000_0300
    }

    private var rootPort: io_connect_t = 0
    private var notifier: io_object_t = 0
    private var woke = false

    public private(set) var isActive = false

    public init(runLoop: CFRunLoop) {
        var notifyPort: IONotificationPortRef?
        // A deliberate permanent retain. IOKit holds this pointer for the life of
        // the process, so a released monitor would be a use-after-free in the
        // callback, which is the bug that already cost us a day.
        let context = Unmanaged.passRetained(self).toOpaque()
        rootPort = IORegisterForSystemPower(
            context,
            &notifyPort,
            { context, _, messageType, argument in
                guard let context else { return }
                Unmanaged<SleepMonitor>.fromOpaque(context)
                    .takeUnretainedValue()
                    .handle(messageType, argument)
            },
            &notifier)
        guard rootPort != 0, let notifyPort else { return }
        CFRunLoopAddSource(
            runLoop,
            IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue(),
            .defaultMode)
        isActive = true
    }

    /// True once per wake, then false until the next one.
    public func consumeWake() -> Bool {
        defer { woke = false }
        return woke
    }

    private func handle(_ messageType: UInt32, _ argument: UnsafeMutableRawPointer?) {
        switch messageType {
        case PowerMessage.canSystemSleep, PowerMessage.systemWillSleep:
            // Answer immediately. Staying silent holds the whole machine awake
            // for thirty seconds waiting on us.
            IOAllowPowerChange(rootPort, Int(bitPattern: argument))
        case PowerMessage.systemHasPoweredOn:
            woke = true
        default:
            break
        }
    }
}
