import Foundation
import Security

/// AES keys by host and key id, in a keychain group the app and its notification extension share.
/// Earlier keys are kept so notices APNs still holds from before a re-registration open (apns spec §4).
public protocol PushKeyStore: Sendable {
    func setKey(_ key: Data, host: String, keyID: String) throws
    func key(host: String, keyID: String) throws -> Data?
}

public enum PushKeyStoreError: Error, Equatable {
    case keychain(operation: String, status: Int32)
    case missingAccessGroup
}

/// Verified in-app only: unsigned `swift test` binaries lack keychain entitlements.
public struct KeychainPushKeyStore: PushKeyStore {
    static let service = "pico.push-key"
    /// Set in both Info.plists from `$(AppIdentifierPrefix)`, which only the build knows.
    static let accessGroupInfoKey = "PicoPushKeychainGroup"

    private let accessGroup: String

    public init(accessGroup: String) {
        self.accessGroup = accessGroup
    }

    public init(bundle: Bundle) throws {
        guard let group = bundle.object(forInfoDictionaryKey: Self.accessGroupInfoKey) as? String,
              !group.isEmpty, !group.hasPrefix(".") else {
            throw PushKeyStoreError.missingAccessGroup
        }
        self.init(accessGroup: group)
    }

    private func baseQuery(host: String, keyID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: "\(host)/\(keyID)",
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: false,
        ]
    }

    public func setKey(_ key: Data, host: String, keyID: String) throws {
        let query = baseQuery(host: host, keyID: keyID)
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: key] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw PushKeyStoreError.keychain(operation: "update", status: updateStatus)
        }
        var addQuery = query
        addQuery[kSecValueData as String] = key
        // The extension runs while the phone is locked, so the key must be readable after first unlock.
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw PushKeyStoreError.keychain(operation: "add", status: addStatus)
        }
    }

    public func key(host: String, keyID: String) throws -> Data? {
        var query = baseQuery(host: host, keyID: keyID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw PushKeyStoreError.keychain(operation: "get", status: status)
        }
        return result as? Data
    }
}

public final class InMemoryPushKeyStore: PushKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: Data] = [:]

    public init() {}

    public func setKey(_ key: Data, host: String, keyID: String) throws {
        lock.withLock { keys["\(host)/\(keyID)"] = key }
    }

    public func key(host: String, keyID: String) throws -> Data? {
        lock.withLock { keys["\(host)/\(keyID)"] }
    }
}

public enum PushNoticeOpener {
    public static func open(userInfo: [AnyHashable: Any], keys: any PushKeyStore) throws -> SealedNotice {
        let envelope = try PushEnvelope(userInfo: userInfo)
        guard let key = try keys.key(host: envelope.host, keyID: envelope.k) else {
            throw PushOpenError.noKey(host: envelope.host)
        }
        return try PushCrypto.open(envelope, key: key)
    }
}
