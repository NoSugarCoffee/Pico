import CryptoKit
import Foundation
import MinisRemote
import PicoPush
import XCTest
@testable import Minis

@MainActor
final class PushRegistrationTests: XCTestCase {
    private struct SaveFailed: Error {}

    private final class Recorder {
        var steps: [String] = []
        var records: [String: PushRegistrationRecord] = [:]
        var token = Data([0x0f, 0x1e])
        var failSave = false
        var authorized = true
    }

    private func deps(_ recorder: Recorder) -> PushRegistration.Dependencies {
        PushRegistration.Dependencies(
            authorize: { recorder.authorized },
            deviceToken: { recorder.token },
            topic: "com.example.pico",
            environment: .development,
            register: { host, token, topic, environment in
                recorder.steps.append("register \(host) \(token) \(topic) \(environment)")
                return HostdAPNsRegistration(keyId: "k-\(host)", key: Data(repeating: 1, count: 32).base64EncodedString())
            },
            saveKey: { key, host, keyID in
                recorder.steps.append("save \(host) \(keyID) \(key.count)")
                if recorder.failSave { throw SaveFailed() }
            },
            activate: { host, keyID in recorder.steps.append("activate \(host) \(keyID)") },
            records: { recorder.records },
            saveRecords: { recorder.records = $0 })
    }

    func testRegistersThenSavesTheKeyThenActivates() async throws {
        let recorder = Recorder()
        try await PushRegistration.register(host: "mac-mini", using: deps(recorder))
        XCTAssertEqual(recorder.steps, [
            "register mac-mini 0f1e com.example.pico development",
            "save mac-mini k-mac-mini 32",
            "activate mac-mini k-mac-mini",
        ])
        XCTAssertEqual(recorder.records["mac-mini"], PushRegistrationRecord(token: "0f1e", keyID: "k-mac-mini", lastError: nil))
    }

    func testAKeyThatWasNotSavedIsNeverActivated() async {
        let recorder = Recorder()
        recorder.failSave = true
        do {
            try await PushRegistration.register(host: "mac-mini", using: deps(recorder))
            XCTFail("registered without saving the key")
        } catch {}
        XCTAssertFalse(recorder.steps.contains { $0.hasPrefix("activate") })
        XCTAssertNil(recorder.records["mac-mini"])
    }

    func testDeniedNotificationsStopBeforeTheHost() async {
        let recorder = Recorder()
        recorder.authorized = false
        do {
            try await PushRegistration.register(host: "mac-mini", using: deps(recorder))
            XCTFail("registered with notifications off")
        } catch {
            XCTAssertEqual(error as? PushRegistrationError, .notificationsDenied)
        }
        XCTAssertEqual(recorder.steps, [])
    }

    func testLaunchReRegistersOnlyHostsWithAnOldToken() async {
        let recorder = Recorder()
        recorder.records = [
            "current": PushRegistrationRecord(token: "0f1e", keyID: "k1", lastError: nil),
            "stale": PushRegistrationRecord(token: "aaaa", keyID: "k2", lastError: nil),
        ]
        await PushRegistration.refreshChangedTokens(using: deps(recorder))
        XCTAssertEqual(recorder.steps.first, "register stale 0f1e com.example.pico development")
        XCTAssertFalse(recorder.steps.contains { $0.contains("current") })
        XCTAssertEqual(recorder.records["stale"]?.token, "0f1e")
    }

    func testAFailedLaunchRefreshKeepsTheOldRecordAndShowsTheError() async {
        let recorder = Recorder()
        recorder.failSave = true
        recorder.records = ["stale": PushRegistrationRecord(token: "aaaa", keyID: "k2", lastError: nil)]
        await PushRegistration.refreshChangedTokens(using: deps(recorder))
        XCTAssertEqual(recorder.records["stale"]?.token, "aaaa")
        XCTAssertEqual(recorder.records["stale"]?.keyID, "k2")
        XCTAssertNotNil(recorder.records["stale"]?.lastError)
    }

    func testAnOldHostdIsAskedToUpdate() {
        let error = HostEventError.server(code: "bad_request", message: "unknown command \"apns register\"")
        XCTAssertTrue(PushRegistration.message(for: error).contains("too old"))
    }

    func testATapUsesTheLinkTheExtensionLeft() {
        let url = PushTap.link(userInfo: [PushUserInfo.urlKey: "pico://host-event/mac-mini/01A"], keys: { InMemoryPushKeyStore() })
        XCTAssertEqual(url?.absoluteString, "pico://host-event/mac-mini/01A")
    }

    func testATapWithoutTheExtensionOpensTheEnvelope() throws {
        let key = SymmetricKey(size: .bits256)
        let notice = try JSONEncoder().encode(SealedNotice(title: "t", body: "b", url: "pico://host-event/mac-mini/01B"))
        let sealed = try AES.GCM.seal(notice, using: key, authenticating: PushCrypto.additionalData(host: "mac-mini"))
        let userInfo: [AnyHashable: Any] = ["pico": ["v": 1, "host": "mac-mini", "k": "k1", "c": try XCTUnwrap(sealed.combined).base64EncodedString()]]
        let keys = InMemoryPushKeyStore()
        try keys.setKey(key.withUnsafeBytes { Data($0) }, host: "mac-mini", keyID: "k1")
        XCTAssertEqual(PushTap.link(userInfo: userInfo, keys: { keys })?.absoluteString, "pico://host-event/mac-mini/01B")
        XCTAssertNil(PushTap.link(userInfo: userInfo, keys: { InMemoryPushKeyStore() }))
    }

    func testOtherNotificationsHaveNoPicoLink() {
        XCTAssertNil(PushTap.link(userInfo: ["sessionId": "s1"], keys: { InMemoryPushKeyStore() }))
    }
}
