import CryptoKit
import Foundation
import XCTest
@testable import PicoPush

final class PushNoticeTests: XCTestCase {
    private static let vectorURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // PicoPushTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // PicoPush
        .deletingLastPathComponent() // Packages
        .deletingLastPathComponent() // ios
        .deletingLastPathComponent() // src
        .deletingLastPathComponent() // repository root
        .appendingPathComponent("host/minis-hostd/testdata/contract/apns_payload.json")

    private struct Vector {
        let key: Data
        let userInfo: [AnyHashable: Any]
        let notice: SealedNotice
    }

    /// Decoded the way iOS hands a remote notification's payload to the extension: a JSON dictionary.
    private func vector() throws -> Vector {
        let data = try Data(contentsOf: Self.vectorURL)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let key = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(object["key"] as? String)))
        let payload = try XCTUnwrap(object["payload"] as? [String: Any])
        let notice = try JSONDecoder().decode(
            SealedNotice.self, from: JSONSerialization.data(withJSONObject: try XCTUnwrap(object["notice"])))
        return Vector(key: key, userInfo: payload, notice: notice)
    }

    func testOpensTheNoticeHostdSealed() throws {
        let vector = try vector()
        let keys = InMemoryPushKeyStore()
        try keys.setKey(vector.key, host: "mac-mini", keyID: "0123456789abcdef")
        XCTAssertEqual(try PushNoticeOpener.open(userInfo: vector.userInfo, keys: keys), vector.notice)
    }

    func testANoticeIsBoundToItsHost() throws {
        let vector = try vector()
        let envelope = try PushEnvelope(userInfo: vector.userInfo)
        let relabelled = PushEnvelope(v: envelope.v, host: "other-host", k: envelope.k, c: envelope.c)
        XCTAssertThrowsError(try PushCrypto.open(relabelled, key: vector.key)) {
            XCTAssertEqual($0 as? PushOpenError, .undecryptable(host: "other-host"))
        }
    }

    func testAStaleKeyIsUndecryptable() throws {
        let vector = try vector()
        let keys = InMemoryPushKeyStore()
        try keys.setKey(Data(repeating: 7, count: 32), host: "mac-mini", keyID: "0123456789abcdef")
        XCTAssertThrowsError(try PushNoticeOpener.open(userInfo: vector.userInfo, keys: keys)) {
            XCTAssertEqual($0 as? PushOpenError, .undecryptable(host: "mac-mini"))
        }
    }

    func testAnEarlierKeyStillOpensNoticesSealedWithIt() throws {
        let vector = try vector()
        let keys = InMemoryPushKeyStore()
        try keys.setKey(vector.key, host: "mac-mini", keyID: "0123456789abcdef")
        try keys.setKey(Data(repeating: 9, count: 32), host: "mac-mini", keyID: "fedcba9876543210")
        XCTAssertEqual(try PushNoticeOpener.open(userInfo: vector.userInfo, keys: keys), vector.notice)
    }

    func testAHostWithoutAKeyIsNamed() throws {
        XCTAssertThrowsError(try PushNoticeOpener.open(userInfo: try vector().userInfo, keys: InMemoryPushKeyStore())) {
            XCTAssertEqual($0 as? PushOpenError, .noKey(host: "mac-mini"))
        }
    }

    func testOtherNotificationsAreNotPicoNotices() {
        XCTAssertThrowsError(try PushEnvelope(userInfo: ["aps": ["alert": "hi"]])) {
            XCTAssertEqual($0 as? PushOpenError, .notAPicoNotice)
        }
        XCTAssertThrowsError(try PushEnvelope(userInfo: ["pico": ["v": 2, "host": "h", "k": "", "c": ""]])) {
            XCTAssertEqual($0 as? PushOpenError, .unsupportedVersion(2))
        }
    }

    func testABrokenEnvelopeIsNotMistakenForSomebodyElsesNotice() {
        XCTAssertThrowsError(try PushEnvelope(userInfo: ["pico": ["host": "mac-mini"]])) {
            XCTAssertEqual($0 as? PushOpenError, .malformedNotice)
        }
    }

    func testAuthenticBytesThatDoNotDecodeAreMalformed() throws {
        let key = SymmetricKey(size: .bits256)
        let sealed = try AES.GCM.seal(
            Data("not a notice".utf8), using: key, authenticating: PushCrypto.additionalData(host: "mac-mini"))
        let envelope = PushEnvelope(
            v: 1, host: "mac-mini", k: "k1", c: try XCTUnwrap(sealed.combined).base64EncodedString())
        XCTAssertThrowsError(try PushCrypto.open(envelope, key: key.withUnsafeBytes { Data($0) })) {
            XCTAssertEqual($0 as? PushOpenError, .malformedNotice)
        }
    }

    func testAPSEnvironmentComesFromTheProfile() {
        func profile(_ environment: String?) -> Data {
            let entitlement = environment.map { "<key>aps-environment</key><string>\($0)</string>" } ?? ""
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict><key>Entitlements</key><dict>\(entitlement)</dict></dict></plist>
            """
            return Data([0x30, 0x82, 0x01]) + Data(plist.utf8) + Data([0xA0, 0x00])
        }
        XCTAssertEqual(try ProvisioningProfile.apsEnvironment(profile: profile("development")), .development)
        XCTAssertEqual(try ProvisioningProfile.apsEnvironment(profile: profile("production")), .production)
        XCTAssertEqual(try ProvisioningProfile.apsEnvironment(profile: nil), .production)
    }

    func testAnUnreadableProfileThrowsInsteadOfClaimingProduction() {
        XCTAssertThrowsError(try ProvisioningProfile.apsEnvironment(profile: Data("not a profile".utf8))) {
            XCTAssertEqual($0 as? ProvisioningProfileError, .unreadable)
        }
        XCTAssertThrowsError(try ProvisioningProfile.apsEnvironment(profile: Data())) {
            XCTAssertEqual($0 as? ProvisioningProfileError, .unreadable)
        }
    }
}
