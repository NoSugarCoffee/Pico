import Foundation

// The shapes minis-hostd prints (B spec §8). Golden files in host/minis-hostd/testdata/contract/ are
// decoded by HostEventContractTests, so a change on either side fails a test.

public enum HostEventSource: String, Codable, Sendable {
    case mail
    case github
}

public struct HostEventSummary: Codable, Equatable, Sendable {
    public let id: String
    public let source: HostEventSource
    public let createdAt: Date
    public let title: String
    public let summary: String
    public let decision: String
    public let reason: String
    public let ackedAt: Date?
}

public struct MailAddress: Codable, Equatable, Sendable {
    public let name: String
    public let address: String
}

public struct MailAttachment: Codable, Equatable, Sendable {
    public let name: String
    public let type: String
    public let size: Int
}

public struct MailEventBody: Codable, Equatable, Sendable {
    public let from: MailAddress
    public let to: [MailAddress]
    public let subject: String
    public let date: Date
    public let messageId: String
    public let text: String
    public let truncated: Bool
    public let attachments: [MailAttachment]
}

public struct GitHubEventBody: Codable, Equatable, Sendable {
    public let repo: String
    public let reason: String
    public let subjectType: String
    public let subjectTitle: String
    public let htmlUrl: String
    public let threadId: String
    public let updatedAt: Date
}

public enum HostEventBody: Equatable, Sendable {
    case mail(MailEventBody)
    case github(GitHubEventBody)
}

public struct HostEvent: Decodable, Equatable, Sendable {
    public let id: String
    public let source: HostEventSource
    public let createdAt: Date
    public let title: String
    public let summary: String
    public let decision: String
    public let reason: String
    public let ackedAt: Date?
    public let url: String
    public let body: HostEventBody

    private enum CodingKeys: String, CodingKey {
        case id, source, createdAt, title, summary, decision, reason, ackedAt, url, body
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        source = try c.decode(HostEventSource.self, forKey: .source)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        title = try c.decode(String.self, forKey: .title)
        summary = try c.decode(String.self, forKey: .summary)
        decision = try c.decode(String.self, forKey: .decision)
        reason = try c.decode(String.self, forKey: .reason)
        ackedAt = try c.decodeIfPresent(Date.self, forKey: .ackedAt)
        url = try c.decode(String.self, forKey: .url)
        switch source {
        case .mail: body = .mail(try c.decode(MailEventBody.self, forKey: .body))
        case .github: body = .github(try c.decode(GitHubEventBody.self, forKey: .body))
        }
    }
}

public struct HostEventBatch: Decodable, Equatable, Sendable {
    public let id: String
    public let createdAt: Date
    public let events: [HostEvent]
}

public struct HostdSourceStatus: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case ok
        case error
    }

    public let name: String
    public let kind: String
    public let state: State
    public let lastOkAt: Date?
    public let lastError: String
}

public struct HostdStatus: Decodable, Equatable, Sendable {
    public let version: String
    public let heartbeatAt: Date?
    public let sources: [HostdSourceStatus]
}

/// `doctor --json`. minis-hostd exits 2 with this same shape when a check fails, so the caller
/// reads `allOK` rather than treating exit 2 as an error.
public struct HostdDoctor: Decodable, Equatable, Sendable {
    public struct Check: Decodable, Equatable, Sendable {
        public let name: String
        public let ok: Bool
        public let detail: String
    }

    public let checks: [Check]

    public var allOK: Bool { checks.allSatisfy(\.ok) }
}

/// `apns register --json`: the pending key hostd drew for this phone (apns spec §4); `key` is base64.
public struct HostdAPNsRegistration: Decodable, Equatable, Sendable {
    public let keyID: String
    public let key: String

    public init(keyID: String, key: String) {
        self.keyID = keyID
        self.key = key
    }

    private enum CodingKeys: String, CodingKey {
        case keyID = "keyId"
        case key
    }
}

struct HostEventListReply: Decodable { let events: [HostEventSummary] }
struct HostEventReply: Decodable { let event: HostEvent }
struct HostEventBatchReply: Decodable { let batch: HostEventBatch }

extension HostEventClient {
    public func list(host: String, limit: Int, before: String?) async throws -> [HostEventSummary] {
        let paging = before.map { ["--before", $0] } ?? []
        let reply: HostEventListReply = try await call(
            host: host, arguments: ["events", "list", "--limit", String(limit)] + paging)
        return reply.events
    }

    public func event(host: String, id: String) async throws -> HostEvent {
        let reply: HostEventReply = try await call(host: host, arguments: ["events", "get", id])
        return reply.event
    }

    public func batch(host: String, id: String) async throws -> HostEventBatch {
        let reply: HostEventBatchReply = try await call(host: host, arguments: ["batches", "get", id])
        return reply.batch
    }

    public func status(host: String) async throws -> HostdStatus {
        try await call(host: host, arguments: ["status"])
    }

    public func doctor(host: String, pushTest: Bool) async throws -> HostdDoctor {
        try await call(host: host, arguments: ["doctor"] + (pushTest ? ["--push-test"] : []))
    }

    public func registerAPNs(host: String, deviceToken: String, topic: String, environment: String) async throws
        -> HostdAPNsRegistration {
        try await call(host: host, arguments: [
            "apns", "register", deviceToken, "--topic", topic, "--environment", environment,
        ])
    }

    /// Call only after the key from `registerAPNs` is saved: from then on hostd seals notices with it.
    public func activateAPNs(host: String, keyID: String) async throws -> HostEventAck {
        try await call(host: host, arguments: ["apns", "activate", keyID])
    }
}
