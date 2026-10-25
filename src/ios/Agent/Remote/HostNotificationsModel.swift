import Foundation
import MinisRemote

/// The minis-hostd release the install command pins. Bump it together with a `hostd-v<version>` release.
enum HostdRelease {
    static let version = "0.3.1"
    /// Read from `main` so a fix to the script reaches users without an app update; the binary it installs
    /// is still pinned by `version` and checked against the release's SHA256SUMS.
    static let installScriptURL =
        "https://raw.githubusercontent.com/NoSugarCoffee/Pico/main/host/minis-hostd/scripts/install.sh"
}

enum HostdRunState: Equatable {
    case running
    /// `since` is the last heartbeat; nil when the daemon has never stamped one.
    case notRunning(since: Date?)
}

enum HostNotificationsStatus: Equatable {
    case reported(HostdRunState, sources: [HostdSourceStatus])
    case notInstalled(host: String)
    case failed(message: String)
}

/// The Settings → Remote Hosts → host → Notifications logic (B spec §9.3), kept out of the view so it can be
/// tested without a host.
@MainActor
enum HostNotificationsModel {
    /// The daemon stamps a heartbeat every 60 s; three missed stamps means it is not running.
    static let heartbeatFreshness: TimeInterval = 3 * 60
    static let recentEventLimit = 50

    static func installCommand(hostName: String) -> String {
        "curl -fsSL \(HostdRelease.installScriptURL) | sh -s -- --host-name \(RemoteRunScripts.shellQuote(hostName)) --version \(HostdRelease.version)"
    }

    static func runState(_ status: HostdStatus, now: Date) -> HostdRunState {
        guard let heartbeat = status.heartbeatAt else { return .notRunning(since: nil) }
        // A heartbeat slightly in the future (host clock ahead of the phone) still counts as fresh.
        return now.timeIntervalSince(heartbeat) <= heartbeatFreshness ? .running : .notRunning(since: heartbeat)
    }

    static func status(_ result: Result<HostdStatus, Error>, host: String, now: Date) -> HostNotificationsStatus {
        switch result {
        case .success(let status):
            return .reported(runState(status, now: now), sources: status.sources)
        case .failure(HostEventError.notInstalled(let name)):
            return .notInstalled(host: name)
        case .failure(let error):
            return .failed(message: message(for: error))
        }
    }

    static func message(for error: Error) -> String {
        if let hostEventError = error as? HostEventError {
            return hostEventError.userMessage
        }
        return RemoteHostSetup.message(for: error)
    }

    static func notInstalledMessage(host: String) -> String {
        RemoteHostL10n.string("minis-hostd is not installed on \(host).")
    }

    /// `decision` is the gate's action (`push`, `store_only`, `drop` in host/minis-hostd/internal/gate).
    static func decisionLabel(_ decision: String) -> String {
        switch decision {
        case "push": return RemoteHostL10n.string("Matched the rules")
        case "store_only": return RemoteHostL10n.string("Stored without a push")
        case "drop": return RemoteHostL10n.string("Dropped")
        default: return decision
        }
    }

    /// Spelled exactly as the gate's `Reason*` constants, which are a stored contract.
    static func reasonLabel(_ reason: String) -> String {
        switch reason {
        case "allowed": return RemoteHostL10n.string("Matched your rules")
        case "malformed_sender": return RemoteHostL10n.string("No single sender address")
        case "too_old": return RemoteHostL10n.string("Older than 48 hours")
        case "automated": return RemoteHostL10n.string("Automated or bulk mail")
        case "sender_not_allowed": return RemoteHostL10n.string("Sender not on the allowlist")
        case "sender_unauthenticated": return RemoteHostL10n.string("Sender failed DMARC")
        case "reason_not_kept": return RemoteHostL10n.string("GitHub reason not kept")
        case "repo_not_kept": return RemoteHostL10n.string("Repository not kept")
        default: return RemoteHostL10n.string("Other reason (\(reason))")
        }
    }

    static func decisionText(_ event: HostEventSummary) -> String {
        "\(decisionLabel(event.decision)) · \(reasonLabel(event.reason))"
    }
}
