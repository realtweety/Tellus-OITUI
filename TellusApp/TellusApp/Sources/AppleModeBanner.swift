import SwiftUI

struct AppleModeBanner: View {
    @StateObject private var preferences = PreferenceStore(domain: .insula)

    var body: some View {
        Group {
            if preferences.bool(forKey: "appleMode", default: false) {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Apple Mode Is On")
                            .font(.headline)
                        Text("Custom appearance, notifications, startup animation, and download progress are paused. Your saved settings remain in place.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Turn Off Apple Mode") {
                            _ = preferences.write(["appleMode": false])
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(Color.blue.opacity(0.12))
            }
        }
        .task { preferences.reload() }
    }
}
