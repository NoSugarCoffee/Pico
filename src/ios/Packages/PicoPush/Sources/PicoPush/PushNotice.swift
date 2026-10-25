import CryptoKit
import Foundation

/// The `pico` object hostd puts beside `aps` (apns spec §3): `k` names the key, `c` is base64 of
/// nonce ‖ ciphertext ‖ tag.
public struct PushEnvelope: Decodable, Equatable, Sendable {
    public static let version = 1

    public let v: Int
    public let host: String
    public let k: String
    public let c: String

    public init(v: Int, host: String, k: String, c: String) {
        self.v = v
        self.host = host
        self.k = k
        self.c = c
    }

    public init(userInfo: [AnyHashable: Any]) throws {
        guard let object = userInfo["pico"], JSONSerialization.isValidJSONObject(object) else {
            throw PushOpenError.notAPicoNotice
        }
        do {
            self = try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: object))
        } catch {
            throw PushOpenError.notAPicoNotice
        }
        guard v == Self.version else { throw PushOpenError.unsupportedVersion(v) }
    }
}

/// What the user sees once the extension has opened the envelope.
public struct SealedNotice: Codable, Equatable, Sendable {
    public let title: String
    public let body: String
    public let url: String?

    public init(title: String, body: String, url: String?) {
        self.title = title
        self.body = body
        self.url = url
    }
}

public enum PushOpenError: Error, Equatable, Sendable {
    case notAPicoNotice
    case unsupportedVersion(Int)
    case noKey(host: String)
    case undecryptable(host: String)
}

public enum PushCrypto {
    /// Must match hostd's `notify.AdditionalData`: it ties a notice to its host.
    public static func additionalData(host: String) -> Data {
        Data("pico-push-v1:\(host)".utf8)
    }

    public static func open(_ envelope: PushEnvelope, key: Data) throws -> SealedNotice {
        guard let combined = Data(base64Encoded: envelope.c) else {
            throw PushOpenError.undecryptable(host: envelope.host)
        }
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            let plaintext = try AES.GCM.open(
                box, using: SymmetricKey(data: key), authenticating: additionalData(host: envelope.host))
            return try JSONDecoder().decode(SealedNotice.self, from: plaintext)
        } catch {
            throw PushOpenError.undecryptable(host: envelope.host)
        }
    }

    /// The text shown when a notice cannot be opened, so a stale key is fixed rather than ignored.
    public static func failureBody(host: String) -> String {
        "Pico could not decrypt this notice. Open Settings → Remote Hosts → \(host) → Notifications and tap Send to This iPhone."
    }

    /// Shown when the failure has no host to name, such as a keychain the extension cannot reach.
    public static let unopenableBody =
        "Pico could not open this notice. Open Settings → Remote Hosts → your host → Notifications and tap Send to This iPhone."
}

/// Where the extension leaves the decrypted link for the app's tap handler.
public enum PushUserInfo {
    public static let urlKey = "pico_url"
}
