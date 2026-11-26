import AppKit
import Foundation

/// Tells the app when a disk is plugged in or ejected.
@MainActor
final class VolumeWatcher {
    private let onMount: (String) -> Void
    private let onUnmount: (String) -> Void
    private var tokens: [NSObjectProtocol] = []
    private var started: Bool = false

    init(onMount: @escaping (String) -> Void, onUnmount: @escaping (String) -> Void) {
        self.onMount = onMount
        self.onUnmount = onUnmount
    }

    func start() {
        guard !started else { return }
        started = true
        let center: NotificationCenter = NSWorkspace.shared.notificationCenter

        let mountToken: NSObjectProtocol = center.addObserver(
            forName: NSWorkspace.didMountNotification, object: nil, queue: .main
        ) { [weak self] note in
            let name: String? = VolumeWatcher.volumeName(from: note)
            MainActor.assumeIsolated {
                if let name = name { self?.onMount(name) }
            }
        }
        let unmountToken: NSObjectProtocol = center.addObserver(
            forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main
        ) { [weak self] note in
            let name: String? = VolumeWatcher.volumeName(from: note)
            MainActor.assumeIsolated {
                if let name = name { self?.onUnmount(name) }
            }
        }
        tokens = [mountToken, unmountToken]
    }

    /// Names of the folders under /Volumes (one per mounted disk).
    static func currentVolumes() -> Set<String> {
        let names: [String] = (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []
        return Set(names)
    }

    nonisolated private static func volumeName(from note: Notification) -> String? {
        guard let info = note.userInfo else { return nil }
        if let name = info[NSWorkspace.localizedVolumeNameUserInfoKey] as? String, !name.isEmpty {
            return name
        }
        if let url = info[NSWorkspace.volumeURLUserInfoKey] as? URL {
            let last: String = url.lastPathComponent
            return last.isEmpty ? nil : last
        }
        return nil
    }
}
