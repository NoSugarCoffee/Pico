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
                return HostdAPNsRegistration(keyID: "k-\(host)", key: Data(repeating: 1, count: 32).base64EncodedString())
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
        } catch {
            XCTAssertTrue(error is SaveFailed, "\(error)")
        }
        XCTAssertTrue(recorder.steps.contains { $0.hasPrefix("save mac-mini") })
        XCTAssertFalse(recorder.steps.contains { $0.hasPrefix("activate") })
        XCTAssertNil(recorder.records["mac-mini"])
    }

    func testTwoRegistrationsOfOneHostRunOnce() async throws {
        let recorder = Recorder()
        var dependencies = deps(recorder)
        var hostCalls = 0
        dependencies.register = { host, _, _, _ in
            hostCalls += 1
            try await Task.sleep(nanoseconds: 30_000_000)
            return HostdAPNsRegistration(keyID: "k-\(host)", key: Data(repeating: 1, count: 32).base64EncodedString())
        }
        async let first: Void = PushRegistration.register(host: "mac-mini", using: dependencies)
        async let second: Void = PushRegistration.register(host: "mac-mini", using: dependencies)
        _ = try await (first, second)
        XCTAssertEqual(hostCalls, 1)
    }

    func testAKeyThatIsNotAES256IsRefusedBeforeSaving() async {
        let recorder = Recorder()
        var dependencies = deps(recorder)
        dependencies.register = { host, token, topic, environment in
            recorder.steps.append("register \(host) \(token) \(topic) \(environment)")
            return HostdAPNsRegistration(keyID: "k-\(host)", key: Data([1, 2, 3]).base64EncodedString())
        }
        do {
            try await PushRegistration.register(host: "mac-mini", using: dependencies)
            XCTFail("saved a key CryptoKit cannot use")
        } catch {
            XCTAssertEqual(error as? PushRegistrationError, .undecodableKey(host: "mac-mini"))
        }
        XCTAssertEqual(recorder.steps, ["register mac-mini 0f1e com.example.pico development"])
        XCTAssertNil(recorder.records["mac-mini"])
    }

    func testUnreadableRecordsAreKeptAsideAndReported() throws {
        let defaults = UserDefaults.standard
        let saved = defaults.data(forKey: PushRegistration.recordsKey)
        let existingBackups = Set(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(PushRegistration.unreadableRecordsKeyPrefix) })
        defer {
            if let saved {
                defaults.set(saved, forKey: PushRegistration.recordsKey)
            } else {
                defaults.removeObject(forKey: PushRegistration.recordsKey)
            }
            for key in defaults.dictionaryRepresentation().keys
            where key.hasPrefix(PushRegistration.unreadableRecordsKeyPrefix) && !existingBackups.contains(key) {
                defaults.removeObject(forKey: key)
            }
        }
        defaults.set(Data("not a records blob".utf8), forKey: PushRegistration.recordsKey)
        XCTAssertTrue(PushRegistration.Dependencies.liveRecords().isEmpty)
        let backups = defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(PushRegistration.unreadableRecordsKeyPrefix) && !existingBackups.contains($0) }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(defaults.data(forKey: try XCTUnwrap(backups.first)), Data("not a records blob".utf8))
        XCTAssertNotNil(PushRegistration.recordsProblem())

        // Rebuilding one host writes a blob that decodes: the warning goes, the copy stays for recovery.
        let rebuilt = ["mac-mini": PushRegistrationRecord(token: "0f1e", keyID: "k1", lastError: nil)]
        defaults.set(try JSONEncoder().encode(rebuilt), forKey: PushRegistration.recordsKey)
        XCTAssertNil(PushRegistration.recordsProblem())
        XCTAssertEqual(defaults.data(forKey: try XCTUnwrap(backups.first)), Data("not a records blob".utf8))
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
