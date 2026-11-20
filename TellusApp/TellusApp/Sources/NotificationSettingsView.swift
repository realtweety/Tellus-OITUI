import SwiftUI

struct NotificationSettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var preferences = PreferenceStore(domain: .insula)
    @State private var sliderDrafts: [String: Double] = [:]
    @State private var xPosition = "0"
    @State private var yPosition = "40"
    @State private var positionMessage: String?

    var body: some View {
        Form {
            AppleModeBanner()
            RecoveryStatusBanner()

            Section {
                Toggle("Show Notifications in the Island", isOn: boolBinding("islandNotificationsEnabled", default: false))
                Toggle("Hide the Stock Banner", isOn: boolBinding("islandNotificationsHideBanner", default: false))
            } footer: {
                Text("Island notifications require Enable Dynamic Island.")
            }

            Section {
                Toggle("Stack Multiple Notifications", isOn: boolBinding("islandNotificationStackEnabled", default: true))
                Picker("Style", selection: intBinding("IslandNotificationsStyle", default: 2)) {
                    Text("Compact").tag(0)
                    Text("Wide").tag(1)
                    Text("Expanded").tag(2)
                }
            } header: {
                Text("Notification Style")
            } footer: {
                Text("The stack can show up to four notifications, with older notifications displayed as cards below the Island. The selected style applies to the next notification.")
            }

            Section {
                Toggle("Dismiss When Tapped", isOn: boolBinding("NotificationTapDismisses", default: false))
                Toggle("Notification Haptic", isOn: boolBinding("NotificationHaptic", default: false))
            } header: {
                Text("Interaction")
            } footer: {
                Text("Dismiss a notification from the Island when you tap it, and optionally play a light haptic when a notification arrives.")
            }

            Section {
                slider("Duration", key: "IslandNotificationsDuration", default: 4, range: 2...10, format: "%.1f sec")
                slider("Message Lines", key: "IslandNotificationsMessageLines", default: 2, range: 1...4, format: "%.0f")
                slider("Extra Roundness", key: "IslandNotificationsCornerExtra", default: 0, range: -4...8, format: "%+.0f pt")
            } header: {
                Text("Display")
            } footer: {
                Text("Set how long each notification stays in the Island, how many message lines appear, and extra corner radius. 0 pt is the stock roundness.")
            }

            Section {
                Toggle("Use Custom Notification Position", isOn: boolBinding("notEnabled", default: false))
                positionField("X Position", text: $xPosition)
                positionField("Y Position", text: $yPosition)
                Button("Save Position") { savePosition() }
            } header: {
                Text("Position")
            } footer: {
                Text("Positions are measured in points. The tweak limits the applied position to the screen bounds.")
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Position", isPresented: Binding(get: { positionMessage != nil }, set: { if !$0 { positionMessage = nil } })) {
            Button("OK", role: .cancel) { positionMessage = nil }
        } message: {
            Text(positionMessage ?? "")
        }
        .onAppear {
            preferences.reload()
            loadPositionDrafts()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                preferences.reload()
                loadPositionDrafts()
            }
        }
    }

    private func positionField(_ title: String, text: Binding<String>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("", text: text)
                .multilineTextAlignment(.trailing)
                .keyboardType(.numbersAndPunctuation)
                .frame(maxWidth: 120)
                .accessibilityLabel(title)
        }
    }

    private func loadPositionDrafts() {
        xPosition = preferences.string(forKey: "xNot", default: "0")
        yPosition = preferences.string(forKey: "yNot", default: "40")
    }

    private func savePosition() {
        guard let x = validPosition(xPosition), let y = validPosition(yPosition) else {
            positionMessage = "Enter a number from −1000 to 1000 for both positions."
            return
        }
        xPosition = x
        yPosition = y
        positionMessage = preferences.write(["xNot": x, "yNot": y])
            ? "Position saved."
            : "The position could not be saved. Try again."
    }

    private func validPosition(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 12 else { return nil }
        let normalized = trimmed.replacingOccurrences(of: ",", with: ".")
        guard normalized.range(of: #"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)$"#, options: .regularExpression) != nil,
              let value = Double(normalized), value.isFinite else { return nil }
        return String(min(1000, max(-1000, value)))
    }

    private func slider(
        _ title: String,
        key: String,
        default defaultValue: Double,
        range: ClosedRange<Double>,
        format: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                let value = sliderDrafts[key] ?? preferences.double(forKey: key, default: defaultValue)
                Text(String(format: format, value))
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

    private func boolBinding(_ key: String, default defaultValue: Bool) -> Binding<Bool> {
        Binding(
            get: { preferences.bool(forKey: key, default: defaultValue) },
            set: { _ = preferences.write([key: NSNumber(value: $0)]) }
        )
    }

    private func intBinding(_ key: String, default defaultValue: Int) -> Binding<Int> {
        Binding(
            get: { preferences.integer(forKey: key, default: defaultValue) },
            set: { _ = preferences.write([key: NSNumber(value: $0)]) }
        )
    }
}
