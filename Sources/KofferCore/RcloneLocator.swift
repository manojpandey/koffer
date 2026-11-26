import Foundation

/// Finds the rclone binary. Homebrew on Apple silicon first, then Intel Homebrew, then the copy
/// Koffer installs itself (see `SyncEngine.installRclone()`).
public struct RcloneLocator {
    /// `~/Library/Application Support/Koffer/bin`, where Koffer puts the rclone it downloads.
    public static var installDirectory: URL {
        let base: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Koffer", isDirectory: true).appendingPathComponent("bin", isDirectory: true)
    }

    /// `~/Library/Application Support/Koffer/bin/rclone`
    public static var installedBinaryPath: String {
        return installDirectory.appendingPathComponent("rclone").path
    }

    public static let defaultCandidates: [String] = ["/opt/homebrew/bin/rclone", "/usr/local/bin/rclone",
                                                     RcloneLocator.installedBinaryPath]

    public var candidates: [String]

    public init(candidates: [String] = RcloneLocator.defaultCandidates) {
        self.candidates = candidates
    }

    /// The first candidate that exists, is a regular file (or a link to one) and is executable.
    public func locate(fileManager: FileManager = .default) -> String? {
        for path in candidates {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue { continue }
            if fileManager.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
}
