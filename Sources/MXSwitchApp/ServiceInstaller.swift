import Foundation
import MXSwitchKit

/// Installs the watcher as a root LaunchDaemon.
///
/// Root is not a convenience here: opening a Bluetooth keyboard's HID++ vendor
/// interface returns kIOReturnNotPermitted to an ordinary user process even with
/// Input Monitoring granted, so the send has to come from a privileged client.
enum ServiceInstaller {
    static let label = "co.bernad.mxswitch"

    /// The helper installs as a named app bundle rather than a bare Unix binary.
    /// Input Monitoring lists whatever asked for access, and a bundle shows up as
    /// "MX Switch Service" with an icon instead of an anonymous path the user
    /// cannot recognise or drag in.
    static let helperName = "MX Switch Service.app"
    static let helperDirectory = "/Library/PrivilegedHelperTools"
    static var helperBundlePath: String { "\(helperDirectory)/\(helperName)" }
    static var daemonPath: String { "\(helperBundlePath)/Contents/MacOS/MXSwitchService" }
    static var plistPath: String { "/Library/LaunchDaemons/\(label).plist" }

    /// Where the pre-bundle releases put the helper. Install sweeps it up.
    private static let legacyDaemonPath = "/usr/local/libexec/mxswitchd"

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistPath)
            && FileManager.default.isExecutableFile(atPath: daemonPath)
    }

    /// The helper bundle shipped inside the app, which install copies into place.
    static var bundledHelper: URL? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/\(helperName)")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    enum InstallError: LocalizedError {
        case helperMissing
        case cancelled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .helperMissing:
                return "The background service is missing from the app bundle. Rebuild the app."
            case .cancelled:
                return "Administrator approval was declined."
            case .failed(let message):
                return message
            }
        }
    }

    /// Re-running this is safe: it replaces the binary and the job definition and
    /// restarts the daemon, whatever state the machine was left in.
    static func install(stateDirectory: URL) throws {
        try runPrivileged(installScript(stateDirectory: stateDirectory))
    }

    /// Exposed so `--print-install-script` can show what is about to run as root.
    static func installScript(stateDirectory: URL) throws -> String {
        guard let helper = bundledHelper else { throw InstallError.helperMissing }
        return """
        set -e
        /bin/launchctl bootout system/\(label) 2>/dev/null || true
        /bin/rm -rf \(shellQuote(helperBundlePath)) \(shellQuote(legacyDaemonPath))
        /usr/bin/install -d -o root -g wheel -m 755 \(shellQuote(helperDirectory))
        /usr/bin/ditto \(shellQuote(helper.path)) \(shellQuote(helperBundlePath))
        /usr/sbin/chown -R root:wheel \(shellQuote(helperBundlePath))
        /bin/chmod -R go-w \(shellQuote(helperBundlePath))
        /bin/cat > \(shellQuote(plistPath)) <<'MXSWITCH_PLIST'
        \(plist(stateDirectory: stateDirectory))
        MXSWITCH_PLIST
        /usr/sbin/chown root:wheel \(shellQuote(plistPath))
        /bin/chmod 644 \(shellQuote(plistPath))
        /bin/launchctl bootstrap system \(shellQuote(plistPath))
        /bin/launchctl enable system/\(label)
        /bin/launchctl kickstart -k system/\(label)
        """
    }

    static func uninstall() throws {
        try runPrivileged(uninstallScript)
    }

    static var uninstallScript: String {
        """
        /bin/launchctl bootout system/\(label) 2>/dev/null || true
        /bin/rm -f \(shellQuote(plistPath)) \(shellQuote(legacyDaemonPath))
        /bin/rm -rf \(shellQuote(helperBundlePath))
        """
    }

    private static func plist(stateDirectory: URL) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(daemonPath)</string>
                <string>watch</string>
                <string>--state-dir</string>
                <string>\(xmlEscape(stateDirectory.path))</string>
            </array>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><true/>
            <!-- Not Background: that opts into CPU and I/O throttling, and a one
                 second poll that must catch a keypress cannot afford to be stalled. -->
            <key>ProcessType</key><string>Interactive</string>
        </dict>
        </plist>
        """
    }

    /// The script goes to a file in the per-user temp directory (mode 0700) and is
    /// run by path. Passing it inline through osascript would mean quoting it twice.
    private static func runPrivileged(_ script: String) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mxswitch-\(UUID().uuidString).sh")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        defer { try? FileManager.default.removeItem(at: url) }

        let source = "do shell script \"/bin/sh \" & quoted form of \"\(url.path)\" with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()
        try process.run()
        let stderr = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus != 0 else { return }
        let message = String(decoding: stderr, as: UTF8.self)
        if message.contains("-128") { throw InstallError.cancelled }
        throw InstallError.failed(message.isEmpty ? "The installer failed." : message)
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
