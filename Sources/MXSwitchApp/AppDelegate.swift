import AppKit
import SwiftUI
import MXSwitchKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = AppModel()
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refresh()

        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }

        // First launch, or a machine that lost its setup: open the window rather
        // than sit silently in the menu bar doing nothing.
        if !model.serviceInstalled || !model.isConfigured {
            showSettings(nil)
        }
    }

    private func refresh() {
        model.refresh()
        guard let button = statusItem.button else { return }
        let symbol = model.isHealthy ? "rectangle.on.rectangle.angled" : "exclamationmark.triangle"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "MX Switch")
        button.image?.isTemplate = true
        button.toolTip = "MX Switch \u{2014} \(model.headline)"
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        model.refresh()
        menu.removeAllItems()

        let headline = NSMenuItem(title: model.headline, action: nil, keyEquivalent: "")
        headline.isEnabled = false
        menu.addItem(headline)
        let detail = NSMenuItem(title: model.detail, action: nil, keyEquivalent: "")
        detail.isEnabled = false
        detail.attributedTitle = NSAttributedString(
            string: model.detail,
            attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        menu.addItem(detail)
        menu.addItem(.separator())

        if let target = model.config.targetHost, model.serviceInstalled {
            let switchBoth = NSMenuItem(
                title: "Switch Keyboard and Mouse to \(model.config.displayName(for: target))",
                action: #selector(switchBoth(_:)), keyEquivalent: "")
            switchBoth.target = self
            menu.addItem(switchBoth)

            let switchMouse = NSMenuItem(
                title: "Send Mouse Only to \(model.config.displayName(for: target))",
                action: #selector(switchMouseOnly(_:)), keyEquivalent: "")
            switchMouse.target = self
            switchMouse.isAlternate = true
            switchMouse.keyEquivalentModifierMask = .option
            menu.addItem(switchMouse)
            menu.addItem(.separator())
        }

        let enabled = NSMenuItem(
            title: "Switch Automatically", action: #selector(toggleEnabled(_:)), keyEquivalent: "")
        enabled.target = self
        enabled.state = model.config.enabled ? .on : .off
        menu.addItem(enabled)

        let settings = NSMenuItem(
            title: "Settings\u{2026}", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        if let event = model.status?.lastEvent {
            menu.addItem(.separator())
            let last = NSMenuItem(title: "Last: \(event)", action: nil, keyEquivalent: "")
            last.isEnabled = false
            last.attributedTitle = NSAttributedString(
                string: "Last: \(event)",
                attributes: [
                    .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ])
            menu.addItem(last)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit MX Switch", action: #selector(quit(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: actions

    @objc private func switchBoth(_ sender: Any?) {
        model.send(.switchBoth, target: model.config.targetHost)
    }

    @objc private func switchMouseOnly(_ sender: Any?) {
        model.send(.switchMouse, target: model.config.targetHost)
    }

    @objc private func toggleEnabled(_ sender: Any?) {
        model.config.enabled.toggle()
        model.save()
        refresh()
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 620),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered, defer: false)
            window.title = "MX Switch"
            window.isReleasedWhenClosed = false
            window.center()
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }
}
