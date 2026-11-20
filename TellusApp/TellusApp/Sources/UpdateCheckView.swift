import SwiftUI

@MainActor
final class UpdateCheckViewModel: ObservableObject {
    enum State {
        case idle
        case loading
        case loaded(UpdateReport)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private let client = GitHubReleaseClient()

    var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }

    func check() async {
        guard !isLoading else { return }
        state = .loading

        do {
            let release = try await client.fetchLatestRelease()
            let installed = await InstalledVersionReader.collect()
            state = .loaded(UpdateReportBuilder.build(release: release, installed: installed))
        } catch is CancellationError {
            // The screen went away mid-check; leave the previous state alone.
            state = .idle
        } catch {
            state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
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
                        Text("Tellus only checks for updates. Install new versions with your package manager.")
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
                ComponentUpdateRow(item: item)
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
        }
        .padding(.vertical, 4)
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
