import Foundation
import KofferCore
import UserNotifications

/// Shows plain-words notifications. Does nothing when not running inside an app bundle.
final class Notifier: NSObject, Notifying, UNUserNotificationCenterDelegate {
    private let hasBundle: Bool = (Bundle.main.bundleIdentifier != nil)

    override init() {
        super.init()
        if hasBundle {
            UNUserNotificationCenter.current().delegate = self
        }
    }

    func requestPermission() {
        guard hasBundle else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: Notifying

    func syncStarted(job: SyncJob) {
        post(title: "Backing up \(job.name)", body: "Koffer will tell you when it's done.")
    }

    func syncFinished(record: RunRecord) {
        post(title: "Backup finished", body: Format.summary(record))
    }

    func syncPaused(job: SyncJob, reason: String) {
        post(title: "Backup paused", body: reason)
    }

    func syncFailed(job: SyncJob, reason: String) {
        post(title: "Backup needs attention", body: reason)
    }

    // MARK: Delegate

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // MARK: Helpers

    private func post(title: String, body: String) {
        guard hasBundle else { return }
        let content: UNMutableNotificationContent = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = UNNotificationSound.default
        let request: UNNotificationRequest = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}
