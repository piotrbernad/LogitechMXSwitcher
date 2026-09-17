import Foundation

/// What a presence poll learned. A transport failure is `unknown` and must never
/// be treated as `absent`, or a hiccup would fire a switch nobody asked for.
public enum Presence: Equatable, Sendable {
    case present
    case absent
    case unknown
}

/// Debounced present/absent edge detector with a sleep/wake guard.
///
/// `feed` returns true exactly when the keyboard was present and has then been
/// absent for `absentPollsRequired` consecutive polls. A wall-clock jump larger
/// than `timeJumpFactor` poll intervals means the Mac slept, so the state
/// resyncs without firing.
public struct PresenceWatcher: Sendable {
    public static let timeJumpFactor: Double = 5
    /// The clock is only a backstop now that real wakes arrive from IOKit. On a
    /// real machine this daemon's own scheduling stalls reached 99 seconds, so a
    /// tighter bound threw away genuine Easy-Switch presses.
    public static let minimumJump: Double = 120

    public let pollInterval: Double
    public let absentPollsRequired: Int

    private var wasPresent: Bool?
    private var absentCount = 0
    private var lastPollTime: Double?
    /// A jump seen while presence was unknown is held until a usable poll can
    /// consume it. Dropping it would let the first real poll after a sleep fire.
    private var pendingJump = false

    public private(set) var lastResync = false
    public private(set) var lastResyncGap: Double = 0

    public init(pollInterval: Double, absentPollsRequired: Int) {
        self.pollInterval = pollInterval
        self.absentPollsRequired = max(1, absentPollsRequired)
    }

    /// The Mac just woke. Resynchronise on the next usable poll instead of acting
    /// on a keyboard that is absent only because Bluetooth has not returned yet.
    public mutating func noteWake() {
        pendingJump = true
        lastResyncGap = 0
        lastPollTime = nil
    }

    /// Forget when the last poll happened, without touching presence state. The
    /// daemon calls this after work that blocks its own loop for many seconds, so
    /// its own slowness is not mistaken for the Mac having slept.
    public mutating func resetClock() {
        lastPollTime = nil
        pendingJump = false
    }

    /// `now` must be wall clock. macOS pauses the monotonic clock across sleep,
    /// so only wall clock exposes the jump that separates a wake from a keypress.
    public mutating func feed(_ presence: Presence, now: Double) -> Bool {
        lastResync = false
        let threshold = max(Self.timeJumpFactor * pollInterval, Self.minimumJump)
        if let last = lastPollTime, now - last > threshold {
            pendingJump = true
            lastResyncGap = now - last
        }
        lastPollTime = now

        guard presence != .unknown else { return false }
        let present = presence == .present

        if pendingJump {
            pendingJump = false
            wasPresent = present
            absentCount = 0
            lastResync = true
            return false
        }

        guard let previously = wasPresent else {
            wasPresent = present
            return false
        }
        if present {
            wasPresent = true
            absentCount = 0
            return false
        }
        guard previously else { return false }
        absentCount += 1
        guard absentCount >= absentPollsRequired else { return false }
        wasPresent = false
        absentCount = 0
        return true
    }
}
