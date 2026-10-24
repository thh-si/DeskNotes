import AppKit
import NotesCore
@preconcurrency import UserNotifications

/// macOS calls these on a background queue, so they can't live on the main-actor `Notifier`.
/// They only pull the note id out of the notification and hand over to it.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private static func noteID(in notification: UNNotification) -> UUID? {
        (notification.request.content.userInfo["noteID"] as? String).flatMap(UUID.init(uuidString:))
    }

    /// A notification arrives while DeskNotes is running: show it like any other.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let id = Self.noteID(in: notification)
        await MainActor.run { Notifier.shared.reminderDelivered(id) }
        return [.banner, .list, .sound]
    }

    /// The notification was clicked.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let id = Self.noteID(in: response.notification)
        await MainActor.run { Notifier.shared.reminderOpened(id) }
    }
}

/// Notifications for reminders and the Pomodoro timer, through the system's Notification Center.
///
/// Reminders are *scheduled with the system*, so they arrive on time even when DeskNotes has been
/// quit. Notifications only work for a real app bundle: from `swift run` this stays silent.
@MainActor
final class Notifier {
    static let shared = Notifier()

    private let delegate = NotificationDelegate()
    private let center: UNUserNotificationCenter? =
        Bundle.main.bundleURL.pathExtension == "app" ? UNUserNotificationCenter.current() : nil

    /// Whether the user allows notifications for DeskNotes (as last checked).
    private(set) var isAuthorized = false
    /// A reminder was delivered while DeskNotes was running (or its notification was clicked).
    var onReminderFired: ((UUID) -> Void)?
    /// A notification was clicked: bring that note up.
    var onOpenNote: ((UUID) -> Void)?

    /// Must run at launch, before anything else, so clicks on notifications are received.
    func start() {
        center?.delegate = delegate
    }

    func refreshAuthorization() async {
        guard let center else { return }
        let status = await center.notificationSettings().authorizationStatus
        isAuthorized = status == .authorized || status == .provisional
    }

    /// Asks the first time (macOS shows its own dialog); afterwards just reports the answer.
    @discardableResult
    func requestAuthorization() async -> Bool {
        guard let center else { return false }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        await refreshAuthorization()
        return isAuthorized
    }

    /// Shows a notification right now. Returns false if it could not be shown.
    @discardableResult
    func post(title: String, body: String, noteID: UUID? = nil) async -> Bool {
        guard let center, isAuthorized else { return false }
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content(title: title, body: body, noteID: noteID),
                                            trigger: nil)
        return (try? await center.add(request)) != nil
    }

    /// Schedules the system to show a notification at `date`. Scheduling again replaces the old one.
    @discardableResult
    func scheduleReminder(noteID: UUID, title: String, body: String, at date: Date) async -> Bool {
        guard let center, isAuthorized else { return false }
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let request = UNNotificationRequest(identifier: noteID.uuidString,
                                            content: content(title: title, body: body, noteID: noteID),
                                            trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
        return (try? await center.add(request)) != nil
    }

    func cancelReminder(noteID: UUID) {
        center?.removePendingNotificationRequests(withIdentifiers: [noteID.uuidString])
        center?.removeDeliveredNotifications(withIdentifiers: [noteID.uuidString])
    }

    /// Notes whose reminder is still showing in Notification Center.
    func deliveredNoteIDs() async -> Set<UUID> {
        guard let center else { return [] }
        let delivered = await center.deliveredNotifications()
        return Set(delivered.compactMap { UUID(uuidString: $0.request.identifier) })
    }

    // MARK: Called by NotificationDelegate

    func reminderDelivered(_ id: UUID?) {
        if let id { onReminderFired?(id) }
    }

    func reminderOpened(_ id: UUID?) {
        guard let id else { return }
        onReminderFired?(id)
        onOpenNote?(id)
    }

    private func content(title: String, body: String, noteID: UUID?) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let noteID { content.userInfo = ["noteID": noteID.uuidString] }
        return content
    }
}
