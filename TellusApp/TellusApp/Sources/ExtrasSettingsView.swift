import SwiftUI

// Tellus > Insula > Extras (0.4.1): the more playful switches. Everything here is off by default.
struct ExtrasSettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var preferences = PreferenceStore(domain: .insula)

    var body: some View {
        Form {
            AppleModeBanner()
            RecoveryStatusBanner()

            Section {
                Toggle("Double Tap Opens Tellus", isOn: doubleTapBinding)
            } footer: {
                Text("Double tap the Island while it is idle to open Tellus. It does nothing while Insula shows something, while the phone is locked, or in Apple Mode. Takes effect immediately. Needs Insula 0.4.1 or later.")
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
        .navigationTitle("Extras")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { preferences.reload() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { preferences.reload() }
        }
    }

    private var doubleTapBinding: Binding<Bool> {
        Binding(
            get: { preferences.bool(forKey: "ExtrasDoubleTapOpensTellus", default: false) },
            set: { _ = preferences.write(["ExtrasDoubleTapOpensTellus": NSNumber(value: $0)]) }
        )
    }
}
