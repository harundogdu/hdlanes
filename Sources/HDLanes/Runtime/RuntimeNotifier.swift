import AppKit
import Foundation
import UserNotifications

/// System notifications for "needs you" and "done". Only in the bundled app:
/// `UNUserNotificationCenter` aborts in a process without a bundle identifier (`swift run`).
@MainActor
final class RuntimeNotifier: NSObject, UNUserNotificationCenterDelegate {
    nonisolated static let sessionKey = "session"

    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    /// Called with the session id when the user clicks a notification.
    var onOpen: ((UUID) -> Void)?
    private var authorization: Bool?
    private var waiting: [UNNotificationRequest] = []
    private var requesting = false

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func post(sessionID: UUID, title: String, body: String, sound: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = sessionID.uuidString
        content.userInfo = [Self.sessionKey: sessionID.uuidString]
        if sound { content.sound = .default }
        // One notification per session: a newer one replaces the older.
        let request = UNNotificationRequest(identifier: sessionID.uuidString, content: content, trigger: nil)
        switch authorization {
        case true?: UNUserNotificationCenter.current().add(request)
        case false?: return
        case nil:
            waiting.append(request)
            requestAuthorization()
        }
    }

    func removeDelivered(sessionID: UUID) {
        guard authorization == true else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [sessionID.uuidString])
    }

    /// Asked lazily, the first time there is something to show.
    private func requestAuthorization() {
        guard !requesting else { return }
        requesting = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.authorization = granted
                self.requesting = false
                let pending = self.waiting
                self.waiting.removeAll()
                if granted { pending.forEach { UNUserNotificationCenter.current().add($0) } }
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Posted only when the user isn't looking at that session, so show it even while hdlanes is active.
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let raw = response.notification.request.content.userInfo[Self.sessionKey] as? String
        DispatchQueue.main.async { [weak self] in
            if let raw, let id = UUID(uuidString: raw) {
                NSApp.activate(ignoringOtherApps: true)
                self?.onOpen?(id)
            }
        }
        completionHandler()
    }
}
