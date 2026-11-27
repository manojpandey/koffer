import AppKit
import Foundation

/// "Update Koffer" from the panel: fetch the latest source from GitHub, build it, swap the app and restart.
///
/// The build script stamps the source folder into the app's Info.plist (`KofferSourceDirectory`), so the app
/// knows which clone to update. Everything runs as child processes; the user never sees a Terminal window.
/// If the download or the build fails, nothing is replaced and Koffer keeps running.
@MainActor
final class Updater: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(count: Int, changes: [String])
        case updating(String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published var showChanges: Bool = false

    let sourceDirectory: String?
    let commit: String?
    let logURL: URL
    private var lastCheck: Date?

    static let noSourceMessage: String =
        "Koffer doesn't know where its source folder is. Install it once more with the installer; after that, updates work from here."

    init(bundle: Bundle = Bundle.main) {
        let info: [String: Any] = bundle.infoDictionary ?? [:]
        let directory: String? = info["KofferSourceDirectory"] as? String
        if let directory = directory, FileManager.default.fileExists(atPath: directory + "/.git") {
            sourceDirectory = directory
        } else {
            sourceDirectory = nil
        }
        commit = info["KofferCommit"] as? String
        let logs: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Koffer", isDirectory: true)
        logURL = logs.appendingPathComponent("update.log")
    }

    var versionText: String {
        let version: String = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
        if let commit = commit, !commit.isEmpty { return "Koffer \(version) (\(commit))" }
        return "Koffer \(version)"
    }

    var isWorking: Bool {
        switch state {
        case .checking, .updating: return true
        default: return false
        }
    }

    /// Checks at most once an hour (called when Settings opens).
    func checkIfStale() {
        if let last = lastCheck, Date().timeIntervalSince(last) < 3600 { return }
        check()
    }

    func check() {
        guard !isWorking else { return }
        guard let directory = sourceDirectory else {
            state = .failed(Updater.noSourceMessage)
            return
        }
        state = .checking
        Task { @MainActor in
            let fetch: ShellResult = await Shell.run(["git", "fetch", "--quiet", "origin", "main"], in: directory)
            guard fetch.status == 0 else {
                self.appendLog(fetch)
                self.state = .failed("Couldn't reach GitHub. Check the internet connection and try again.")
                return
            }
            let log: ShellResult = await Shell.run(["git", "log", "--format=%s", "HEAD..origin/main"], in: directory)
            self.lastCheck = Date()
            let changes: [String] = log.stdout
                .split(separator: "\n")
                .map { (line: Substring) -> String in String(line) }
                .filter { (line: String) -> Bool in !line.isEmpty }
            self.state = changes.isEmpty ? .upToDate : .available(count: changes.count, changes: changes)
        }
    }

    func install(backupRunning: Bool) {
        guard !isWorking else { return }
        guard !backupRunning else {
            state = .failed("Wait for the backup to finish, then update.")
            return
        }
        guard let directory = sourceDirectory else {
            state = .failed(Updater.noSourceMessage)
            return
        }
        startLog()
        Task { @MainActor in
            self.state = .updating("Downloading the update\u{2026}")
            let pull: ShellResult = await Shell.run(["git", "pull", "--ff-only", "origin", "main"], in: directory)
            self.appendLog(pull)
            guard pull.status == 0 else {
                self.state = .failed("Couldn't download the update. Nothing was changed. The update log has the details.")
                return
            }
            self.state = .updating("Building the new version\u{2026} this takes a minute or two.")
            let build: ShellResult = await Shell.run(["/bin/bash", directory + "/scripts/build.sh"], in: directory)
            self.appendLog(build)
            let newApp: String = directory + "/build/Koffer.app"
            guard build.status == 0, FileManager.default.fileExists(atPath: newApp + "/Contents/MacOS/Koffer") else {
                self.state = .failed("The new version didn't build, so nothing was replaced and Koffer keeps running. The update log has the details.")
                return
            }
            self.state = .updating("Restarting Koffer\u{2026}")
            self.relaunch(newApp: newApp)
        }
    }

    func showLog() {
        if FileManager.default.fileExists(atPath: logURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([logURL])
        }
    }

    // MARK: - Private

    /// Starts a detached helper that waits for Koffer to quit, swaps the app bundle, and opens the new one.
    /// If the copy fails it puts the old app back, so there is always a working Koffer.
    private func relaunch(newApp: String) {
        let destination: String = Bundle.main.bundlePath
        let pid: String = String(ProcessInfo.processInfo.processIdentifier)
        let script: String = """
        PID="$1"; SRC="$2"; DEST="$3"
        for i in $(/usr/bin/seq 1 150); do /bin/kill -0 "$PID" 2>/dev/null || break; /bin/sleep 0.2; done
        if [ "$SRC" != "$DEST" ]; then
          /bin/rm -rf "$DEST.previous"
          if /bin/mv "$DEST" "$DEST.previous" && /usr/bin/ditto "$SRC" "$DEST"; then
            /bin/rm -rf "$DEST.previous"
            echo "Installed the new version at $DEST"
          else
            echo "Copy failed; restoring the previous version"
            /bin/rm -rf "$DEST"
            /bin/mv "$DEST.previous" "$DEST"
          fi
        fi
        /usr/bin/open "$DEST"
        """
        let process: Process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script, "koffer-update", pid, newApp, destination]
        process.standardInput = FileHandle.nullDevice
        if let handle = FileHandle(forWritingAtPath: logURL.path) {
            handle.seekToEndOfFile()
            process.standardOutput = handle
            process.standardError = handle
        }
        do {
            try process.run()
        } catch {
            state = .failed("Couldn't restart Koffer: \(error.localizedDescription). The new version is in \(newApp).")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.terminate(nil)
        }
    }

    private func startLog() {
        let folder: URL = logURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let header: String = "Koffer update, \(Date())\n"
        try? header.data(using: .utf8)?.write(to: logURL, options: .atomic)
    }

    private func appendLog(_ result: ShellResult) {
        if !FileManager.default.fileExists(atPath: logURL.path) { startLog() }
        let text: String = "\n$ \(result.command)\nexit \(result.status)\n\(result.stdout)\(result.stderr)\n"
        guard let data = text.data(using: .utf8), let handle = FileHandle(forWritingAtPath: logURL.path) else { return }
        handle.seekToEndOfFile()
        handle.write(data)
        handle.closeFile()
    }
}

struct ShellResult {
    var status: Int32
    var stdout: String
    var stderr: String
    var command: String
}

/// Runs a command off the main thread with a predictable PATH (Homebrew and the Command Line Tools).
enum Shell {
    static func run(_ arguments: [String], in directory: String) async -> ShellResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<ShellResult, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runBlocking(arguments, in: directory))
            }
        }
    }

    private static func runBlocking(_ arguments: [String], in directory: String) -> ShellResult {
        let command: String = arguments.joined(separator: " ")
        let process: Process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        var environment: [String: String] = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let out: Pipe = Pipe()
        let err: Pipe = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return ShellResult(status: -1, stdout: "", stderr: error.localizedDescription, command: command)
        }
        let box: DataBox = DataBox()
        let group: DispatchGroup = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            box.data = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData: Data = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return ShellResult(status: process.terminationStatus,
                           stdout: String(decoding: outData, as: UTF8.self),
                           stderr: String(decoding: box.data, as: UTF8.self),
                           command: command)
    }
}

private final class DataBox {
    var data: Data = Data()
}
