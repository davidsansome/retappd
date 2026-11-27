import Foundation
import UserNotifications

/// Downloads and attaches the beer label or user avatar specified by the relay's `retappd.image_url`.
final class NotificationService: UNNotificationServiceExtension {
    private let lock = NSLock()
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?
    private var task: Task<Void, Never>?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        lock.withLock {
            self.contentHandler = contentHandler
            self.bestAttemptContent = content
        }

        guard let url = NotificationImageAttachment.imageURL(from: request.content.userInfo) else {
            deliver(content)
            return
        }

        let t = Task {
            let attachment = await NotificationImageAttachment.attachment(for: url)
            guard !Task.isCancelled else { return }
            if let attachment, let updated = content.mutableCopy() as? UNMutableNotificationContent {
                updated.attachments = [attachment]
                self.deliver(updated)
            } else {
                self.deliver(content)
            }
        }
        lock.withLock { self.task = t }
    }

    override func serviceExtensionTimeWillExpire() {
        let (t, content) = lock.withLock { (task, bestAttemptContent) }
        t?.cancel()
        if let content { deliver(content) }
    }

    private func deliver(_ content: UNNotificationContent) {
        let handler = lock.withLock { () -> ((UNNotificationContent) -> Void)? in
            let h = contentHandler
            contentHandler = nil
            bestAttemptContent = nil
            task = nil
            return h
        }
        handler?(content)
    }
}
