import Foundation
import MXSwitchKit

/// The watch loop. Config is re-read every tick so the menu bar app can change
/// settings without a restart, and the presence state machine is only rebuilt
/// when its own parameters change, so edits elsewhere never lose the debounce.
final class Daemon {
    private let store: StateStore
    private let transport: HIDTransport
    private let log: Log
    private let switcher: Switcher
    private let sleepMonitor: SleepMonitor

    private var watcher: PresenceWatcher
    private var watcherParameters: (poll: Double, absent: Int)
    private var acknowledgedCommand = 0
    private var lastEvent: String?
    private var lastEventAt: Date?
    private var probedHosts: [ProbedHost]?
    private var accessDenied = false
    private var lastAccessCheck: Date?
    private var pendingReason = "not configured yet"

    init(store: StateStore, transport: HIDTransport, log: Log) {
        self.store = store
        self.transport = transport
        self.log = log
        switcher = Switcher(transport: transport, log: { log($0) })
        sleepMonitor = SleepMonitor(runLoop: CFRunLoopGetCurrent())
        let config = store.loadConfig() ?? Config()
        watcherParameters = (config.pollInterval, config.absentPollsRequired)
        watcher = PresenceWatcher(
            pollInterval: config.pollInterval,
            absentPollsRequired: config.absentPollsRequired)
        acknowledgedCommand = store.loadCommand()?.id ?? 0
        probedHosts = store.loadStatus()?.probedHosts
    }

    func run() {
        log("mxswitchd started, state directory \(store.directory.path), euid \(geteuid())")
        if !sleepMonitor.isActive {
            log("could not register for sleep and wake notifications, falling back to the clock")
        }
        while true {
            let config = store.loadConfig() ?? Config()
            if sleepMonitor.consumeWake() {
                log("the Mac woke, presence will resync without switching")
                watcher.noteWake()
            }
            resyncWatcher(with: config)
            refreshAccessCheck(config)
            runPendingCommand(config)
            let health = tick(config)
            publish(config, health: health)
            Thread.sleep(forTimeInterval: max(0.2, config.pollInterval))
        }
    }

    private func resyncWatcher(with config: Config) {
        let parameters = (config.pollInterval, config.absentPollsRequired)
        guard parameters != watcherParameters else { return }
        watcherParameters = parameters
        watcher = PresenceWatcher(
            pollInterval: config.pollInterval,
            absentPollsRequired: config.absentPollsRequired)
        log("poll settings changed, presence state reset")
    }

    /// Report a missing Input Monitoring grant at startup rather than letting the
    /// user discover it when their first Easy-Switch press goes nowhere. Retried
    /// every minute so the daemon recovers on its own once the grant is given.
    private func refreshAccessCheck(_ config: Config) {
        guard let mouse = config.mouse else { return }
        let due = lastAccessCheck.map { Date().timeIntervalSince($0) > 60 } ?? true
        guard due else { return }
        lastAccessCheck = Date()
        switch switcher.checkAccess(to: mouse) {
        case .denied:
            if !accessDenied { note("Input Monitoring is not granted to this service") }
            accessDenied = true
        case .ok:
            if accessDenied { note("HID++ access restored") }
            accessDenied = false
        case .deviceUnreachable:
            break
        }
    }

    private func tick(_ config: Config) -> DaemonStatus.Health {
        guard config.enabled else { return .paused }
        guard case .ready(let keyboard, let mouse, let target) = config.readiness else {
            if case .notReady(let reason) = config.readiness { pendingReason = reason }
            return .misconfigured
        }
        if accessDenied { return .permissionDenied }
        let presence = transport.presence(of: keyboard)
        guard watcher.feed(presence, now: Date().timeIntervalSince1970) else {
            if watcher.lastResync {
                log(String(format: "wall clock jumped %.0fs, presence resynced without switching",
                           watcher.lastResyncGap))
            }
            return .watching
        }
        log("keyboard left this Mac, sending \(mouse.name) to key \(target.keyLabel)")
        let outcome = switcher.push(
            mouse, to: target, budget: config.sendBudget,
            sleepAbort: config.sleepAbort, confirmDelay: config.confirmDelay)
        record(outcome, device: mouse, target: target)
        // A push can block this loop for the whole budget. That is our own
        // slowness, not the Mac sleeping, so do not let the next poll read it as one.
        watcher.resetClock()
        return outcome == .denied ? .permissionDenied : .watching
    }

    private func runPendingCommand(_ config: Config) {
        guard let command = store.loadCommand(), command.id > acknowledgedCommand else { return }
        acknowledgedCommand = command.id
        // Commands talk to hardware and can take tens of seconds.
        defer { watcher.resetClock() }
        switch command.kind {
        case .restart:
            note("restarting to pick up a permission change")
            try? store.saveStatus(DaemonStatus(
                health: .paused, detail: "Restarting\u{2026}",
                lastEvent: lastEvent, lastEventAt: lastEventAt,
                probedHosts: probedHosts, acknowledgedCommand: acknowledgedCommand))
            exit(0)

        case .probeHosts:
            guard let keyboard = config.keyboard else {
                note("cannot read Easy-Switch names: no keyboard selected")
                return
            }
            log("reading Easy-Switch slot names from \(keyboard.name)")
            if let hosts = switcher.probeHosts(on: keyboard) {
                probedHosts = hosts
                note("read \(hosts.count) Easy-Switch slots from \(keyboard.name)")
            } else {
                note("could not read Easy-Switch names from \(keyboard.name)")
            }

        case .switchMouse, .switchBoth:
            guard let target = command.target ?? config.targetHost else {
                note("no target slot for the requested switch")
                return
            }
            // The mouse goes first: it is the device most likely to be asleep, and
            // a failure there is worth knowing before the keyboard leaves too.
            if let mouse = config.mouse {
                record(pushed(mouse, to: target, config), device: mouse, target: target)
            }
            if command.kind == .switchBoth, let keyboard = config.keyboard {
                record(pushed(keyboard, to: target, config), device: keyboard, target: target)
            }
        }
    }

    private func pushed(_ device: DeviceRef, to target: HostSlot, _ config: Config) -> PushOutcome {
        switcher.push(
            device, to: target, budget: config.sendBudget,
            sleepAbort: config.sleepAbort, confirmDelay: config.confirmDelay)
    }

    private func record(_ outcome: PushOutcome, device: DeviceRef, target: HostSlot) {
        switch outcome {
        case .switched: note("\(device.name) switched to key \(target.keyLabel)")
        case .alreadyOnTarget: note("\(device.name) was already on key \(target.keyLabel)")
        case .denied: note("permission denied: grant Input Monitoring to mxswitchd")
        case .targetOutOfRange(let available): note("key \(target.keyLabel) is not paired (\(device.name) reports \(available) slots)")
        case .abortedForSleep: note("aborted: the Mac slept mid-switch")
        case .notOnThisMac:
            note("\(device.name) is not connected to this Mac, so it cannot be moved from here. "
                + "Install MX Switch on the other Mac so it can send the mouse back.")
        case .gaveUp(let attempts): note("\(device.name) did not move after \(attempts) attempts")
        }
    }

    private func note(_ message: String) {
        log(message)
        lastEvent = message
        lastEventAt = Date()
    }

    private func publish(_ config: Config, health: DaemonStatus.Health) {
        let status = DaemonStatus(
            health: health,
            detail: detail(for: health, config: config),
            keyboardPresent: config.keyboard.map { transport.presence(of: $0) == .present },
            mousePresent: config.mouse.map { transport.presence(of: $0) == .present },
            lastEvent: lastEvent,
            lastEventAt: lastEventAt,
            probedHosts: probedHosts,
            acknowledgedCommand: acknowledgedCommand)
        try? store.saveStatus(status)
    }

    private func detail(for health: DaemonStatus.Health, config: Config) -> String {
        switch health {
        case .paused:
            return "Switching is off"
        case .misconfigured:
            return pendingReason.prefix(1).uppercased() + pendingReason.dropFirst()
        case .permissionDenied:
            return "Input Monitoring is not granted to the background service"
        case .watching:
            guard let target = config.targetHost else { return "Watching" }
            return "Sends the mouse to \(config.displayName(for: target))"
        }
    }
}
