import Foundation
import UserNotifications

/// Local notifications. Texts are generic: no file names, so nothing sensitive
/// shows on the lock screen.
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    var onOpen: (() -> Void)?
    /// Accept / Decline pressed on an incoming-transfer notification.
    var onOfferAction: ((_ transferId: String, _ accept: Bool) -> Void)?
    /// "Show in Finder" pressed on a "ready to paste" notification.
    var onReveal: ((_ urls: [URL]) -> Void)?

    private static let offerCategory = "OFFER"
    private static let acceptAction = "ACCEPT"
    private static let declineAction = "DECLINE"
    private static let readyCategory = "READY"
    private static let revealAction = "REVEAL"

    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let accept = UNNotificationAction(identifier: Self.acceptAction, title: "Accept", options: [])
        let decline = UNNotificationAction(identifier: Self.declineAction, title: "Decline", options: [.destructive])
        let reveal = UNNotificationAction(identifier: Self.revealAction, title: "Show in Finder", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.offerCategory, actions: [accept, decline],
                                   intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: Self.readyCategory, actions: [reveal],
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

    /// Something arrived and is ready (e.g. a photo on the clipboard), with "Show in Finder".
    /// The paths travel in `userInfo` only; the visible text never names the files.
    func postReady(title: String, body: String, urls: [URL]) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = Self.readyCategory
        content.userInfo = ["paths": urls.prefix(20).map { $0.path }]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
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
        let paths = response.notification.request.content.userInfo["paths"] as? [String] ?? []
        let action = response.actionIdentifier
        DispatchQueue.main.async {
            if let id = transferId, action == Self.acceptAction || action == Self.declineAction {
                self.onOfferAction?(id, action == Self.acceptAction)
            } else if action == Self.revealAction, !paths.isEmpty {
                self.onReveal?(paths.map { URL(fileURLWithPath: $0) })
            } else {
                self.onOpen?()
            }
        }
        completionHandler()
    }
}
