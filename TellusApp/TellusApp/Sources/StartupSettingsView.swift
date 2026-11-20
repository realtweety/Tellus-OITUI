import SwiftUI

struct StartupSettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var preferences = PreferenceStore(domain: .insula)

    var body: some View {
        Form {
            AppleModeBanner()
            RecoveryStatusBanner()

            Section {
                Toggle("Enable Hello Animation", isOn: boolBinding)
            } footer: {
                Text("Plays a Hello animation after a respring, once the phone is unlocked. It plays at most once every five minutes. Turning it on requires a respring; turning it off takes effect immediately.")
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
        .navigationTitle("Startup Animation")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { preferences.reload() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { preferences.reload() }
        }
    }

    private var boolBinding: Binding<Bool> {
        Binding(
            get: { preferences.bool(forKey: "IslandStartupHelloEnabled", default: false) },
            set: { _ = preferences.write(["IslandStartupHelloEnabled": NSNumber(value: $0)]) }
        )
    }
}
