import Foundation
import MinisRemote
import UIKit

private let logger = AppLogger(category: "RemoteHost")

enum RemoteKeySource {
    case generate
    case importOpenSSH(pem: String, passphrase: String?)
}

/// A host key waiting for the user's decision; `openSSHKey` is exactly the key whose fingerprint is shown.
struct RemoteHostKeyPrompt: Identifiable, Equatable {
    let host: String
    /// The endpoint that presented the key; trusting it for a host since moved elsewhere would pin the wrong key.
    let address: String
    let port: Int
    let fingerprint: String
    let openSSHKey: String
    /// True when the host presented a key different from the pinned one.
    let replacesPinnedKey: Bool

    var id: String { "\(host) \(fingerprint)" }
}

/// A setup step the app itself rejects (no key text, unreadable file); `message` is shown as is.
struct RemoteHostSetupFailure: Error, Equatable {
    let message: String
}

enum RemoteHostCheckOutcome: Equatable {
    case checked([RemoteHostChecks.Result])
    case untrusted(RemoteHostKeyPrompt)
    case failed(String)
}

/// The Settings → Remote Hosts actions, kept out of the views so each one reads as a single call.
@MainActor
enum RemoteHostSetup {
    static func publicKeyComment() -> String {
        "minis@\(UIDevice.current.name)"
    }

    static func publicKeyLine(host: RemoteHostConfig, services: RemoteServices) throws -> String {
        let key = try RemoteKeyStore.privateKey(store: services.secrets, account: host.keyRef)
        return RemoteKeyStore.publicKeyLine(of: key, comment: publicKeyComment())
    }

    static func authorizedKeysCommand(publicKeyLine: String) -> String {
        "echo \(RemoteRunScripts.shellQuote(publicKeyLine)) >> ~/.ssh/authorized_keys"
    }

    /// The key is stored first so the host never exists without one; a rejected host leaves no secret behind.
    static func addHost(
        name: String, address: String, port: Int, user: String, key: RemoteKeySource, services: RemoteServices
    ) throws {
        let keyRef = "host-\(UUID().uuidString.lowercased())"
        try storeKey(key, account: keyRef, secrets: services.secrets)
        do {
            try services.store.add(RemoteHostConfig(
                name: name, address: address, port: port, user: user, keyRef: keyRef, pinnedHostKey: nil, os: nil))
        } catch {
            try services.secrets.delete(account: keyRef)
            throw error
        }
        logger.info("Added remote host \(name)")
    }

    /// Pairing spec §4: the key is generated first and deleted again unless the host accepted it, and the host
    /// is added only once its `authorized_keys` holds the key, pinned to the host key the code carried.
    static func pair(
        _ payload: PairingPayload, name: String, client: PairingClient, services: RemoteServices
    ) async throws {
        try services.store.checkNewName(name)
        let keyRef = "host-\(UUID().uuidString.lowercased())"
        try storeKey(.generate, account: keyRef, secrets: services.secrets)
        do {
            let key = try RemoteKeyStore.privateKey(store: services.secrets, account: keyRef)
            let address = try await client.pair(
                payload, publicKey: RemoteKeyStore.publicKeyLine(of: key, comment: publicKeyComment()))
            try services.store.add(RemoteHostConfig(
                name: name, address: address, port: payload.port, user: payload.user, keyRef: keyRef,
                pinnedHostKey: payload.hostKey, os: nil))
        } catch {
            try services.secrets.delete(account: keyRef)
            throw error
        }
        logger.info("Paired remote host \(name)")
    }

    static func pairCommand() -> String {
        "curl -fsSL \(HostdRelease.installScriptURL) | sh -s -- --pair --version \(HostdRelease.version)"
    }

    static func updateHost(
        name: String, address: String, port: Int, user: String, services: RemoteServices
    ) async throws {
        try services.store.update(name: name, address: address, port: port, user: user)
        await services.pool.invalidate(host: name)
        await services.executor.forgetHome(host: name)
    }

    /// Overwrites the host's key in place; the cached connection still uses the old one, so it is dropped.
    static func replaceKey(host: RemoteHostConfig, with key: RemoteKeySource, services: RemoteServices) async throws {
        try storeKey(key, account: host.keyRef, secrets: services.secrets)
        await services.pool.invalidate(host: host.name)
        logger.info("Replaced the key of remote host \(host.name)")
    }

    static func removeHost(name: String, services: RemoteServices) async throws {
        try services.store.remove(name: name)
        PushRegistration.forget(host: name)
        await services.pool.invalidate(host: name)
        await services.executor.forgetHome(host: name)
        logger.info("Removed remote host \(name)")
    }

    static func trust(_ prompt: RemoteHostKeyPrompt, services: RemoteServices) async throws {
        guard let current = services.store.hosts.first(where: { $0.name == prompt.host }) else {
            throw RemoteHostStoreError.unknownHost(prompt.host)
        }
        guard current.address == prompt.address, current.port == prompt.port else {
            throw RemoteHostSetupFailure(message: RemoteHostL10n.string("This host key came from \(prompt.address):\(String(prompt.port)), but “\(prompt.host)” now points to \(current.address):\(String(current.port)). Test the connection again to see the current host's key."))
        }
        try services.store.pinHostKey(name: prompt.host, openSSHPublicKey: prompt.openSSHKey)
        await services.pool.invalidate(host: prompt.host)
        logger.info("Trusted host key \(prompt.fingerprint) for \(prompt.host)")
    }

    /// Persists the reported OS, which the system prompt reads (it never execs on the host itself).
    static func runChecks(host: String, services: RemoteServices) async -> RemoteHostCheckOutcome {
        guard let config = services.store.hosts.first(where: { $0.name == host }) else {
            return .failed(message(for: RemoteHostError.notConfigured(host: host)))
        }
        let output: String
        do {
            output = try await services.executor.hostCheckOutput(host: host)
        } catch RemoteHostError.hostKeyUnpinned(let name, let fingerprint, let key) {
            return .untrusted(RemoteHostKeyPrompt(
                host: name, address: config.address, port: config.port, fingerprint: fingerprint,
                openSSHKey: key, replacesPinnedKey: false))
        } catch RemoteHostError.hostKeyMismatch(let name, let fingerprint, let key) {
            return .untrusted(RemoteHostKeyPrompt(
                host: name, address: config.address, port: config.port, fingerprint: fingerprint,
                openSSHKey: key, replacesPinnedKey: true))
        } catch {
            logger.error("Checks on \(host) failed: \(error)")
            return .failed(message(for: error))
        }
        if let os = RemoteHostChecks.operatingSystem(in: output) {
            do {
                try services.store.setOS(name: host, os: os)
            } catch {
                return .failed(message(for: error))
            }
        }
        return .checked(RemoteHostChecks.parse(output))
    }

    /// Settings wording, in the user's language. The package's `userMessage` texts are written for the model
    /// (English, pointing at tools), so every error Settings can meet is worded here instead.
    static func message(for error: Error) -> String {
        switch error {
        case let failure as RemoteHostSetupFailure:
            return failure.message
        case let hostError as RemoteHostError:
            return message(for: hostError)
        case let pairingError as PairingError:
            return message(for: pairingError)
        case RemoteRunError.outputFrameMissing(let host, let exitStatus, let detail):
            return RemoteHostL10n.string("“\(host)” did not run the Minis control script (exit status \(exitStatus), \(detail)). Check that /bin/sh and base64 -d (or base64 -D) work on the host and that its login files do not exit.")
        case RemoteRunError.homeDirectoryUnknown(let host, let detail):
            return RemoteHostL10n.string("Could not read $HOME on “\(host)” (\(detail)). Go to an absolute path instead.")
        case RemoteFileError.notFound(let path):
            return RemoteHostL10n.string("\(path) does not exist on the host.")
        case RemoteFileError.failed(let path, let detail):
            return RemoteHostL10n.string("The host could not open \(path): \(detail)")
        case RemoteExecError.timedOut(let host, let after):
            return RemoteHostL10n.string("\(host) did not answer within \(after.formatted()). Check that the host is awake and reachable, then try again.")
        case RemoteKeyStoreError.unsupportedKeyEncryption:
            return RemoteHostL10n.string("This key's passphrase encryption uses more bcrypt rounds than Minis can read (current ssh-keygen uses 24, the limit is 17). Re-encrypt a copy with fewer rounds, ssh-keygen -p -a 16 -f <copy of the key>, then import it again.")
        case RemoteKeyStoreError.invalidPrivateKey(let detail):
            return RemoteHostL10n.string("Could not read an OpenSSH Ed25519 private key (wrong passphrase, unsupported type or malformed text): \(detail)")
        case RemoteKeyStoreError.keyNotFound, RemoteKeyStoreError.corruptStoredKey:
            return RemoteHostL10n.string("This host's private key is missing from the Keychain. Replace the key, then add the new public key to the host.")
        case RemoteSecretStoreError.keychain(let operation, let status):
            return keychainMessage(operation: operation, status: Int(status)) ?? String(describing: error)
        case RemoteHostStoreError.invalidName(let name):
            return RemoteHostL10n.string("“\(name)” is not a valid host name. Use 1–32 letters, digits, “-” or “_”.")
        case RemoteHostStoreError.duplicateName(let name):
            return RemoteHostL10n.string("A host named “\(name)” already exists. Pick another name.")
        case RemoteHostStoreError.unknownHost(let name):
            return RemoteHostL10n.string("The host “\(name)” no longer exists. Go back and pick another host.")
        case RemoteHostStoreError.invalidPort(let port):
            return RemoteHostL10n.string("Port \(String(port)) is not valid. Use a number from 1 to 65535.")
        case RemoteHostStoreError.missingField("address"):
            return RemoteHostL10n.string("Enter the host's address.")
        case RemoteHostStoreError.missingField("user"):
            return RemoteHostL10n.string("Enter the host's user name.")
        // Only tool calls meet the remaining run and file errors; Settings runs no commands or file tools.
        case let runError as RemoteRunError:
            return runError.userMessage
        case let fileError as RemoteFileError:
            return fileError.userMessage
        default:
            return String(describing: error)
        }
    }

    private static func message(for hostError: RemoteHostError) -> String {
        switch hostError {
        case .unreachable(let host):
            return RemoteHostL10n.string("“\(host)” is unreachable. Is Tailscale on?")
        case .authFailed(let host):
            return RemoteHostL10n.string("“\(host)” rejected this device's SSH key. Add the key shown under Public Key in Settings → Remote Hosts → \(host) to ~/.ssh/authorized_keys on the host.")
        case .hostKeyMismatch(let host, let presented, _):
            return RemoteHostL10n.string("“\(host)” presented a different host key (\(presented)), so the connection was refused. If the host was reinstalled, check the new fingerprint and trust it in Settings → Remote Hosts → \(host).")
        case .hostKeyUnpinned(let host, let presented, _):
            return RemoteHostL10n.string("“\(host)” is not trusted yet (host key \(presented)). Check the fingerprint and trust it in Settings → Remote Hosts → \(host).")
        case .notConfigured(let host):
            return RemoteHostL10n.string("“\(host)” is not configured. Add it in Settings → Remote Hosts.")
        }
    }

    private static func message(for pairingError: PairingError) -> String {
        switch pairingError {
        case .notAPairingCode, .malformedCode:
            return RemoteHostL10n.string("This is not a Minis pairing code. Run minis-hostd pair on the computer and scan the code it prints.")
        case .unsupportedVersion:
            return RemoteHostL10n.string("Update Minis to pair with this host.")
        case .unreachable(let name, let addresses):
            return RemoteHostL10n.string("Could not reach \(name) at \(addresses.joined(separator: ", ")). Check that the phone and the computer are on the same Tailscale network or Wi-Fi, and that minis-hostd pair is still running.")
        case .refused(.hostError):
            return RemoteHostL10n.string("The computer could not save this iPhone's key. Its Terminal shows why; fix that and run minis-hostd pair again.")
        case .refused, .malformedReply:
            return RemoteHostL10n.string("The computer refused the pairing. Run minis-hostd pair again and scan the new code.")
        }
    }

    /// One whole sentence per Keychain operation (`KeychainSecretStore`), so no verb is spliced into a sentence.
    /// The status goes in as a String: an Int would be localized with grouping ("-25,308"), but it is a code.
    private static func keychainMessage(operation: String, status: Int) -> String? {
        switch operation {
        case "add", "update":
            return RemoteHostL10n.string("The Keychain refused to save the key (OSStatus \(String(status))). Unlock the device and try again.")
        case "get":
            return RemoteHostL10n.string("The Keychain refused to read the key (OSStatus \(String(status))). Unlock the device and try again.")
        case "delete":
            return RemoteHostL10n.string("The Keychain refused to delete the key (OSStatus \(String(status))). Unlock the device and try again.")
        default:
            return nil
        }
    }

    static func checkLabel(_ check: RemoteHostChecks.Check) -> String {
        switch check {
        case .operatingSystem: return RemoteHostL10n.string("Operating system")
        case .loginShell: return RemoteHostL10n.string("Login shell")
        case .git: return "git"
        case .minisDirectory: return RemoteHostL10n.string("~/.minis writable")
        }
    }

    static func checkDetail(_ finding: RemoteHostChecks.Finding) -> String {
        switch finding {
        case .missing:
            return RemoteHostL10n.string("Missing from the check output; the check script did not finish on the host.")
        case .operatingSystem(let os):
            return os
        case .operatingSystemEmpty:
            return RemoteHostL10n.string("uname -s printed nothing.")
        case .loginShell(let shell):
            return shell
        case .loginShellUnset:
            return RemoteHostL10n.string("$SHELL is not set; commands run with /bin/sh -l.")
        case .loginShellNotPosix(let shell, let execShell):
            return RemoteHostL10n.string("\(shell) is not a POSIX shell; commands run with \(execShell) -l instead.")
        case .gitFound(let path):
            return path
        case .gitNotOnPath(let execShell):
            return RemoteHostL10n.string("git was not found on the PATH of the login shell (\(execShell) -l). Install git, or add its directory to PATH in that shell's login profile.")
        case .gitShellFailed(let execShell):
            return RemoteHostL10n.string("The login shell failed before printing, so git's PATH could not be checked. Run \(execShell) -lc 'command -v git' on the host to see the error.")
        case .minisWritable:
            return RemoteHostL10n.string("Run output is kept in ~/.minis/runs.")
        case .minisUnwritable:
            return RemoteHostL10n.string("~/.minis could not be created or written. Minis keeps run output in ~/.minis/runs; fix the ownership or permissions of ~/.minis, or free disk space.")
        }
    }

    /// The public line the key store returns is not kept: the detail screen derives it from the stored key.
    private static func storeKey(_ key: RemoteKeySource, account: String, secrets: RemoteSecretStore) throws {
        switch key {
        case .generate:
            _ = try RemoteKeyStore.generateEd25519(store: secrets, account: account, comment: publicKeyComment())
        case .importOpenSSH(let pem, let passphrase):
            _ = try RemoteKeyStore.importOpenSSHPrivateKey(
                store: secrets, pem, passphrase: passphrase, account: account, comment: publicKeyComment())
        }
    }
}
