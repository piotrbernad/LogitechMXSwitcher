import AppKit
import SwiftUI
import MXSwitchKit

@MainActor
enum SettingsRenderer {
    static func write(to path: String) {
        // A scratch state directory: rendering the UI must never rewrite the
        // settings the user is actually running with.
        let arguments = CommandLine.arguments
        let override = arguments.firstIndex(of: "--state-dir").flatMap { index -> URL? in
            index + 1 < arguments.count ? URL(fileURLWithPath: arguments[index + 1]) : nil
        }
        let scratch = override ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("mxswitch-render-\(UUID().uuidString)", isDirectory: true)
        defer { if override == nil { try? FileManager.default.removeItem(at: scratch) } }
        let model = AppModel(store: StateStore(directory: scratch))
        let hosting = NSHostingView(rootView: SettingsView(model: model))
        hosting.frame = NSRect(x: 0, y: 0, width: 480, height: 620)

        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "MX Switch"
        window.contentView = hosting
        window.orderFrontRegardless()
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))

        // SwiftUI needs a few run loop turns before the layer tree has content.
        for _ in 0..<40 {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    }
}
