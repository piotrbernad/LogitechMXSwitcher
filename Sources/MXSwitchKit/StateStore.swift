import Foundation

/// The three JSON files the app and the daemon exchange, in one directory the
/// user owns. The daemon runs as root, so every file it writes is chowned back
/// to the directory's owner; otherwise the app would lose the ability to replace it.
public struct StateStore: Sendable {
    public let directory: URL

    public static var userDefault: StateStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return StateStore(directory: base.appendingPathComponent("MXSwitch", isDirectory: true))
    }

    public init(directory: URL) {
        self.directory = directory
    }

    public var configURL: URL { directory.appendingPathComponent("config.json") }
    public var statusURL: URL { directory.appendingPathComponent("status.json") }
    public var commandURL: URL { directory.appendingPathComponent("command.json") }
    public var logURL: URL { directory.appendingPathComponent("mxswitchd.log") }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(type, from: data)
    }

    public func write<T: Encodable>(_ value: T, to url: URL) throws {
        try ensureDirectory()
        let data = try Self.encoder.encode(value)
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier)")
        try data.write(to: temp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        adoptDirectoryOwner(url)
    }

    public func loadConfig() -> Config? { read(Config.self, from: configURL) }
    public func saveConfig(_ config: Config) throws { try write(config, to: configURL) }
    public func loadStatus() -> DaemonStatus? { read(DaemonStatus.self, from: statusURL) }
    public func saveStatus(_ status: DaemonStatus) throws { try write(status, to: statusURL) }
    public func loadCommand() -> Command? { read(Command.self, from: commandURL) }
    public func saveCommand(_ command: Command) throws { try write(command, to: commandURL) }

    /// Hand a root-written file back to the user who owns the state directory.
    private func adoptDirectoryOwner(_ url: URL) {
        guard geteuid() == 0 else { return }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: directory.path),
              let uid = attrs[.ownerAccountID] as? NSNumber,
              let gid = attrs[.groupOwnerAccountID] as? NSNumber
        else { return }
        chown(url.path, uid_t(truncating: uid), gid_t(truncating: gid))
        chmod(url.path, 0o644)
    }
}
