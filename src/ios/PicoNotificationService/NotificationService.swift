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
            let keys = try KeychainPushKeyStore(bundle: .main)
            let notice = try PushNoticeOpener.open(userInfo: content.userInfo, keys: keys)
            content.title = notice.title
            content.body = notice.body
            var userInfo = content.userInfo
            userInfo[PushUserInfo.urlKey] = notice.url
            userInfo["pico"] = nil
            content.userInfo = userInfo
        } catch PushOpenError.notAPicoNotice {
            return content
        } catch let PushOpenError.noKey(host), let PushOpenError.undecryptable(host) {
            // The envelope stays, so the tap opens it again once the phone has a key that works.
            content.body = PushCrypto.failureBody(host: host)
        } catch {
            NSLog("[PicoPush] the notice could not be opened: %@", String(describing: error))
            content.body = PushCrypto.unopenableBody
        }
        return content
    }
}
