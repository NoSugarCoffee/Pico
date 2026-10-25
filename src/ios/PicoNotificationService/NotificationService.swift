import PicoPush
import UserNotifications

/// Opens hostd's sealed notice before iOS shows it (apns spec §5). Apple only ever saw the placeholder.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var fallback: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        fallback = content
        contentHandler(Self.opened(content))
    }

    override func serviceExtensionTimeWillExpire() {
        if let contentHandler, let fallback {
            contentHandler(fallback)
        }
    }

    private static func opened(_ content: UNMutableNotificationContent) -> UNNotificationContent {
        do {
            let display = PushDisplayPolicy.display(
                title: content.title,
                body: content.body,
                userInfo: content.userInfo,
                keys: try KeychainPushKeyStore(bundle: .main),
                failureBody: { host in
                    String(
                        localized: "Pico could not decrypt this notice. Open Settings → Remote Hosts → \(host) → Notifications and tap Send to This iPhone.",
                        table: "RemotePush", bundle: .main)
                },
                unopenableBody: String(
                    localized: "Pico could not open this notice. Open Settings → Remote Hosts → your host → Notifications and tap Send to This iPhone.",
                    table: "RemotePush", bundle: .main))
            content.title = display.title
            content.body = display.body
            content.userInfo = display.userInfo
        } catch {
            NSLog("[PicoPush] no key store for the notice: %@", String(describing: error))
            content.body = String(
                localized: "Pico could not open this notice. Open Settings → Remote Hosts → your host → Notifications and tap Send to This iPhone.",
                table: "RemotePush", bundle: .main)
        }
        return content
    }
}
