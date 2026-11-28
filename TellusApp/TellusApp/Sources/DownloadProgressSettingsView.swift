import SwiftUI

struct DownloadProgressSettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var preferences = PreferenceStore(domain: .insula)
    @State private var sliderDrafts: [String: Double] = [:]

    var body: some View {
        Form {
            AppleModeBanner()
            RecoveryStatusBanner()

            Section(content: {
                Toggle("Show Download Progress", isOn: boolBinding("DownloadProgressEnabled", default: false))
            }, footer: {
                Text("Shows tracked downloads in the Dynamic Island. This feature is experimental.")
            })

            Section(content: {
                Toggle("App Store Downloads", isOn: boolBinding("DownloadAppStoreEnabled", default: false))
                Toggle("Browser Downloads", isOn: boolBinding("DownloadBrowserEnabled", default: false))
            }, header: {
                Text("Sources")
            }, footer: {
                Text("Browser support covers Safari, Chrome, and Arc Search. Downloads from private browsing are shown like any other.")
            })

            Section(content: {
                Toggle("Completion Haptic", isOn: boolBinding("DownloadCompletionHaptic", default: false))
            }, header: {
                Text("Completion")
            }, footer: {
                Text("One short haptic when a tracked download or installation finishes, two quick ones when it fails or is cancelled. Haptic only, no sound; the system's own haptics setting applies. Needs Insula 0.4.2 or later.")
            })

            Section(content: {
                Picker("Style", selection: integerBinding("DownloadProgressStyle", default: 0)) {
                    Text("Minimal").tag(0)
                    Text("Detailed").tag(1)
                }
                .pickerStyle(.segmented)
            }, header: {
                Text("Look")
            }, footer: {
                Text("Minimal is a compact pill over the Island. Detailed uses an expanded Island presentation.")
            })

            Section(content: {
                slider("Width", key: "DownloadPillWidth", default: 296, range: 200...380, format: "%.0f pt")
                slider("Bottom Padding", key: "DownloadPillBottomPadding", default: 10, range: 0...40, format: "%.0f pt")
                slider("Vertical Offset", key: "DownloadPillNudgeY", default: 0, range: -30...30, format: "%.0f pt")
            }, header: {
                Text("Minimal Size")
            }, footer: {
                Text("These controls adjust the Minimal pill. Start a test download to preview the changes.")
            })

            Section(content: {
                slider("Downloaded", key: "DownloadIdleAfterMB", default: 0, range: 0...5000, format: "%.0f MB", zeroText: "Never")
                slider("Progress", key: "DownloadIdleAfterPercent", default: 0, range: 0...99, format: "%.0f%%", zeroText: "Never")
                slider("Time on Screen", key: "DownloadIdleAfterSeconds", default: 0, range: 0...900, format: "%.0f sec", zeroText: "Never")
            }, header: {
                Text("Return to Idle")
            }, footer: {
                Text("The progress display hides when a limit is reached; the download continues. The size limit applies only to byte-based downloads.")
            })

            Section(content: {
                slider("Test Size", key: "DownloadTestSizeMB", default: 800, range: 50...5000, format: "%.0f MB")
                Button("Start Test Download") {
                    preferences.post("com.wilburt.oiti/TestDownloadStart")
                }
                Button("Stop Test Download", role: .destructive) {
                    preferences.post("com.wilburt.oiti/TestDownloadStop")
                }
            }, header: {
                Text("Test Download")
            }, footer: {
                Text("A simulated download for previewing the progress display and its limits. Show Download Progress must be on.")
            })

            Section(content: {
                Label(
                    preferences.synchronizationSucceeded ? "Preferences available" : "Could not synchronize preferences",
                    systemImage: preferences.synchronizationSucceeded ? "checkmark.circle" : "exclamationmark.circle"
                )
            }, header: {
                Text("Preference Connection")
            })
        }
        .navigationTitle("Download Progress")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { preferences.reload() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { preferences.reload() }
        }
    }

    private func boolBinding(_ key: String, default defaultValue: Bool) -> Binding<Bool> {
        Binding(
            get: { preferences.bool(forKey: key, default: defaultValue) },
            set: { _ = preferences.write([key: NSNumber(value: $0)]) }
        )
    }

    private func integerBinding(_ key: String, default defaultValue: Int) -> Binding<Int> {
        Binding(
            get: { preferences.integer(forKey: key, default: defaultValue) },
            set: { _ = preferences.write([key: NSNumber(value: $0)]) }
        )
    }

    private func slider(
        _ title: String,
        key: String,
        default defaultValue: Double,
        range: ClosedRange<Double>,
        format: String,
        zeroText: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                let value = sliderDrafts[key] ?? preferences.double(forKey: key, default: defaultValue)
                Text(zeroText != nil && value < 0.5 ? zeroText! : String(format: format, value))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(
                value: Binding(
                    get: { sliderDrafts[key] ?? preferences.double(forKey: key, default: defaultValue) },
                    set: {
                        sliderDrafts[key] = $0
                        preferences.updateSlider($0, forKey: key)
                    }
                ),
                in: range,
                onEditingChanged: { editing in
                    guard !editing, let value = sliderDrafts.removeValue(forKey: key) else { return }
                    preferences.updateSlider(value, forKey: key, finished: true)
                }
            )
        }
        .padding(.vertical, 4)
    }
}
