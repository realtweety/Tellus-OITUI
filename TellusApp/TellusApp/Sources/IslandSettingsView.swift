import SwiftUI

struct IslandSettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var preferences = PreferenceStore(domain: .insula)
    @State private var xPosition = "0"
    @State private var yPosition = "20.5"
    @State private var saveMessage: String?
    @State private var islandMessage: String?
    @State private var isUpdatingIsland = false

    var body: some View {
        Form {
            AppleModeBanner()
            RecoveryStatusBanner()

            Section {
                Toggle("Enable Dynamic Island", isOn: islandEnabledBinding)
                    .disabled(isUpdatingIsland)
            } footer: {
                Text("Turning this on or off needs a respring. Tellus uses Insula’s original-value backup and restore for the device identity change.")
            }

            Section {
                Toggle("Apple Mode", isOn: boolBinding("appleMode", default: false))
            } footer: {
                Text("Makes the Island look and behave like stock iOS. Your saved customizations remain in place; position settings stay active.")
            }

            Section {
                Toggle("Use Custom Position", isOn: boolBinding("posEnabled", default: false))
                positionField("X Position", text: $xPosition)
                positionField("Y Position", text: $yPosition)
                Button("Save Position") { savePosition() }
                Button("Reset Position", role: .destructive) {
                    xPosition = "0"
                    yPosition = "20.5"
                    _ = preferences.write(["xPos": "0", "yPos": "20.5"])
                    saveMessage = "Position reset to X 0, Y 20.5."
                }
            } header: {
                Text("Position")
            } footer: {
                Text("Positions are measured in points. The tweak limits the applied position to the screen bounds.")
            }

            Section {
                Toggle("Hide When Not in Use", isOn: boolBinding("hideEnabled", default: false))
                Toggle("Disable Island Outline", isOn: boolBinding("lineDisabled", default: false))
            } footer: {
                Text("Changing Hide When Not in Use requires a respring. Outline changes apply immediately.")
            }

            Section {
                Picker("Status Bar Layout", selection: stringBinding("StatusBarLayout", default: "auto")) {
                    Text("Automatic").tag("auto")
                    Text("Off (leave as iOS chooses)").tag("off")
                    Text("828 px (iPhone XR, 11)").tag("_UIStatusBarVisualProvider_Split828")
                    Text("1080 px (iPhone 12 mini, 13 mini)").tag("_UIStatusBarVisualProvider_Split1080")
                    Text("1080 px, wide").tag("_UIStatusBarVisualProvider_Split1080_Wide")
                    Text("1125 px (iPhone X, XS, 11 Pro)").tag("_UIStatusBarVisualProvider_Split1125")
                    Text("1170 px (iPhone 12, 13, 14)").tag("_UIStatusBarVisualProvider_Split1170")
                    Text("Dynamic Island, medium").tag("_UIStatusBarVisualProvider_DynamicSplitMedium")
                    Text("Dynamic Island").tag("_UIStatusBarVisualProvider_DynamicSplit")
                }
            } header: {
                Text("Status Bar")
            } footer: {
                Text("Experimental. Changing this layout requires a respring. On supported notched iPhones, Automatic is usually the best choice.")
            }

            Section {
                Label(
                    preferences.synchronizationSucceeded ? "Preferences available" : "Could not synchronize preferences",
                    systemImage: preferences.synchronizationSucceeded ? "checkmark.circle" : "exclamationmark.circle"
                )
            } header: {
                Text("Preference Connection")
            }
        }
        .navigationTitle("Island")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Position", isPresented: Binding(get: { saveMessage != nil }, set: { if !$0 { saveMessage = nil } })) {
            Button("OK", role: .cancel) { saveMessage = nil }
        } message: {
            Text(saveMessage ?? "")
        }
        .alert("Enable Dynamic Island", isPresented: Binding(get: { islandMessage != nil }, set: { if !$0 { islandMessage = nil } })) {
            Button("OK", role: .cancel) { islandMessage = nil }
        } message: {
            Text(islandMessage ?? "")
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
        xPosition = preferences.string(forKey: "xPos", default: "0")
        yPosition = preferences.string(forKey: "yPos", default: "20.5")
    }

    private func savePosition() {
        guard let x = validPosition(xPosition), let y = validPosition(yPosition) else {
            saveMessage = "Enter a number from −1000 to 1000 for both positions."
            return
        }
        xPosition = x
        yPosition = y
        if preferences.write(["xPos": x, "yPos": y]) {
            saveMessage = "Position saved."
        } else {
            saveMessage = "The position could not be saved. Try again."
        }
    }

    private func validPosition(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 12 else { return nil }
        let normalized = trimmed.replacingOccurrences(of: ",", with: ".")
        guard normalized.range(of: #"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)$"#, options: .regularExpression) != nil,
              let value = Double(normalized), value.isFinite else { return nil }
        return String(min(1000, max(-1000, value)))
    }

    private func boolBinding(_ key: String, default defaultValue: Bool) -> Binding<Bool> {
        Binding(
            get: { preferences.bool(forKey: key, default: defaultValue) },
            set: { _ = preferences.write([key: NSNumber(value: $0)]) }
        )
    }

    private func stringBinding(_ key: String, default defaultValue: String) -> Binding<String> {
        Binding(
            get: { preferences.string(forKey: key, default: defaultValue) },
            set: { _ = preferences.write([key: $0]) }
        )
    }

    private var islandEnabledBinding: Binding<Bool> {
        Binding(
            get: { preferences.bool(forKey: "islandEnabled", default: false) },
            set: { value in
                guard preferences.write(["islandEnabled": NSNumber(value: value)]) else {
                    islandMessage = "The Island setting could not be saved."
                    return
                }
                isUpdatingIsland = true
                Task {
                    defer { isUpdatingIsland = false }
                    do {
                        let result = try await DiagnosticsBridge.perform("islandIdentity")
                        islandMessage = result == "ok"
                            ? "Saved. Respring to apply the change."
                            : result
                    } catch {
                        islandMessage = error.localizedDescription
                    }
                }
            }
        )
    }
}
