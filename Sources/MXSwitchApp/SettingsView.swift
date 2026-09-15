import SwiftUI
import MXSwitchKit

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var installError: String?
    @State private var busy = false

    var body: some View {
        Form {
            Section("Devices") {
                devicePicker(
                    "Keyboard", selection: keyboardBinding,
                    options: model.keyboardCandidates,
                    empty: "No Logitech keyboard with Easy-Switch found")
                devicePicker(
                    "Mouse", selection: mouseBinding,
                    options: model.mouseCandidates,
                    empty: "No Logitech mouse with Easy-Switch found")
                HStack {
                    Spacer()
                    Button("Rescan") { model.refresh() }
                }
            }

            Section("Computers") {
                slotPicker("This Mac", selection: thisHostBinding)
                slotPicker("Other Mac", selection: targetHostBinding)
                LabeledContent("") {
                    VStack(alignment: .leading, spacing: 6) {
                        Button("Read Names From Keyboard") {
                            model.send(.probeHosts)
                        }
                        .disabled(!model.serviceInstalled)
                        Text(namesHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Background Service") {
                LabeledContent("Status") {
                    Label(model.headline, systemImage: model.isHealthy ? "checkmark.circle" : "exclamationmark.circle")
                        .foregroundStyle(model.isHealthy ? Color.green : Color.orange)
                }
                LabeledContent("") {
                    Text(model.detail).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(model.serviceInstalled ? "Reinstall\u{2026}" : "Install\u{2026}") { install() }
                        .disabled(busy)
                    if model.serviceInstalled {
                        Button("Remove\u{2026}") { uninstall() }.disabled(busy)
                    }
                    Spacer()
                    Button("Input Monitoring\u{2026}") { openInputMonitoring() }
                }
                HStack {
                    Button("Reveal Service in Finder") { revealHelper() }
                        .disabled(!model.serviceInstalled)
                    Spacer()
                    Button("Restart Service") { model.send(.restart) }
                        .disabled(!model.serviceInstalled)
                }
                Text("""
                The service runs as root because macOS refuses a normal app the \
                Bluetooth HID++ channel these devices switch on. Open Input \
                Monitoring, drag "MX Switch Service" in from the Finder window, \
                switch it on, then click Restart Service.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section("Timing") {
                LabeledContent("Poll every") {
                    Stepper(
                        value: doubleBinding(\.pollInterval, range: 0.25...5, step: 0.25),
                        in: 0.25...5, step: 0.25
                    ) {
                        Text(String(format: "%.2f s", model.config.pollInterval))
                    }
                }
                LabeledContent("Confirm absence after") {
                    Stepper(value: intBinding(\.absentPollsRequired, range: 1...10), in: 1...10) {
                        Text("\(model.config.absentPollsRequired) polls")
                    }
                }
                Text("Higher values debounce Bluetooth dropouts; lower values switch sooner.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let installError {
                Section {
                    Text(installError).foregroundStyle(.red).font(.callout)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 620)
        .onAppear { model.refresh() }
    }

    // MARK: pieces

    private func devicePicker(
        _ title: String, selection: Binding<DeviceRef?>,
        options: [HIDDeviceInfo], empty: String
    ) -> some View {
        // A device that is configured but currently asleep still belongs in the
        // list, or opening Settings would silently drop the selection.
        var refs = options.map(\.ref)
        if let chosen = selection.wrappedValue, !refs.contains(chosen) {
            refs.append(chosen)
        }
        return Group {
            if refs.isEmpty {
                LabeledContent(title) {
                    Text(empty).foregroundStyle(.secondary).font(.callout)
                }
            } else {
                Picker(title, selection: selection) {
                    Text("Choose\u{2026}").tag(DeviceRef?.none)
                    ForEach(refs, id: \.self) { ref in
                        Text(deviceLabel(ref, connected: options.contains { $0.ref == ref }))
                            .tag(Optional(ref))
                    }
                }
            }
        }
    }

    private func deviceLabel(_ ref: DeviceRef, connected: Bool) -> String {
        connected ? "\(ref.name)  (\(ref.vidpid))" : "\(ref.name)  (\(ref.vidpid), not connected)"
    }

    private func slotPicker(_ title: String, selection: Binding<HostSlot?>) -> some View {
        Picker(title, selection: selection) {
            Text("Not set").tag(HostSlot?.none)
            ForEach(HostSlot.all, id: \.self) { slot in
                Text(label(for: slot)).tag(Optional(slot))
            }
        }
    }

    private func label(for slot: HostSlot) -> String {
        let name = model.config.displayName(for: slot)
        return name == "Key \(slot.keyLabel)"
            ? "Key \(slot.keyLabel)"
            : "Key \(slot.keyLabel) \u{2014} \(name)"
    }

    private var namesHint: String {
        guard model.serviceInstalled else {
            return "Install the background service first; reading names needs its privileges."
        }
        let named = model.config.hostNames.filter { !$0.isEmpty }.count
        return named == 0
            ? "Asks the keyboard which computer is paired to each Easy-Switch key."
            : "Names came from the keyboard, so the keys above match the physical Macs."
    }

    // MARK: bindings

    private var keyboardBinding: Binding<DeviceRef?> {
        Binding(get: { model.config.keyboard }, set: { model.config.keyboard = $0; model.save() })
    }

    private var mouseBinding: Binding<DeviceRef?> {
        Binding(get: { model.config.mouse }, set: { model.config.mouse = $0; model.save() })
    }

    private var thisHostBinding: Binding<HostSlot?> {
        Binding(get: { model.config.thisHost }, set: { model.config.thisHost = $0; model.save() })
    }

    private var targetHostBinding: Binding<HostSlot?> {
        Binding(get: { model.config.targetHost }, set: { model.config.targetHost = $0; model.save() })
    }

    private func doubleBinding(_ path: WritableKeyPath<Config, Double>, range: ClosedRange<Double>, step: Double) -> Binding<Double> {
        Binding(
            get: { model.config[keyPath: path] },
            set: { model.config[keyPath: path] = min(max($0, range.lowerBound), range.upperBound); model.save() })
    }

    private func intBinding(_ path: WritableKeyPath<Config, Int>, range: ClosedRange<Int>) -> Binding<Int> {
        Binding(
            get: { model.config[keyPath: path] },
            set: { model.config[keyPath: path] = min(max($0, range.lowerBound), range.upperBound); model.save() })
    }

    // MARK: service

    private func install() {
        busy = true
        installError = nil
        do {
            try ServiceInstaller.install(stateDirectory: model.store.directory)
            model.save()
            model.refresh()
        } catch {
            installError = error.localizedDescription
        }
        busy = false
    }

    private func uninstall() {
        busy = true
        installError = nil
        do {
            try ServiceInstaller.uninstall()
            model.refresh()
        } catch {
            installError = error.localizedDescription
        }
        busy = false
    }

    private func openInputMonitoring() {
        revealHelper()
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        NSWorkspace.shared.open(url)
    }

    /// The Input Monitoring list takes a drag from the Finder, which is far easier
    /// to get right than typing a path into its file picker.
    private func revealHelper() {
        guard model.serviceInstalled else { return }
        NSWorkspace.shared.activateFileViewerSelecting([
            URL(fileURLWithPath: ServiceInstaller.helperBundlePath)
        ])
    }
}
