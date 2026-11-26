import Foundation

/// Finds the rclone binary. Homebrew on Apple silicon first, then Intel Homebrew.
public struct RcloneLocator {
    public static let defaultCandidates: [String] = ["/opt/homebrew/bin/rclone", "/usr/local/bin/rclone"]

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
