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

/// The link a tapped Pico notification opens (apns spec §5).
enum PushTap {
    /// The extension leaves the link in userInfo. When it crashed or ran out of time, iOS showed the
    /// placeholder and the link is still sealed in the envelope, so it is opened here with the same keys.
    static func link(userInfo: [AnyHashable: Any]) -> URL? {
        link(userInfo: userInfo, keys: { try KeychainPushKeyStore(bundle: .main) })
    }

    static func link(userInfo: [AnyHashable: Any], keys: () throws -> any PushKeyStore) -> URL? {
        if let link = userInfo[PushUserInfo.urlKey] as? String {
            return URL(string: link)
        }
        guard userInfo["pico"] != nil else { return nil }
        do {
            return try PushNoticeOpener.open(userInfo: userInfo, keys: keys()).url.flatMap(URL.init(string:))
        } catch {
            logger.error("[PicoPush] tapped notice could not be opened: \(error)")
            return nil
        }
    }
}

/// What this phone last registered on each host, so a changed token is noticed on launch (apns spec §4).
struct PushRegistrationRecord: Codable, Equatable {
    var token: String
    var keyID: String
    /// The last background re-registration's failure, shown on the host's Notifications screen.
    var lastError: String?
    /// Every key this phone kept for the host, because earlier ones still open queued notices; removing the
    /// host has to delete all of them, not just the active one.
    var keyIDs: [String]

    private enum CodingKeys: String, CodingKey { case token, keyID = "keyId", lastError, keyIDs }

    init(token: String, keyID: String, lastError: String?, keyIDs: [String]) {
        self.token = token
        self.keyID = keyID
        self.lastError = lastError
        self.keyIDs = keyIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        token = try container.decode(String.self, forKey: .token)
        keyID = try container.decode(String.self, forKey: .keyID)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        keyIDs = try container.decodeIfPresent([String].self, forKey: .keyIDs) ?? [keyID]
    }
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
        var deleteKey: (_ host: String, _ keyID: String) throws -> Void
        var activate: (_ host: String, _ keyID: String) async throws -> Void
        var records: () -> [String: PushRegistrationRecord]
        var saveRecords: ([String: PushRegistrationRecord]) -> Void
    }

    static let recordsKey = "pico.push.registrations"
    static let unreadableRecordsKeyPrefix = "pico.push.registrations.unreadable-"

    /// A launch refresh and Send to This iPhone can aim at the same host; hostd keeps one pending key, so
    /// the second run would replace the first one's key and fail to activate. Both wait on the same run instead.
    private static var inFlight: [String: (id: UUID, task: Task<Void, Error>)] = [:]
    /// Bumped when a host is removed, so a registration already talking to hostd cannot save a record for it.
    private static var generations: [String: Int] = [:]

    static func tokenHex(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }

    static func register(host: String, using deps: Dependencies) async throws {
        if let running = inFlight[host] {
            return try await running.task.value
        }
        let generation = generations[host, default: 0]
        let id = UUID()
        let running = Task { try await performRegister(host: host, generation: generation, using: deps) }
        inFlight[host] = (id: id, task: running)
        // A run that lost its host must not clear the entry of the run that replaced it.
        defer { if inFlight[host]?.id == id { inFlight[host] = nil } }
        try await running.value
    }

    /// The order is the point: hostd seals with the new key only after `activate`, which runs only once
    /// the key is in the keychain, so an interrupted run leaves the host on the key the phone already has.
    private static func performRegister(host: String, generation: Int, using deps: Dependencies) async throws {
        guard try await deps.authorize() else { throw PushRegistrationError.notificationsDenied }
        let token = tokenHex(try await deps.deviceToken())
        let reply = try await deps.register(host, token, deps.topic, deps.environment.rawValue)
        // The host may have been removed while hostd was answering; nothing of this run may persist then.
        guard generation == generations[host, default: 0] else {
            throw CancellationError()
        }
        guard let key = Data(base64Encoded: reply.key), key.count == PushCrypto.keyLength else {
            throw PushRegistrationError.undecodableKey(host: host)
        }
        try deps.saveKey(key, host, reply.keyID)
        // The key id is kept before activation: if activation fails, removing the host still finds the key.
        // The token stays that of the last activated key, so a failed first activation is retried on launch.
        var records = deps.records()
        let previous = records[host]
        records[host] = PushRegistrationRecord(
            token: previous?.token ?? "", keyID: previous?.keyID ?? reply.keyID, lastError: nil,
            keyIDs: (previous?.keyIDs ?? []) + [reply.keyID])
        deps.saveRecords(records)
        do {
            try await deps.activate(host, reply.keyID)
        } catch {
            recordFailure(host: host, generation: generation, error: error, using: deps)
            throw error
        }
        guard generation == generations[host, default: 0] else {
            discard(host: host, keyID: reply.keyID, using: deps)
            throw CancellationError()
        }
        records = deps.records()
        records[host]?.token = token
        records[host]?.keyID = reply.keyID
        records[host]?.lastError = nil
        deps.saveRecords(records)
        logger.info("[PicoPush] registered \(host) with key \(reply.keyID)")
    }

    private static func recordFailure(host: String, generation: Int, error: Error, using deps: Dependencies) {
        guard generation == generations[host, default: 0], var record = deps.records()[host] else { return }
        record.lastError = message(for: error)
        var records = deps.records()
        records[host] = record
        deps.saveRecords(records)
    }

    /// Hosts this phone registered with, again, when iOS has since given it a different token.
    static func refreshChangedTokens(using deps: Dependencies) async {
        guard !deps.records().isEmpty else { return }
        let token: String
        do {
            token = tokenHex(try await deps.deviceToken())
        } catch {
            logger.error("[PicoPush] no token on launch: \(error)")
            return
        }
        // Re-read: a host may have been removed, or another run may have registered it, while iOS answered.
        let records = deps.records()
        for (host, record) in records.sorted(by: { $0.key < $1.key }) where record.token != token {
            // An earlier host in this loop suspends, so this one may have been removed in the meantime.
            guard deps.records()[host] != nil else { continue }
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
        if error is ProvisioningProfileError {
            return RemoteHostL10n.string("Pico could not read this build's provisioning profile, so it cannot tell whether to use the APNs sandbox. Rebuild the app with ios-personal-device.sh.")
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

    /// A removed host leaves no key behind and no record that would claim its name is still registered.
    /// The record stays when the keychain refuses, so the removal is retried on the next launch.
    static func forget(host: String) {
        forget(host: host, droppingRecord: false, deleteKey: deleteLiveKey,
               records: Dependencies.liveRecords, saveRecords: Dependencies.saveLiveRecords)
    }

    /// An endpoint edit: the old record no longer describes this host, even when a key could not be deleted.
    static func forgetForReplacedHost(host: String) {
        forget(host: host, droppingRecord: true, deleteKey: deleteLiveKey,
               records: Dependencies.liveRecords, saveRecords: Dependencies.saveLiveRecords)
    }

    private static func deleteLiveKey(host: String, keyID: String) throws {
        try KeychainPushKeyStore(bundle: .main).deleteKey(host: host, keyID: keyID)
    }

    static func forget(
        host: String, droppingRecord: Bool, deleteKey: (_ host: String, _ keyID: String) throws -> Void,
        records loadRecords: () -> [String: PushRegistrationRecord],
        saveRecords: ([String: PushRegistrationRecord]) -> Void
    ) {
        invalidate(host: host)
        var records = loadRecords()
        guard let record = records[host] else { return }
        do {
            for keyID in record.keyIDs {
                try deleteKey(host, keyID)
            }
        } catch {
            logger.error("[PicoPush] could not delete the keys of \(host): \(error)")
            guard droppingRecord else { return }
        }
        records.removeValue(forKey: host)
        saveRecords(records)
        logger.info("[PicoPush] forgot \(host)")
    }

    /// A registration that resumed after its host was removed: drop the key it saved and its record.
    private static func discard(host: String, keyID: String, using deps: Dependencies) {
        do {
            try deps.deleteKey(host, keyID)
        } catch {
            logger.error("[PicoPush] could not delete the key of \(host) after its removal: \(error)")
            return
        }
        var records = deps.records()
        guard var record = records[host], record.keyIDs.contains(keyID) else { return }
        record.keyIDs.removeAll { $0 == keyID }
        guard let newest = record.keyIDs.last else {
            records.removeValue(forKey: host)
            deps.saveRecords(records)
            return
        }
        // A newer run under the same name may have added its key to the staged record; that one stays.
        if record.keyID == keyID { record.keyID = newest }
        records[host] = record
        deps.saveRecords(records)
    }

    /// A removal bumps the generation, so a registration still awaiting hostd cannot persist afterwards.
    static func invalidate(host: String) {
        generations[host, default: 0] += 1
        inFlight[host]?.task.cancel()
        inFlight[host] = nil
    }

    /// Registrations for hosts the user has since removed; `forget` also retries a keychain deletion that failed.
    static func forgetRemovedHosts(existing: Set<String>) {
        for host in Dependencies.liveRecords().keys where !existing.contains(host) {
            forget(host: host)
        }
    }

    /// Stops notices for a host the user is removing, before its SSH settings are gone. Best effort: an old
    /// minis-hostd has no `apns unregister`, and the local key is deleted either way.
    static func unregister(host: String, services: RemoteServices) async {
        if Dependencies.registrationStateIsKnown(for: host), Dependencies.liveRecords()[host] == nil { return }
        invalidate(host: host)
        do {
            _ = try await HostEventClient(runner: services.executor).unregisterAPNs(host: host)
        } catch {
            logger.error("[PicoPush] could not stop notices for \(host) on the host: \(error)")
        }
    }

    /// Set while the stored records cannot be read, because registering again replaces the blob and the
    /// hosts only survive in the backup `liveRecords` keeps. The backup itself stays until the user removes
    /// the app, so a rebuilt list does not throw away what was there.
    static func recordsProblem() -> String? {
        let defaults = UserDefaults.standard
        let hasBackup = defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix(unreadableRecordsKeyPrefix) }
        guard hasBackup else { return nil }
        if let data = defaults.data(forKey: recordsKey),
           (try? JSONDecoder().decode([String: PushRegistrationRecord].self, from: data)) != nil {
            return nil
        }
        return RemoteHostL10n.string("Pico could not read the list of hosts this iPhone registered on. It kept a copy, and Send to This iPhone registers a host again.")
    }

    static func refreshOnLaunch() {
        guard !Dependencies.liveRecords().isEmpty, case .success(let services) = RemoteAppWiring.shared.services else {
            return
        }
        do {
            forgetRemovedHosts(existing: Set(services.store.hosts.map(\.name)))
            let deps = try Dependencies.live(services: services)
            Task { await refreshChangedTokens(using: deps) }
        } catch {
            logger.error("[PicoPush] cannot refresh registrations: \(error)")
        }
    }
}

extension PushRegistration.Dependencies {
    static func saveLiveRecords(_ records: [String: PushRegistrationRecord]) {
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(records), forKey: PushRegistration.recordsKey)
        } catch {
            logger.error("[PicoPush] saving registration records failed: \(error)")
        }
    }

    /// False when the records cannot be trusted, because a retained backup means the current blob may be
    /// missing hosts that were registered before it.
    static func registrationStateIsKnown(for host: String) -> Bool {
        let defaults = UserDefaults.standard
        let hasBackup = defaults.dictionaryRepresentation().keys.contains {
            $0.hasPrefix(PushRegistration.unreadableRecordsKeyPrefix)
        }
        return !hasBackup && recordsAreReadable()
    }

    /// False when the blob exists but does not decode, because then no host's state is known.
    static func recordsAreReadable() -> Bool {
        guard let data = UserDefaults.standard.data(forKey: PushRegistration.recordsKey) else { return true }
        return (try? JSONDecoder().decode([String: PushRegistrationRecord].self, from: data)) != nil
    }

    static func liveRecords() -> [String: PushRegistrationRecord] {
        guard let data = UserDefaults.standard.data(forKey: PushRegistration.recordsKey) else { return [:] }
        do {
            return try JSONDecoder().decode([String: PushRegistrationRecord].self, from: data)
        } catch {
            logger.error("[PicoPush] registration records unreadable: \(error)")
            keepUnreadableRecords(data)
            return [:]
        }
    }

    /// The next registration overwrites the blob, so the bytes are kept under their own key: without them
    /// every other host would silently drop out of the token-change refresh.
    private static func keepUnreadableRecords(_ data: Data) {
        let defaults = UserDefaults.standard
        let alreadyKept = defaults.dictionaryRepresentation().keys.contains {
            $0.hasPrefix(PushRegistration.unreadableRecordsKeyPrefix) && defaults.data(forKey: $0) == data
        }
        guard !alreadyKept else { return }
        let key = PushRegistration.unreadableRecordsKeyPrefix + ISO8601DateFormatter().string(from: Date())
        defaults.set(data, forKey: key)
        logger.info("[PicoPush] kept the unreadable registration records as \(key)")
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
            environment: try ProvisioningProfile.apsEnvironment(profile: profile),
            register: { host, token, topic, environment in
                try await client.registerAPNs(host: host, deviceToken: token, topic: topic, environment: environment)
            },
            saveKey: { key, host, keyID in try keys.setKey(key, host: host, keyID: keyID) },
            deleteKey: { host, keyID in try keys.deleteKey(host: host, keyID: keyID) },
            activate: { host, keyID in _ = try await client.activateAPNs(host: host, keyID: keyID) },
            records: liveRecords,
            saveRecords: saveLiveRecords)
    }
}
