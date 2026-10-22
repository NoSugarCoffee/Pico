import Foundation
import MinisRemote
import PicoPush
import UIKit
import UserNotifications

private let logger = AppLogger(category: "PicoPush")

enum PushRegistrationError: Error, Equatable {
    case notificationsDenied
    case tokenUnavailable(String)
    case undecodableKey(host: String)

    var userMessage: String {
        switch self {
        case .notificationsDenied:
            return RemoteHostL10n.string("Notifications are off for Pico. Turn them on in the iOS Settings app → Pico → Notifications, then try again.")
        case .tokenUnavailable(let detail):
            return RemoteHostL10n.string("iOS did not give Pico a push token (\(detail)). This build may lack the push entitlement: build it with ios-personal-device.sh --keep-push.")
        case .undecodableKey(let host):
            return RemoteHostL10n.string("minis-hostd on \(host) returned a push key Pico could not read. Update minis-hostd on \(host).")
        }
    }
}

/// What this phone last registered on each host, so a changed token is noticed on launch (apns spec §4).
struct PushRegistrationRecord: Codable, Equatable {
    var token: String
    var keyID: String
    /// The last background re-registration's failure, shown on the host's Notifications screen.
    var lastError: String?
}

/// Hands APNs device tokens from the app delegate to whoever asked for one.
@MainActor
final class PushTokenBroker {
    static let shared = PushTokenBroker()

    private var waiters: [CheckedContinuation<Data, Error>] = []

    func requestToken() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    func received(_ token: Data) {
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume(returning: token) }
    }

    func failed(_ error: Error) {
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume(throwing: PushRegistrationError.tokenUnavailable(error.localizedDescription)) }
    }
}

/// Settings → Remote Hosts → host → Notifications → Send to This iPhone, and its silent repeat on launch.
@MainActor
enum PushRegistration {
    struct Dependencies {
        var authorize: () async throws -> Bool
        var deviceToken: () async throws -> Data
        var topic: String
        var environment: APNsEnvironment
        var register: (_ host: String, _ token: String, _ topic: String, _ environment: String) async throws
            -> HostdAPNsRegistration
        var saveKey: (_ key: Data, _ host: String, _ keyID: String) throws -> Void
        var activate: (_ host: String, _ keyID: String) async throws -> Void
        var records: () -> [String: PushRegistrationRecord]
        var saveRecords: ([String: PushRegistrationRecord]) -> Void
    }

    static let recordsKey = "pico.push.registrations"

    static func tokenHex(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }

    /// The order is the point: hostd seals with the new key only after `activate`, which runs only once
    /// the key is in the keychain, so an interrupted run leaves the host on the key the phone already has.
    static func register(host: String, using deps: Dependencies) async throws {
        guard try await deps.authorize() else { throw PushRegistrationError.notificationsDenied }
        let token = tokenHex(try await deps.deviceToken())
        let reply = try await deps.register(host, token, deps.topic, deps.environment.rawValue)
        guard let key = Data(base64Encoded: reply.key) else { throw PushRegistrationError.undecodableKey(host: host) }
        try deps.saveKey(key, host, reply.keyId)
        try await deps.activate(host, reply.keyId)
        var records = deps.records()
        records[host] = PushRegistrationRecord(token: token, keyID: reply.keyId, lastError: nil)
        deps.saveRecords(records)
        logger.info("[PicoPush] registered \(host) with key \(reply.keyId)")
    }

    /// Hosts this phone registered with, again, when iOS has since given it a different token.
    static func refreshChangedTokens(using deps: Dependencies) async {
        let records = deps.records()
        guard !records.isEmpty else { return }
        let token: String
        do {
            token = tokenHex(try await deps.deviceToken())
        } catch {
            logger.error("[PicoPush] no token on launch: \(error)")
            return
        }
        for (host, record) in records.sorted(by: { $0.key < $1.key }) where record.token != token {
            do {
                try await register(host: host, using: deps)
            } catch {
                logger.error("[PicoPush] re-registering \(host) failed: \(error)")
                var updated = deps.records()
                updated[host]?.lastError = message(for: error)
                deps.saveRecords(updated)
            }
        }
    }

    static func message(for error: Error) -> String {
        if let registrationError = error as? PushRegistrationError {
            return registrationError.userMessage
        }
        if let keychainError = error as? PushKeyStoreError {
            switch keychainError {
            case .missingAccessGroup:
                return RemoteHostL10n.string("This build has no keychain group for notification keys (PicoPushKeychainGroup in Info.plist). Build it with a development team.")
            case .keychain(let operation, let status):
                return RemoteHostL10n.string("Saving the notification key failed (keychain \(operation), status \(status)).")
            }
        }
        if case HostEventError.server(code: "bad_request", let message) = error, message.contains("unknown command") {
            return RemoteHostL10n.string("This minis-hostd is too old for Pico notifications. Update it to \(HostdRelease.version) or later.")
        }
        return HostNotificationsModel.message(for: error)
    }

    static func record(host: String) -> PushRegistrationRecord? {
        Dependencies.liveRecords()[host]
    }

    static func refreshOnLaunch() {
        guard !Dependencies.liveRecords().isEmpty, case .success(let services) = RemoteAppWiring.shared.services else {
            return
        }
        do {
            let deps = try Dependencies.live(services: services)
            Task { await refreshChangedTokens(using: deps) }
        } catch {
            logger.error("[PicoPush] cannot refresh registrations: \(error)")
        }
    }
}

extension PushRegistration.Dependencies {
    static func liveRecords() -> [String: PushRegistrationRecord] {
        guard let data = UserDefaults.standard.data(forKey: PushRegistration.recordsKey) else { return [:] }
        do {
            return try JSONDecoder().decode([String: PushRegistrationRecord].self, from: data)
        } catch {
            logger.error("[PicoPush] registration records unreadable: \(error)")
            return [:]
        }
    }

    static func live(services: RemoteServices) throws -> Self {
        let keys = try KeychainPushKeyStore(bundle: .main)
        let client = HostEventClient(runner: services.executor)
        let profile = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
            .flatMap { try? Data(contentsOf: $0) }
        return Self(
            authorize: {
                try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            },
            deviceToken: { try await PushTokenBroker.shared.requestToken() },
            topic: Bundle.main.bundleIdentifier ?? "",
            environment: ProvisioningProfile.apsEnvironment(profile: profile),
            register: { host, token, topic, environment in
                try await client.registerAPNs(host: host, deviceToken: token, topic: topic, environment: environment)
            },
            saveKey: { key, host, keyID in try keys.setKey(key, host: host, keyID: keyID) },
            activate: { host, keyID in _ = try await client.activateAPNs(host: host, keyID: keyID) },
            records: liveRecords,
            saveRecords: { records in
                do {
                    UserDefaults.standard.set(try JSONEncoder().encode(records), forKey: PushRegistration.recordsKey)
                } catch {
                    logger.error("[PicoPush] saving registration records failed: \(error)")
                }
            })
    }
}
