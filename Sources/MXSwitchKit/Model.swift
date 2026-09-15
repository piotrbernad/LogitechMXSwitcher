import Foundation

/// A paired Logitech device, identified the way HID enumeration identifies it.
public struct DeviceRef: Codable, Hashable, Sendable {
    public var vendorID: UInt16
    public var productID: UInt16
    public var name: String

    public init(vendorID: UInt16, productID: UInt16, name: String) {
        self.vendorID = vendorID
        self.productID = productID
        self.name = name
    }

    public var vidpid: String {
        String(format: "%04X:%04X", vendorID, productID)
    }
}

/// An Easy-Switch channel. Stored 0-based as the HID++ wire format wants it;
/// `keyLabel` is the 1-based number printed on the keycap.
public struct HostSlot: Codable, Hashable, Comparable, Sendable {
    public static let count = 3
    public static let all = (0..<count).map { HostSlot(unchecked: $0) }

    public let index: Int

    private init(unchecked index: Int) { self.index = index }

    public init?(index: Int) {
        guard (0..<HostSlot.count).contains(index) else { return nil }
        self.index = index
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(Int.self)
        guard let slot = HostSlot(index: raw) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Easy-Switch slot \(raw) is outside 0...\(HostSlot.count - 1)"))
        }
        self = slot
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(index)
    }

    public var keyLabel: String { "\(index + 1)" }

    public static func < (lhs: HostSlot, rhs: HostSlot) -> Bool { lhs.index < rhs.index }
}

/// Everything the daemon needs. Written by the menu bar app, read by the daemon.
public struct Config: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var keyboard: DeviceRef?
    public var mouse: DeviceRef?
    /// The slot this Mac occupies. Used to label the UI and to reject a target equal to it.
    public var thisHost: HostSlot?
    /// Where the mouse is pushed when the keyboard leaves this Mac.
    public var targetHost: HostSlot?
    public var hostNames: [String]
    public var pollInterval: Double
    public var absentPollsRequired: Int
    public var sendBudget: Double
    public var sleepAbort: Double
    public var confirmDelay: Double

    public init(
        enabled: Bool = true,
        keyboard: DeviceRef? = nil,
        mouse: DeviceRef? = nil,
        thisHost: HostSlot? = nil,
        targetHost: HostSlot? = nil,
        hostNames: [String] = ["", "", ""],
        pollInterval: Double = 1.0,
        absentPollsRequired: Int = 2,
        sendBudget: Double = 35.0,
        sleepAbort: Double = 30.0,
        confirmDelay: Double = 1.0
    ) {
        self.enabled = enabled
        self.keyboard = keyboard
        self.mouse = mouse
        self.thisHost = thisHost
        self.targetHost = targetHost
        self.hostNames = hostNames
        self.pollInterval = pollInterval
        self.absentPollsRequired = absentPollsRequired
        self.sendBudget = sendBudget
        self.sleepAbort = sleepAbort
        self.confirmDelay = confirmDelay
    }

    /// The daemon refuses to watch until every required field is set and coherent.
    public enum Readiness: Equatable, Sendable {
        case ready(keyboard: DeviceRef, mouse: DeviceRef, target: HostSlot)
        case notReady(String)
    }

    public var readiness: Readiness {
        guard let keyboard else { return .notReady("no keyboard selected") }
        guard let mouse else { return .notReady("no mouse selected") }
        guard let targetHost else { return .notReady("no target Easy-Switch slot selected") }
        if let thisHost, thisHost == targetHost {
            return .notReady("this Mac and the other Mac are both on slot \(targetHost.keyLabel)")
        }
        return .ready(keyboard: keyboard, mouse: mouse, target: targetHost)
    }

    public func displayName(for slot: HostSlot) -> String {
        let name = hostNames.indices.contains(slot.index) ? hostNames[slot.index] : ""
        return name.isEmpty ? "Key \(slot.keyLabel)" : name
    }
}

/// What the daemon last saw. Written by the daemon, read by the menu bar app.
public struct DaemonStatus: Codable, Equatable, Sendable {
    public enum Health: String, Codable, Sendable {
        case watching, paused, misconfigured, permissionDenied
    }

    public var health: Health
    public var detail: String
    public var updatedAt: Date
    public var keyboardPresent: Bool?
    public var mousePresent: Bool?
    public var lastEvent: String?
    public var lastEventAt: Date?
    public var probedHosts: [ProbedHost]?
    public var acknowledgedCommand: Int

    public init(
        health: Health,
        detail: String,
        updatedAt: Date = Date(),
        keyboardPresent: Bool? = nil,
        mousePresent: Bool? = nil,
        lastEvent: String? = nil,
        lastEventAt: Date? = nil,
        probedHosts: [ProbedHost]? = nil,
        acknowledgedCommand: Int = 0
    ) {
        self.health = health
        self.detail = detail
        self.updatedAt = updatedAt
        self.keyboardPresent = keyboardPresent
        self.mousePresent = mousePresent
        self.lastEvent = lastEvent
        self.lastEventAt = lastEventAt
        self.probedHosts = probedHosts
        self.acknowledgedCommand = acknowledgedCommand
    }
}

public struct ProbedHost: Codable, Equatable, Sendable {
    public var slot: Int
    public var paired: Bool
    public var name: String
    public var isCurrent: Bool

    public init(slot: Int, paired: Bool, name: String, isCurrent: Bool) {
        self.slot = slot
        self.paired = paired
        self.name = name
        self.isCurrent = isCurrent
    }
}

/// A one-shot request from the menu bar app. The daemon runs it when `id`
/// exceeds the id it last acknowledged, so a re-read of the same file is a no-op.
public struct Command: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case switchMouse
        case switchBoth
        case probeHosts
        /// Quit so launchd starts a fresh process. macOS caches a TCC decision for
        /// the life of a process, so a new Input Monitoring grant needs a new one.
        case restart
    }

    public var id: Int
    public var kind: Kind
    public var target: HostSlot?

    public init(id: Int, kind: Kind, target: HostSlot? = nil) {
        self.id = id
        self.kind = kind
        self.target = target
    }
}
