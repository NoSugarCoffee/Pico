import Foundation
import MinisRemote
import XCTest
@testable import Minis

@MainActor
final class HostNotificationsModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(type, from: Data(json.utf8))
    }

    private func failingGmail() throws -> HostdSourceStatus {
        try decode(HostdSourceStatus.self, #"{"name":"gmail","kind":"imap","state":"error","lastError":"Gmail rejected the app password"}"#)
    }

    private func status(heartbeatAt: Date?, sources: [HostdSourceStatus] = []) throws -> HostdStatus {
        let heartbeat = heartbeatAt.map { String($0.timeIntervalSince1970) } ?? "null"
        let encodedSources = String(decoding: try JSONEncoder().encode(sources), as: UTF8.self)
        return try decode(HostdStatus.self, #"{"version":"0.1.0","heartbeatAt":\#(heartbeat),"sources":\#(encodedSources)}"#)
    }

    // MARK: Install command

    func testInstallCommandPinsVersionAndScriptURL() {
        XCTAssertEqual(
            HostNotificationsModel.installCommand(hostName: "mini"),
            "curl -fsSL https://raw.githubusercontent.com/NoSugarCoffee/Pico/main/host/minis-hostd/scripts/install.sh | sh -s -- --host-name 'mini' --version 0.3.0")
        XCTAssertEqual(HostdRelease.version, "0.3.0")
    }

    func testInstallCommandQuotesHostNameWithQuoteAndSpace() {
        let command = HostNotificationsModel.installCommand(hostName: "bob's mini")
        XCTAssertTrue(command.contains(#"--host-name 'bob'\''s mini' --version 0.3.0"#), command)
    }

    // MARK: Status

    func testFreshHeartbeatIsRunning() throws {
        let source = try failingGmail()
        let mapped = HostNotificationsModel.status(
            .success(try status(heartbeatAt: now.addingTimeInterval(-170), sources: [source])), host: "mini", now: now)
        XCTAssertEqual(mapped, .reported(.running, sources: [source]))
    }

    func testHeartbeatAheadOfPhoneClockIsRunning() throws {
        XCTAssertEqual(
            HostNotificationsModel.runState(try status(heartbeatAt: now.addingTimeInterval(30)), now: now), .running)
    }

    func testStaleHeartbeatIsNotRunningSinceHeartbeat() throws {
        let heartbeat = now.addingTimeInterval(-181)
        XCTAssertEqual(
            HostNotificationsModel.status(.success(try status(heartbeatAt: heartbeat)), host: "mini", now: now),
            .reported(.notRunning(since: heartbeat), sources: []))
    }

    func testMissingHeartbeatIsNotRunningWithoutTime() throws {
        XCTAssertEqual(
            HostNotificationsModel.runState(try status(heartbeatAt: nil), now: now), .notRunning(since: nil))
    }

    func testNotInstalled() {
        XCTAssertEqual(
            HostNotificationsModel.status(.failure(HostEventError.notInstalled(host: "mini")), host: "mini", now: now),
            .notInstalled(host: "mini"))
        XCTAssertEqual(HostNotificationsModel.notInstalledMessage(host: "mini"), "minis-hostd is not installed on mini.")
    }

    func testServerErrorUsesUserMessage() {
        let error = HostEventError.server(code: "store", message: "database is locked")
        XCTAssertEqual(
            HostNotificationsModel.status(.failure(error), host: "mini", now: now),
            .failed(message: error.userMessage))
    }

    func testConnectionErrorUsesSettingsWording() {
        XCTAssertEqual(
            HostNotificationsModel.status(.failure(RemoteHostError.unreachable(host: "mini")), host: "mini", now: now),
            .failed(message: "“mini” is unreachable. Is Tailscale on?"))
    }

    // MARK: Decision and reason labels

    func testReasonLabelsCoverEveryGateReason() {
        let expected: [String: String] = [
            "allowed": "Matched your rules",
            "malformed_sender": "No single sender address",
            "too_old": "Older than 48 hours",
            "automated": "Automated or bulk mail",
            "sender_not_allowed": "Sender not on the allowlist",
            "sender_unauthenticated": "Sender failed DMARC",
            "reason_not_kept": "GitHub reason not kept",
            "repo_not_kept": "Repository not kept",
        ]
        for (reason, label) in expected {
            XCTAssertEqual(HostNotificationsModel.reasonLabel(reason), label, reason)
        }
    }

    func testUnknownReasonShowsRawValue() {
        XCTAssertEqual(HostNotificationsModel.reasonLabel("quiet_hours"), "Other reason (quiet_hours)")
    }

    func testDecisionLabels() {
        XCTAssertEqual(HostNotificationsModel.decisionLabel("push"), "Matched the rules")
        XCTAssertEqual(HostNotificationsModel.decisionLabel("store_only"), "Stored without a push")
        XCTAssertEqual(HostNotificationsModel.decisionLabel("drop"), "Dropped")
        XCTAssertEqual(HostNotificationsModel.decisionLabel("held"), "held")
    }
}
