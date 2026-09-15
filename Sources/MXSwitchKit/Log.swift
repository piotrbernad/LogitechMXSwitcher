import Foundation

/// Line logger that also appends to a rotating file, so the menu bar app can
/// show the daemon's last words after a failure.
public final class Log {
    private let fileURL: URL?
    private let maxBytes: UInt64
    private let formatter: DateFormatter

    public init(fileURL: URL?, maxBytes: UInt64 = 1_000_000) {
        self.fileURL = fileURL
        self.maxBytes = maxBytes
        formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    }

    public func callAsFunction(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        FileHandle.standardOutput.write(Data(line.utf8))
        guard let fileURL else { return }
        rotateIfNeeded()
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: fileURL)
        }
    }

    private func rotateIfNeeded() {
        guard let fileURL,
              let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? UInt64,
              size > maxBytes
        else { return }
        let previous = fileURL.deletingPathExtension().appendingPathExtension("1.log")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: fileURL, to: previous)
    }
}
