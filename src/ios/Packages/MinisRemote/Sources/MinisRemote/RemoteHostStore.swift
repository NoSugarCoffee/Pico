import Foundation

public enum RemoteHostStoreError: Error, Equatable {
    case invalidName(String)
    case duplicateName(String)
    case unknownHost(String)
    case invalidPort(Int)
    case missingField(String)
}

@MainActor
public final class RemoteHostStore: ObservableObject {
    private struct Snapshot: Codable {
        var hosts: [RemoteHostConfig]
        var bindings: [String: SessionHostBindingValue]
        /// Host name → working directories, most recent first.
        var recentWorkdirs: [String: [String]]

        init(
            hosts: [RemoteHostConfig], bindings: [String: SessionHostBindingValue],
            recentWorkdirs: [String: [String]]
        ) {
            self.hosts = hosts
            self.bindings = bindings
            self.recentWorkdirs = recentWorkdirs
        }

        /// Files written before `recentWorkdirs` existed have no such key; they simply have no history.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            hosts = try container.decode([RemoteHostConfig].self, forKey: .hosts)
            bindings = try container.decode([String: SessionHostBindingValue].self, forKey: .bindings)
            recentWorkdirs = try container.decodeIfPresent([String: [String]].self, forKey: .recentWorkdirs) ?? [:]
        }
    }

    public static let maxNameLength = 32
    public static let maxRecentWorkdirs = 8

    @Published public private(set) var hosts: [RemoteHostConfig]
    private var bindings: [String: SessionHostBindingValue]
    private var recentWorkdirs: [String: [String]]
    private let fileURL: URL
    private let secrets: RemoteSecretStore
    private let onHostAdded: @MainActor (String) -> Void

    /// Throws when the file exists but cannot be decoded, so a corrupt file is never silently reset.
    public init(fileURL: URL, secrets: RemoteSecretStore, onHostAdded: @escaping @MainActor (String) -> Void) throws {
        self.fileURL = fileURL
        self.secrets = secrets
        self.onHostAdded = onHostAdded
        let snapshot = try Self.load(fileURL: fileURL)
        self.hosts = snapshot.hosts
        self.bindings = snapshot.bindings
        self.recentWorkdirs = snapshot.recentWorkdirs
    }

    /// Moves a file that `init` could not decode next to itself and returns the backup's URL, so the next
    /// `init` starts empty without destroying what the user had.
    public static func moveUnreadableFileAside(at fileURL: URL, date: Date) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backup = fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(fileURL.lastPathComponent).unreadable-\(formatter.string(from: date))")
        try FileManager.default.moveItem(at: fileURL, to: backup)
        return backup
    }

    public func add(_ host: RemoteHostConfig) throws {
        try checkNewName(host.name)
        try Self.validateConnection(address: host.address, port: host.port, user: host.user)
        try commit(hosts: hosts + [host], bindings: bindings, recentWorkdirs: recentWorkdirs)
        onHostAdded("remote-host:\(host.name)")
    }

    /// Pairing calls this before it touches the host, so a name `add` would refuse never leaves a key behind there.
    public func checkNewName(_ name: String) throws {
        guard Self.isValidName(name) else { throw RemoteHostStoreError.invalidName(name) }
        guard !hosts.contains(where: { $0.name == name }) else { throw RemoteHostStoreError.duplicateName(name) }
    }

    /// A new address or port may be a different machine, so its pinned key and OS no longer apply.
    public func update(name: String, address: String, port: Int, user: String) throws {
        let host = try existingHost(name)
        try Self.validateConnection(address: address, port: port, user: user)
        let sameEndpoint = host.address == address && host.port == port
        let updated = RemoteHostConfig(
            name: name, address: address, port: port, user: user, keyRef: host.keyRef,
            pinnedHostKey: sameEndpoint ? host.pinnedHostKey : nil, os: sameEndpoint ? host.os : nil)
        try replace(updated)
    }

    public func setOS(name: String, os: String) throws {
        let host = try existingHost(name)
        try replace(RemoteHostConfig(
            name: host.name, address: host.address, port: host.port, user: host.user,
            keyRef: host.keyRef, pinnedHostKey: host.pinnedHostKey, os: os))
    }

    public func recentWorkdirs(host: String) -> [String] {
        recentWorkdirs[host] ?? []
    }

    public func remove(name: String) throws {
        guard let removed = hosts.first(where: { $0.name == name }) else { return }
        let remaining = hosts.filter { $0.name != name }
        var remainingRecents = recentWorkdirs
        remainingRecents[name] = nil
        try commit(
            hosts: remaining, bindings: bindings.filter { $0.value.hostName != name }, recentWorkdirs: remainingRecents)
        if !remaining.contains(where: { $0.keyRef == removed.keyRef }) {
            try secrets.delete(account: removed.keyRef)
        }
    }

    public func pinHostKey(name: String, openSSHPublicKey: String) throws {
        let host = try existingHost(name)
        try replace(RemoteHostConfig(
            name: host.name, address: host.address, port: host.port, user: host.user,
            keyRef: host.keyRef, pinnedHostKey: openSSHPublicKey, os: host.os))
    }

    public func binding(sessionId: String) -> SessionHostBindingValue? {
        bindings[sessionId]
    }

    public func setBinding(_ value: SessionHostBindingValue?, sessionId: String) throws {
        var updated = bindings
        updated[sessionId] = value
        var updatedRecents = recentWorkdirs
        if let value {
            let previous = updatedRecents[value.hostName] ?? []
            updatedRecents[value.hostName] = Array(
                ([value.workdir] + previous.filter { $0 != value.workdir }).prefix(Self.maxRecentWorkdirs))
        }
        try commit(hosts: hosts, bindings: updated, recentWorkdirs: updatedRecents)
    }

    private func existingHost(_ name: String) throws -> RemoteHostConfig {
        guard let host = hosts.first(where: { $0.name == name }) else {
            throw RemoteHostStoreError.unknownHost(name)
        }
        return host
    }

    private func replace(_ host: RemoteHostConfig) throws {
        try commit(
            hosts: hosts.map { $0.name == host.name ? host : $0 }, bindings: bindings, recentWorkdirs: recentWorkdirs)
    }

    public static func validateConnection(address: String, port: Int, user: String) throws {
        guard !address.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw RemoteHostStoreError.missingField("address")
        }
        guard (1...65535).contains(port) else { throw RemoteHostStoreError.invalidPort(port) }
        guard !user.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw RemoteHostStoreError.missingField("user")
        }
    }

    private static func isValidName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        return (1...maxNameLength).contains(bytes.count) && bytes.allSatisfy { byte in
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-")
        }
    }

    private static func load(fileURL: URL) throws -> Snapshot {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return Snapshot(hosts: [], bindings: [:], recentWorkdirs: [:])
        }
        return try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: fileURL))
    }

    /// Persists first so in-memory state never gets ahead of the file when the write fails.
    private func commit(
        hosts newHosts: [RemoteHostConfig], bindings newBindings: [String: SessionHostBindingValue],
        recentWorkdirs newRecents: [String: [String]]
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Snapshot(hosts: newHosts, bindings: newBindings, recentWorkdirs: newRecents))
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        hosts = newHosts
        bindings = newBindings
        recentWorkdirs = newRecents
    }
}
