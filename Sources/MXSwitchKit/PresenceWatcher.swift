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

    public let pollInterval: Double
    public let absentPollsRequired: Int

    private var wasPresent: Bool?
    private var absentCount = 0
    private var lastPollTime: Double?

    public private(set) var lastResync = false

    public init(pollInterval: Double, absentPollsRequired: Int) {
        self.pollInterval = pollInterval
        self.absentPollsRequired = max(1, absentPollsRequired)
    }

    /// `now` must be wall clock. macOS pauses the monotonic clock across sleep,
    /// so only wall clock exposes the jump that separates a wake from a keypress.
    public mutating func feed(_ presence: Presence, now: Double) -> Bool {
        lastResync = false
        guard presence != .unknown else { return false }
        let present = presence == .present

        if let last = lastPollTime, now - last > Self.timeJumpFactor * pollInterval {
            lastPollTime = now
            wasPresent = present
            absentCount = 0
            lastResync = true
            return false
        }
        lastPollTime = now

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
