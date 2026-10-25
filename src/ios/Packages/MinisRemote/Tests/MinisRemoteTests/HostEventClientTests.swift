import Foundation
import XCTest
@testable import MinisRemote

final class HostEventLinkTests: XCTestCase {
    private func parse(_ string: String) -> HostEventLink? {
        HostEventLinks.parse(URL(string: string)!)
    }

    func testParsesEventAndBatchLinks() {
        XCTAssertEqual(parse("pico://host-event/mac-mini/01JS0000000000000000000001"),
                       .event(host: "mac-mini", id: "01JS0000000000000000000001"))
        XCTAssertEqual(parse("pico://host-event/mac_mini/batch/01JSBATCH"),
                       .batch(host: "mac_mini", id: "01JSBATCH"))
    }

    func testParsesLinksFromHostdBeforePicoScheme() {
        XCTAssertEqual(parse("minis://host-event/mac-mini/01A"), .event(host: "mac-mini", id: "01A"))
        XCTAssertEqual(parse("minis://host-event/mac_mini/batch/01JSBATCH"), .batch(host: "mac_mini", id: "01JSBATCH"))
    }

    func testRejectsEverythingElse() {
        let rejected = [
            "minis://host-event/mac-mini",
            "minis://host-event/mac-mini/",
            "minis://host-event/mac-mini/01A/extra",
            "minis://host-event/mac-mini/batch/",
            "minis://host-event/mac-mini/batch/01A/extra",
            "minis://host-event/mac-mini/01A?x=1",
            "minis://host-event/mac-mini/01A#x",
            "minis://host-event/mac%20mini/01A",
            "minis://host-event/mac-mini/01A%3Brm",
            "minis://host-event/../01A",
            "minis://open_terminal/mac-mini/01A",
            "pico://open_terminal/mac-mini/01A",
            "https://host-event/mac-mini/01A",
        ]
        for link in rejected {
            XCTAssertNil(parse(link), link)
        }
    }
}

final class HostEventClientTests: XCTestCase {
    private actor RecordingRunner: HostControlRunner {
        let result: ExecResult
        private(set) var scripts: [String] = []

        init(stdout: String, exitStatus: Int, stderr: String = "") {
            result = ExecResult(stdout: Array(stdout.utf8), stderr: Array(stderr.utf8), exitStatus: exitStatus)
        }

        func runControlScript(host: String, script: String) async throws -> ExecResult {
            scripts.append(script)
            return result
        }
    }

    func testAckQuotesEachIDAndDecodesTheReply() async throws {
        let runner = RecordingRunner(stdout: #"{"schemaVersion":1,"ok":true}"# + "\n", exitStatus: 0)
        let reply = try await HostEventClient(runner: runner).ack(host: "mac-mini", ids: ["01A", "01B"])
        XCTAssertTrue(reply.ok)
        let scripts = await runner.scripts
        XCTAssertEqual(scripts, [#""$HOME/.minis/bin/minis-hostd" 'events' 'ack' '01A' '01B' --json"#])
    }

    func testUnregisterAPNsAsksHostdToForgetThePhone() async throws {
        let runner = RecordingRunner(stdout: #"{"schemaVersion":1,"ok":true}"# + "\n", exitStatus: 0)
        let reply = try await HostEventClient(runner: runner).unregisterAPNs(host: "mac-mini")
        XCTAssertTrue(reply.ok)
        let scripts = await runner.scripts
        XCTAssertEqual(scripts, [#""$HOME/.minis/bin/minis-hostd" 'apns' 'unregister' --json"#])
    }

    func testRegisterAPNsQuotesItsArgumentsAndReturnsTheKey() async throws {
        let runner = RecordingRunner(stdout: #"{"schemaVersion":1,"keyId":"0a1b","key":"AAEC"}"# + "\n", exitStatus: 0)
        let reply = try await HostEventClient(runner: runner).registerAPNs(
            host: "mac-mini", deviceToken: "0f1e", topic: "com.example.pico", environment: "development")
        XCTAssertEqual(reply, HostdAPNsRegistration(keyID: "0a1b", key: "AAEC"))
        let scripts = await runner.scripts
        XCTAssertEqual(scripts, [
            #""$HOME/.minis/bin/minis-hostd" 'apns' 'register' '0f1e' '--topic' 'com.example.pico' '--environment' 'development' --json"#,
        ])
    }

    func testExit2IsTheServersError() async {
        let line = #"{"schemaVersion":1,"error":{"code":"not_found","message":"No event 01Z."}}"#
        let runner = RecordingRunner(stdout: line, exitStatus: 2, stderr: "minis-hostd: No event 01Z.")
        await assertThrows(HostEventError.server(code: "not_found", message: "No event 01Z."), runner: runner)
    }

    func testExit127MeansNotInstalled() async {
        let runner = RecordingRunner(stdout: "", exitStatus: 127, stderr: "/bin/sh: minis-hostd: not found")
        await assertThrows(HostEventError.notInstalled(host: "mac-mini"), runner: runner)
    }

    func testNewerContractIsRefused() async {
        let runner = RecordingRunner(stdout: #"{"schemaVersion":2,"ok":true}"#, exitStatus: 0)
        await assertThrows(HostEventError.schemaMismatch(host: "mac-mini", found: 2), runner: runner)
    }

    func testOtherExitStatusCarriesStderr() async {
        let runner = RecordingRunner(stdout: "", exitStatus: 1, stderr: "segfault\n")
        await assertThrows(HostEventError.unexpectedExit(host: "mac-mini", status: 1, stderr: "segfault"), runner: runner)
    }

    func testGarbageIsUndecodable() async {
        let runner = RecordingRunner(stdout: "not json", exitStatus: 0)
        do {
            _ = try await HostEventClient(runner: runner).ack(host: "mac-mini", ids: ["01A"])
            XCTFail("expected an error")
        } catch HostEventError.undecodable(let host, _) {
            XCTAssertEqual(host, "mac-mini")
        } catch {
            XCTFail("\(error)")
        }
    }

    func testNotFoundMessageExplainsRetention() {
        let message = HostEventError.server(code: "not_found", message: "No event 01Z.").userMessage
        XCTAssertEqual(message, "No event 01Z. It may be older than 30 days and deleted on the host.")
    }

    private func assertThrows(_ expected: HostEventError, runner: RecordingRunner,
                              file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await HostEventClient(runner: runner).ack(host: "mac-mini", ids: ["01A"])
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as HostEventError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("\(error)", file: file, line: line)
        }
    }
}
