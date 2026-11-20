import CoreFoundation
import SwiftUI

@main
struct TellusApp: App {
    @State private var showRespringConfirmation = false
    @State private var showSafeModeConfirmation = false
    @State private var safeModeActive = false

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                List {
                    AppleModeBanner()
                    RecoveryStatusBanner()

                    Section("Insula") {
                        NavigationLink {
                            IslandSettingsView()
                        } label: {
                            Label("Island", systemImage: "capsule")
                        }
                        .listRowInsets(miscCardInsets)
                        NavigationLink {
                            AppearanceSettingsView()
                        } label: {
                            Label("Appearance", systemImage: "circle.lefthalf.filled")
                        }
                        .listRowInsets(miscCardInsets)
                        NavigationLink {
                            NotificationSettingsView()
                        } label: {
                            Label("Notifications", systemImage: "bell.badge")
                        }
                        .listRowInsets(miscCardInsets)
                        NavigationLink {
                            StartupSettingsView()
                        } label: {
                            Label("Startup Animation", systemImage: "sunrise.fill")
                        }
                        .listRowInsets(miscCardInsets)
                        NavigationLink {
                            DiagnosticsSettingsView()
                        } label: {
                            Label("Diagnostics", systemImage: "waveform.path.ecg")
                        }
                        .listRowInsets(miscCardInsets)
                        NavigationLink {
                            DownloadProgressSettingsView()
                        } label: {
                            Label("Download Progress", systemImage: "arrow.down.circle")
                        }
                        .listRowInsets(miscCardInsets)
                    }

                    Section {
                        VStack(spacing: 0) {
                            Button {
                                showRespringConfirmation = true
                            } label: {
                                MiscRowLabel(
                                    title: "Respring",
                                    subtitle: "Restart SpringBoard",
                                    symbol: "arrow.clockwise",
                                    tint: Color.orange
                                )
                            }
                            .buttonStyle(.plain)

                            miscDivider

                            Button {
                                showSafeModeConfirmation = true
                            } label: {
                                MiscRowLabel(
                                    title: "Exit Safe Mode",
                                    subtitle: "Exit Insula safe mode if active.",
                                    symbol: "exclamationmark",
                                    tint: Color.red
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(!safeModeActive)

                            miscDivider

                            NavigationLink {
                                AboutSettingsView()
                            } label: {
                                MiscRowLabel(
                                    title: "About",
                                    subtitle: "Tellus version and project information.",
                                    symbol: "info",
                                    tint: Color.gray,
                                    showsChevron: false
                                )
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 14)
                        .background(Color(uiColor: .secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                        .listRowBackground(Color.clear)
                    } header: {
                        Text("Miscellaneous")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(Color.white)
                            .textCase(nil)
                    }
                }
                .listStyle(.insetGrouped)
                .navigationTitle("Tellus")
                .task { await refreshRecoveryState() }
                .confirmationDialog("Respring?", isPresented: $showRespringConfirmation, titleVisibility: .visible) {
                    Button("Respring", role: .destructive) {
                        post("com.wilburt.oiti/Respring")
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("SpringBoard will restart.")
                }
                .confirmationDialog("Exit Safe Mode?", isPresented: $showSafeModeConfirmation, titleVisibility: .visible) {
                    Button("Exit Safe Mode & Respring", role: .destructive) {
                        post("com.wilburt.oiti/ClearSafeModeAndRespring")
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Insula Safe Mode will be cleared, then SpringBoard will restart.")
                }
            }
        }
    }

    private var miscDivider: some View {
        Rectangle()
            .fill(Color(uiColor: .separator).opacity(0.45))
            .frame(height: 1)
    }

    private var miscCardInsets: EdgeInsets {
        EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
    }

    private func post(_ notification: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(notification as CFString),
            nil,
            nil,
            true
        )
    }

    @MainActor
    private func refreshRecoveryState() async {
        do {
            let response = try await DiagnosticsBridge.perform("recoveryState")
            let object = try JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any]
            safeModeActive = object?["safeMode"] is [String: Any]
        } catch {
            safeModeActive = false
        }
    }
}

private struct MiscRowLabel: View {
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color
    var showsChevron = true

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(tint.opacity(0.16))
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(tint)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if showsChevron {
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(uiColor: .tertiaryLabel))
            }
        }
        .padding(.vertical, 20)
        .contentShape(Rectangle())
    }
}

private struct AboutSettingsView: View {
    @State private var insulaVersion = "Loading…"

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }

    var body: some View {
        Form {
            Section("Tellus") {
                LabeledContent("Version", value: appVersion)
                Text("Tellus brings Insula settings together in one app.")
                    .foregroundStyle(.secondary)
            }

            Section("Insula") {
                LabeledContent("Version", value: insulaVersion)
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                insulaVersion = try await DiagnosticsBridge.perform("insulaVersion")
                    .replacingOccurrences(of: "Insula (OITI) version ", with: "")
            } catch {
                insulaVersion = "Unavailable"
            }
        }
    }
}
