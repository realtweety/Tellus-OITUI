import SwiftUI

@MainActor
final class UpdateCheckViewModel: ObservableObject {
    enum State {
        case idle
        case loading
        case loaded(UpdateReport)
        case failed(String)
    }

    enum DownloadState {
        case downloading
        case verified(VerifiedPackage)
        case failed(String)
    }

    enum InstallState {
        case installing
        case installed(summary: String, log: String)
        case failed(summary: String, log: String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var downloads: [UpdateComponent: DownloadState] = [:]
    @Published private(set) var installs: [UpdateComponent: InstallState] = [:]

    private let client = GitHubReleaseClient()
    private let downloader = PackageDownloader()
    private let installer = PackageInstaller()
    private var latestRelease: GitHubRelease?

    var isInstalling: Bool {
        installs.values.contains { state in
            if case .installing = state { return true }
            return false
        }
    }

    var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }

    func check() async {
        guard !isLoading, !isInstalling else { return }
        state = .loading
        downloads = [:]
        installs = [:]

        do {
            let release = try await client.fetchLatestRelease()
            latestRelease = release
            let installed = await InstalledVersionReader.collect()
            state = .loaded(UpdateReportBuilder.build(release: release, installed: installed))
        } catch is CancellationError {
            // The screen went away mid-check; leave the previous state alone.
            state = .idle
        } catch {
            state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Downloads and verifies one package. It is only stored, never installed.
    func download(_ item: ComponentUpdate, checksumsURL: URL?) async {
        guard let package = item.package else { return }
        if case .downloading? = downloads[item.component] { return }
        downloads[item.component] = .downloading

        do {
            let verified = try await downloader.downloadAndVerify(package, checksumsURL: checksumsURL)
            downloads[item.component] = .verified(verified)
        } catch is CancellationError {
            downloads[item.component] = nil
        } catch {
            downloads[item.component] = .failed(
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }
    }

    /// Installs a package that was downloaded and verified. The root helper repeats the checks.
    func install(_ item: ComponentUpdate) async {
        guard case .verified(let verified)? = downloads[item.component], !isInstalling else { return }
        installs[item.component] = .installing

        let outcome = await installer.install(verified)
        if outcome.succeeded {
            installs[item.component] = .installed(summary: outcome.summary, log: outcome.log)
            await refreshInstalledVersions()
        } else {
            installs[item.component] = .failed(summary: outcome.summary, log: outcome.log)
        }
    }

    /// Re-reads the installed versions without asking GitHub again, so the rows update after an install.
    private func refreshInstalledVersions() async {
        guard let release = latestRelease else { return }
        let installed = await InstalledVersionReader.collect()
        state = .loaded(UpdateReportBuilder.build(release: release, installed: installed))
    }
}

struct UpdateCheckView: View {
    @StateObject private var model = UpdateCheckViewModel()

    var body: some View {
        Form {
            switch model.state {
            case .idle, .loading:
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Checking GitHub for updates…")
                            .foregroundStyle(.secondary)
                    }
                }

            case .failed(let message):
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Button("Try Again") {
                        Task { await model.check() }
                    }
                }

            case .loaded(let report):
                summarySection(report)
                componentsSection(report)
                if let notes = report.notes {
                    notesSection(notes)
                }
                if let url = report.releaseURL {
                    Section {
                        Link(destination: url) {
                            Label("View Release on GitHub", systemImage: "arrow.up.right.square")
                        }
                    } footer: {
                        Text("Downloads are checked against GitHub\u{2019}s SHA-256 checksums before anything is installed. Installing needs the Tellus root helper; after installing Insula, respring to load the new version.")
                    }
                }
            }
        }
        .navigationTitle("Check for Updates")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task { await model.check() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(model.isLoading)
                .accessibilityLabel("Check Again")
            }
        }
        .task { await model.check() }
    }

    // MARK: Sections

    private func summarySection(_ report: UpdateReport) -> some View {
        Section {
            let updates = report.updatesAvailable
            if updates.isEmpty {
                Label("Everything is up to date", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label(
                    "Update available for " + updates.map { $0.component.displayName }.joined(separator: ", "),
                    systemImage: "arrow.down.circle.fill"
                )
                .foregroundStyle(.blue)
            }
            LabeledContent("Latest Release", value: report.releaseTitle)
            if let date = report.publishedAt {
                LabeledContent("Published", value: date.formatted(date: .abbreviated, time: .omitted))
            }
        }
    }

    private func componentsSection(_ report: UpdateReport) -> some View {
        Section("Components") {
            ForEach(report.components) { item in
                ComponentUpdateRow(
                    item: item,
                    download: model.downloads[item.component],
                    install: model.installs[item.component],
                    installingElsewhere: model.isInstalling,
                    onDownload: { Task { await model.download(item, checksumsURL: report.checksumsURL) } },
                    onInstall: { Task { await model.install(item) } }
                )
            }
        }
    }

    private func notesSection(_ notes: String) -> some View {
        Section("Release Notes") {
            Text(Self.attributedNotes(notes))
                .font(.callout)
                .textSelection(.enabled)
        }
    }

    private static func attributedNotes(_ notes: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: notes, options: options)) ?? AttributedString(notes)
    }
}

private struct ComponentUpdateRow: View {
    let item: ComponentUpdate
    let download: UpdateCheckViewModel.DownloadState?
    let install: UpdateCheckViewModel.InstallState?
    let installingElsewhere: Bool
    let onDownload: () -> Void
    let onInstall: () -> Void

    @State private var confirmingInstall = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(item.component.displayName)
                    .font(.headline)
                Spacer()
                Label(statusText, systemImage: statusSymbol)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(statusColor)
            }
            LabeledContent("Installed", value: installedText)
            LabeledContent("Available", value: item.availableVersion ?? "Not in this release")
            if item.package?.downloadURL != nil {
                downloadControls
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var downloadControls: some View {
        switch download {
        case nil:
            Button(item.status == .updateAvailable ? "Download" : "Download Anyway", action: onDownload)
                .font(.footnote.weight(.semibold))
                .buttonStyle(.borderless)

        case .downloading?:
            HStack(spacing: 8) {
                ProgressView()
                Text("Downloading and verifying\u{2026}")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

        case .verified(let verified)?:
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Downloaded and verified", systemImage: "checkmark.seal.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.green)
                    Text("SHA-256 \(verified.sha256.prefix(16))\u{2026}")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                installControls
            }

        case .failed(let message)?:
            VStack(alignment: .leading, spacing: 4) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                Button("Try Again", action: onDownload)
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.borderless)
            }
        }
    }

    private var canInstall: Bool {
        PackageInstaller.installableComponents.contains(item.component)
    }

    private var installButtonTitle: String {
        switch item.status {
        case .updateAvailable: return "Install Update"
        case .installedIsNewer: return "Downgrade\u{2026}"
        default: return "Reinstall"
        }
    }

    private var confirmationMessage: String {
        var message = ""
        switch item.status {
        case .installedIsNewer:
            message = "The installed version is newer than this release, so this would downgrade it. "
        case .upToDate:
            message = "This is the version that is already installed, so it will be reinstalled. "
        default:
            break
        }
        if item.component == .insula {
            message += "Respring afterwards to load the new Insula."
        }
        return message
    }

    @ViewBuilder
    private var installControls: some View {
        if canInstall {
            switch install {
            case nil:
                Button(installButtonTitle) { confirmingInstall = true }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.borderless)
                    .disabled(installingElsewhere)
                    .confirmationDialog(
                        "Install \(item.component.displayName) \(item.availableVersion ?? "")?",
                        isPresented: $confirmingInstall,
                        titleVisibility: .visible
                    ) {
                        Button("Install", role: item.status == .installedIsNewer ? .destructive : nil, action: onInstall)
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text(confirmationMessage)
                    }

            case .installing?:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Installing\u{2026} keep Tellus open")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

            case .installed(let summary, let log)?:
                VStack(alignment: .leading, spacing: 4) {
                    Label(summary, systemImage: "checkmark.circle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.green)
                    if item.component == .insula {
                        Text("Respring to load the new version.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    installLog(log)
                }

            case .failed(let summary, let log)?:
                VStack(alignment: .leading, spacing: 4) {
                    Label(summary, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    installLog(log)
                    Button("Try Again") { confirmingInstall = true }
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.borderless)
                        .disabled(installingElsewhere)
                        .confirmationDialog(
                            "Install \(item.component.displayName) \(item.availableVersion ?? "")?",
                            isPresented: $confirmingInstall,
                            titleVisibility: .visible
                        ) {
                            Button("Install", role: item.status == .installedIsNewer ? .destructive : nil, action: onInstall)
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text(confirmationMessage)
                        }
                }
            }
        }
    }

    @ViewBuilder
    private func installLog(_ log: String) -> some View {
        if !log.isEmpty {
            DisclosureGroup("Details") {
                Text(log)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .font(.caption)
        }
    }

    private var installedText: String {
        switch item.installed {
        case .version(let text): return text
        case .notInstalled: return "Not installed"
        case .unknown: return "Unavailable"
        }
    }

    private var statusText: String {
        switch item.status {
        case .updateAvailable: return "Update"
        case .upToDate: return "Up to date"
        case .installedIsNewer: return "Newer than release"
        case .notInstalled: return "Not installed"
        case .notPublished: return "Not published"
        case .cannotCompare: return "Unknown"
        }
    }

    private var statusSymbol: String {
        switch item.status {
        case .updateAvailable: return "arrow.down.circle.fill"
        case .upToDate: return "checkmark.circle.fill"
        case .installedIsNewer: return "arrow.up.circle"
        case .notInstalled, .notPublished, .cannotCompare: return "info.circle"
        }
    }

    private var statusColor: Color {
        switch item.status {
        case .updateAvailable: return .blue
        case .upToDate: return .green
        case .installedIsNewer, .notInstalled, .notPublished, .cannotCompare: return .secondary
        }
    }
}
