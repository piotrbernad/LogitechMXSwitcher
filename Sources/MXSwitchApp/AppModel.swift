import Foundation
import Combine
import MXSwitchKit

/// The menu bar app's whole state. It owns the config file; the daemon owns the
/// status file. Nothing else is shared, so neither side can clobber the other.
@MainActor
final class AppModel: ObservableObject {
    @Published var config: Config
    @Published var status: DaemonStatus?
    @Published var devices: [HIDDeviceInfo] = []
    @Published var serviceInstalled: Bool = false

    let store: StateStore
    private let transport = HIDTransport()
    private var nextCommandID: Int

    init(store: StateStore = .userDefault) {
        self.store = store
        config = store.loadConfig() ?? Config()
        nextCommandID = (store.loadCommand()?.id ?? 0) + 1
        refresh()
        if config.keyboard == nil || config.mouse == nil { adoptDetectedDevices() }
    }

    // MARK: reading the world

    func refresh() {
        devices = transport.enumerateDistinct()
        status = store.loadStatus()
        serviceInstalled = ServiceInstaller.isInstalled
        if let probed = status?.probedHosts { adoptProbedNames(probed) }
    }

    /// Logitech devices that speak HID++. Anything else cannot be switched, so
    /// offering it in the picker would only invite a misconfiguration.
    var switchableDevices: [HIDDeviceInfo] {
        devices.filter(\.hasHIDPPInterface)
    }

    var keyboardCandidates: [HIDDeviceInfo] {
        switchableDevices.filter { $0.usagePage == 0x01 && $0.usage == 0x06 }
    }

    var mouseCandidates: [HIDDeviceInfo] {
        switchableDevices.filter { $0.usagePage == 0x01 && $0.usage == 0x02 }
    }

    /// Pre-fill the pickers on first launch so the common case needs no choices.
    private func adoptDetectedDevices() {
        if config.keyboard == nil { config.keyboard = keyboardCandidates.first?.ref }
        if config.mouse == nil { config.mouse = mouseCandidates.first?.ref }
        if config.keyboard != nil || config.mouse != nil { save() }
    }

    private func adoptProbedNames(_ probed: [ProbedHost]) {
        var names = config.hostNames
        while names.count < HostSlot.count { names.append("") }
        var changed = false
        for host in probed where host.slot < names.count && !host.name.isEmpty {
            if names[host.slot] != host.name {
                names[host.slot] = host.name
                changed = true
            }
        }
        // The slot the keyboard reports as current is the one this Mac sits on.
        if let current = probed.first(where: \.isCurrent), let slot = HostSlot(index: current.slot),
           config.thisHost != slot {
            config.thisHost = slot
            if config.targetHost == nil || config.targetHost == slot {
                config.targetHost = otherPairedSlot(besides: slot, in: probed)
            }
            changed = true
        }
        guard changed else { return }
        config.hostNames = names
        save()
    }

    private func otherPairedSlot(besides slot: HostSlot, in probed: [ProbedHost]) -> HostSlot? {
        probed
            .filter { $0.paired && $0.slot != slot.index }
            .compactMap { HostSlot(index: $0.slot) }
            .first
    }

    // MARK: writing

    func save() {
        try? store.saveConfig(config)
    }

    func send(_ kind: Command.Kind, target: HostSlot? = nil) {
        let command = Command(id: nextCommandID, kind: kind, target: target)
        nextCommandID += 1
        try? store.saveCommand(command)
    }

    // MARK: derived labels

    var headline: String {
        guard serviceInstalled else { return "Background service not installed" }
        guard let status else { return "Starting…" }
        switch status.health {
        case .watching: return "Watching \(config.keyboard?.name ?? "keyboard")"
        case .paused: return "Paused"
        case .misconfigured: return "Needs setup"
        case .permissionDenied: return "Needs Input Monitoring"
        }
    }

    var detail: String {
        guard serviceInstalled else { return "Open Settings to install it." }
        guard let status else { return "Waiting for the background service to report in." }
        if status.updatedAt.timeIntervalSinceNow < -30 {
            return "The background service has not reported in for a while."
        }
        return status.detail
    }

    var isConfigured: Bool {
        if case .ready = config.readiness { return true }
        return false
    }

    var configurationProblem: String? {
        if case .notReady(let reason) = config.readiness { return reason }
        return nil
    }

    var isHealthy: Bool {
        guard serviceInstalled, let status else { return false }
        return status.health == .watching && status.updatedAt.timeIntervalSinceNow > -30
    }

    var otherMacName: String {
        guard let target = config.targetHost else { return "the other Mac" }
        return config.displayName(for: target)
    }
}
