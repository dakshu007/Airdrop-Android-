import Foundation
import UserNotifications

/// Local notifications. Texts are generic: no file names, so nothing sensitive
/// shows on the lock screen.
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    var onOpen: (() -> Void)?
    /// Accept / Decline pressed on an incoming-transfer notification.
    var onOfferAction: ((_ transferId: String, _ accept: Bool) -> Void)?

    private static let offerCategory = "OFFER"
    private static let acceptAction = "ACCEPT"
    private static let declineAction = "DECLINE"

    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let accept = UNNotificationAction(identifier: Self.acceptAction, title: "Accept", options: [])
        let decline = UNNotificationAction(identifier: Self.declineAction, title: "Decline", options: [.destructive])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.offerCategory, actions: [accept, decline],
                                   intentIdentifiers: [], options: []),
        ])
    }

    /// An incoming transfer waiting for approval, with Accept / Decline buttons.
    func postOffer(transferId: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = Self.offerCategory
        content.userInfo = ["transferId": transferId]
        let request = UNNotificationRequest(identifier: "offer-" + transferId, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    func removeOffer(transferId: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["offer-" + transferId])
    }

    func requestAuthorization(_ completion: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let transferId = response.notification.request.content.userInfo["transferId"] as? String
        let action = response.actionIdentifier
        DispatchQueue.main.async {
            if let id = transferId, action == Self.acceptAction || action == Self.declineAction {
                self.onOfferAction?(id, action == Self.acceptAction)
            } else {
                self.onOpen?()
            }
        }
        completionHandler()
    }
}
