import MinisRemote
import SwiftUI

/// Settings → Remote Hosts → host → Notifications (B spec §9.3): how to install minis-hostd, whether it runs,
/// and what it recently decided.
struct HostNotificationsView: View {
    let services: RemoteServices
    let hostName: String

    private enum EventsState {
        case loaded([HostEventSummary])
        case failed(String)
    }

    @State private var status: HostNotificationsStatus?
    @State private var events: EventsState?
    @State private var isLoading = false
    @State private var copiedNotice: String?
    @State private var pushRecord: PushRegistrationRecord?
    @State private var pushState: PushRegistrationState = .idle

    private enum PushRegistrationState: Equatable {
        case idle
        case registering
        case registered
        case failed(String)
    }

    var body: some View {
        List {
            installSection
            picoNotificationsSection
            statusSection
            eventsSection
        }
        .navigationTitle(RemoteHostL10n.string("Notifications"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            pushRecord = PushRegistration.record(host: hostName)
            await load()
        }
        .refreshable { await load() }
    }

    private var installSection: some View {
        let command = HostNotificationsModel.installCommand(hostName: hostName)
        return Section {
            Text(command)
                .font(.caption.monospaced())
                .textSelection(.enabled)
            Button(RemoteHostL10n.string("Copy Install Command")) {
                UIPasteboard.general.string = command
                copiedNotice = RemoteHostL10n.string("Install command copied")
            }
        } header: {
            Text(RemoteHostL10n.string("Install minis-hostd"))
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(RemoteHostL10n.string("Run the command on \(hostName). It installs minis-hostd \(HostdRelease.version) to ~/.minis/bin after checking its SHA-256, and writes ~/.minis/hostd/config.toml. Then, on the host:"))
                Text(RemoteHostL10n.string("1. Edit ~/.minis/hostd/config.toml: turn on a Gmail account or GitHub, and paste the Bark device key. In the Bark app, set Push Encryption to AES256 / GCM / noPadding with the encryption_key from the file."))
                Text(RemoteHostL10n.string("2. Check everything and send a test push: ~/.minis/bin/minis-hostd doctor --push-test"))
                Text(RemoteHostL10n.string("3. Start it as a service: ~/.minis/bin/minis-hostd install-service"))
                if let copiedNotice {
                    Text(copiedNotice).foregroundStyle(.green)
                }
            }
        }
    }

    private var picoNotificationsSection: some View {
        Section {
            Button {
                Task { await registerThisPhone() }
            } label: {
                HStack {
                    Text(RemoteHostL10n.string("Send to This iPhone"))
                    if pushState == .registering {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(pushState == .registering)
            switch pushState {
            case .registered:
                Label(RemoteHostL10n.string("This iPhone is registered. Run minis-hostd doctor --push-test on \(hostName) to try it."), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed(let message):
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            case .idle, .registering:
                if let lastError = pushRecord?.lastError {
                    Text(lastError)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                } else if pushRecord != nil {
                    Text(RemoteHostL10n.string("Notices from \(hostName) come to this iPhone."))
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(RemoteHostL10n.string("Pico Notifications"))
        } footer: {
            Text(RemoteHostL10n.string("For a Pico built with your own paid Apple team. On \(hostName), turn on [apns] in ~/.minis/hostd/config.toml with your APNs key in place of [bark], then tap Send to This iPhone."))
        }
    }

    private func registerThisPhone() async {
        pushState = .registering
        do {
            try await PushRegistration.register(host: hostName, using: try .live(services: services))
            pushRecord = PushRegistration.record(host: hostName)
            pushState = .registered
        } catch {
            pushState = .failed(PushRegistration.message(for: error))
        }
    }

    private var statusSection: some View {
        Section {
            switch status {
            case .reported(let runState, let sources):
                runStateRow(runState)
                ForEach(sources, id: \.name) { source in
                    HostdSourceRow(source: source)
                }
            case .notInstalled(let host):
                Text(HostNotificationsModel.notInstalledMessage(host: host))
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            case nil:
                ProgressView()
            }
        } header: {
            Text(RemoteHostL10n.string("Status"))
        }
    }

    @ViewBuilder
    private func runStateRow(_ runState: HostdRunState) -> some View {
        switch runState {
        case .running:
            Label(RemoteHostL10n.string("Running"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .notRunning(let since):
            Label {
                if let since {
                    Text(RemoteHostL10n.string("Not running since \(since.formatted(date: .abbreviated, time: .shortened)). Start it on the host with ~/.minis/bin/minis-hostd install-service."))
                } else {
                    Text(RemoteHostL10n.string("Not running: minis-hostd has never started. Start it on the host with ~/.minis/bin/minis-hostd install-service."))
                }
            } icon: {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var eventsSection: some View {
        switch events {
        case .loaded(let summaries):
            Section {
                if summaries.isEmpty {
                    Text(RemoteHostL10n.string("No events yet."))
                        .foregroundStyle(.secondary)
                }
                ForEach(summaries, id: \.id) { event in
                    Button {
                        open(event)
                    } label: {
                        HostEventSummaryRow(event: event)
                    }
                    .foregroundStyle(.primary)
                }
            } header: {
                Text(RemoteHostL10n.string("Recent Events"))
            } footer: {
                Text(RemoteHostL10n.string("Tap an event to open it in a read-only chat."))
            }
        case .failed(let message):
            Section {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            } header: {
                Text(RemoteHostL10n.string("Recent Events"))
            }
        case nil:
            EmptyView()
        }
    }

    /// Like A1's Test Connection, this is the user's own action in Settings, so it runs without the
    /// per-host tool permission prompt; that prompt is presented by the chat view and cannot show over Settings.
    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let client = HostEventClient(runner: services.executor)
        let statusResult: Result<HostdStatus, Error>
        do {
            statusResult = .success(try await client.status(host: hostName))
        } catch {
            statusResult = .failure(error)
        }
        let loadedStatus = HostNotificationsModel.status(statusResult, host: hostName, now: Date())
        status = loadedStatus
        if case .notInstalled = loadedStatus {
            events = nil
            return
        }
        do {
            events = .loaded(try await client.list(
                host: hostName, limit: HostNotificationsModel.recentEventLimit, before: nil))
        } catch {
            events = .failed(HostNotificationsModel.message(for: error))
        }
    }

    private func open(_ event: HostEventSummary) {
        // The Settings sheet would cover the session and its permission prompt, so it is dismissed first; the
        // delay lets the dismissal finish, as DeepLinkRouter does before presenting.
        NotificationCenter.default.post(name: .dismissAllImmersivePresentations, object: nil)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            await HostEventOpener.open(.event(host: hostName, id: event.id), using: .live)
        }
    }
}

private struct HostdSourceRow: View {
    let source: HostdSourceStatus

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name)
                if !source.lastError.isEmpty {
                    Text(source.lastError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        } icon: {
            Image(systemName: source.state == .ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(source.state == .ok ? .green : .red)
        }
    }
}

private struct HostEventSummaryRow: View {
    let event: HostEventSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(event.title)
                    .lineLimit(2)
                Spacer()
                Text(event.createdAt.formatted(.relative(presentation: .named)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !event.summary.isEmpty {
                Text(event.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text(HostNotificationsModel.decisionText(event))
                .font(.caption2)
                .foregroundStyle(event.decision == "push" ? .green : .secondary)
        }
    }
}
