import AppKit
import Foundation

/// Opens Terminal and runs a command (used for things like reconnecting to OneDrive).
enum TerminalLauncher {
    static func run(_ command: String) {
        let script: String = """
        #!/bin/zsh
        export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
        \(command)
        echo ""
        echo "All done. You can close this window."

        """
        let name: String = "koffer-\(UUID().uuidString).command"
        let url: URL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
        guard let data: Data = script.data(using: .utf8) else { return }
        let ok: Bool = FileManager.default.createFile(
            atPath: url.path, contents: data, attributes: [.posixPermissions: 0o755])
        guard ok else { return }
        // Make sure the executable bit is set even if the umask interfered.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        NSWorkspace.shared.open(url)
    }
}
