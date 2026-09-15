import AppKit
import MXSwitchKit

@main
enum MXSwitch {
    /// NSApplication holds its delegate weakly, so the app owns it here.
    @MainActor private static var delegate: AppDelegate?

    @MainActor
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)

        // `--render-settings <path>` draws the settings window to a PNG and exits.
        // It keeps the UI reviewable without granting anything Screen Recording.
        if let index = CommandLine.arguments.firstIndex(of: "--render-settings"),
           index + 1 < CommandLine.arguments.count {
            SettingsRenderer.write(to: CommandLine.arguments[index + 1])
            return
        }

        // Show the privileged script instead of running it. Anything asking for an
        // admin password should be readable first.
        if CommandLine.arguments.contains("--print-install-script") {
            let directory = StateStore.userDefault.directory
            print((try? ServiceInstaller.installScript(stateDirectory: directory))
                ?? "the helper is missing from the app bundle")
            print("\n# uninstall\n" + ServiceInstaller.uninstallScript)
            return
        }

        let appDelegate = AppDelegate()
        delegate = appDelegate
        application.delegate = appDelegate
        application.run()
    }
}
