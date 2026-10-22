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
        var userInfo = content.userInfo
        userInfo["pico"] = nil
        do {
            let keys = try KeychainPushKeyStore(bundle: .main)
            let notice = try PushNoticeOpener.open(userInfo: content.userInfo, keys: keys)
            content.title = notice.title
            content.body = notice.body
            userInfo[PushUserInfo.urlKey] = notice.url
        } catch PushOpenError.notAPicoNotice {
            return content
        } catch let PushOpenError.noKey(host), let PushOpenError.undecryptable(host) {
            content.body = PushCrypto.failureBody(host: host)
        } catch {
            content.body = "Pico could not open this notice (\(error))."
        }
        content.userInfo = userInfo
        return content
    }
}
