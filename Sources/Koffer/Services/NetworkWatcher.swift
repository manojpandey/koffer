import Foundation
import Network

/// Reports when the Mac goes online or offline.
final class NetworkWatcher {
    private let onChange: (Bool) -> Void
    private let monitor: NWPathMonitor = NWPathMonitor()
    private let queue: DispatchQueue = DispatchQueue(label: "com.koffer.app.network")
    // Only touched on `queue`.
    private var last: Bool? = nil
    private var started: Bool = false

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
    }

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let online: Bool = (path.status == .satisfied)
            if self.last == online { return }
            self.last = online
            DispatchQueue.main.async {
                self.onChange(online)
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
