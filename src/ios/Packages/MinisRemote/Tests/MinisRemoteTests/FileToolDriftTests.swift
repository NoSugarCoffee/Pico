import Crypto
import Foundation
import XCTest

/// FileToolLogic is a port of the app's local file_read / file_edit (upstream code the fork leaves untouched).
/// When upstream changes one of these functions, remote and local behaviour drift apart unless the change is
/// ported, so this test pins each function's source.
final class FileToolDriftTests: XCTestCase {
    private static let chatDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // MinisRemoteTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // MinisRemote
        .deletingLastPathComponent()  // Packages
        .deletingLastPathComponent()  // src/ios
        .appendingPathComponent("Agent/Chat")

    /// SHA-256 of each function's source, from its `func` line through its closing brace, per upstream file,
    /// as of 1a71df0 (1.15). 1.15 moved the matching into `FileToolIO.applyEdit` unchanged and read and
    /// edit off the main thread; neither changes what the remote tools do over SSH.
    private static let recordedFingerprints: [String: [String: String]] = [
        "AIChatViewModel+FileTools.swift": [
            "executeFileRead": "0c9bdfd0c8f872ebf35b288c3ff1206a6d2bb5d460f751f62316fd7eefbb563e",
            "executeFileEdit": "5ffb0b0ec06faf943d23fb3a5e52c0e4257243f8bff9869070b49106bddd6964",
        ],
        "FileToolIO.swift": [
            "applyEdit": "d47e6564a0f76a2c7326b128df9d5a1ee7df292af9aeba7c157537431ccbf77f",
            "findAllRanges": "bff5279614800df01b5bf3c7527fb2ca649e210b3118c09ab022ac2253804657",
            "normalizeForFuzzyMatch": "b569839b468faddac10f1b0588d74234dedd9606050abea1105c67588857130f",
            "buildFileEditPreview": "a2a2ea1e6f018e2516cf2904b9b3da90b5255fa68640af3663d1abfab5443a6d",
        ],
    ]

    func testPortedUpstreamFileToolFunctionsAreUnchanged() throws {
        for (file, functions) in Self.recordedFingerprints.sorted(by: { $0.key < $1.key }) {
            let source = try String(contentsOf: Self.chatDirectory.appendingPathComponent(file), encoding: .utf8)
            for (name, recorded) in functions.sorted(by: { $0.key < $1.key }) {
                let body = try XCTUnwrap(
                    Self.functionSource(named: name, in: source),
                    "`func \(name)(` is gone from \(file). Find where upstream moved it and port the change into FileToolLogic.")
                XCTAssertEqual(
                    Self.fingerprint(body), recorded,
                    "Upstream changed `\(name)` in \(file). Port the change into FileToolLogic (the remote file_read/file_edit) so remote and local tools behave alike, then record the new fingerprint here.")
            }
        }
    }

    static func functionSource(named name: String, in source: String) -> String? {
        let lines = source.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.contains("func \(name)(") }) else { return nil }
        var depth = 0
        var opened = false
        for index in start..<lines.count {
            for character in lines[index] {
                if character == "{" { depth += 1; opened = true }
                if character == "}" { depth -= 1 }
            }
            if opened && depth == 0 {
                return lines[start...index].joined(separator: "\n")
            }
        }
        return nil
    }

    static func fingerprint(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func testFunctionSourceStopsAtTheMatchingBrace() {
        let source = "a\nfunc f(x: Int) {\n    if x > 0 { g() }\n}\nfunc h() {}\n"
        XCTAssertEqual(Self.functionSource(named: "f", in: source), "func f(x: Int) {\n    if x > 0 { g() }\n}")
        XCTAssertNil(Self.functionSource(named: "missing", in: source))
    }
}
