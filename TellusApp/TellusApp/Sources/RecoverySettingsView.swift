import CoreFoundation
import SwiftUI

struct RecoverySettingsView: View {
    @State private var confirmation: RecoveryAction?

    var body: some View {
        Form {
            AppleModeBanner()
            RecoveryStatusBanner()

            Section {
                Button("Clear Safe Mode & Respring", role: .destructive) {
                    confirmation = .clearSafeMode
                }
            } footer: {
                Text("Clears Insula’s Safe Mode recovery state and restarts SpringBoard. Use this after repeated SpringBoard crashes have switched Insula off.")
            }

            Section {
                Label("Requires Insula 0.3.8 or later", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            } footer: {
                Text("These actions use Insula’s SpringBoard-side request handler. The app does not access recovery files directly.")
            }
        }
        .navigationTitle("Recovery")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            confirmation?.title ?? "",
            isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
            titleVisibility: .visible
        ) {
            if let confirmation {
                Button(confirmation.buttonTitle, role: .destructive) {
                    send(confirmation)
                }
            }
            Button("Cancel", role: .cancel) { confirmation = nil }
        } message: {
            Text(confirmation?.message ?? "")
        }
    }

    private func send(_ action: RecoveryAction) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("com.wilburt.oiti/ClearSafeModeAndRespring" as CFString),
            nil,
            nil,
            true
        )
        confirmation = nil
    }
}

private enum RecoveryAction {
    case clearSafeMode

    var title: String {
        switch self {
        case .clearSafeMode: "Clear Safe Mode and respring?"
        }
    }

    var buttonTitle: String {
        switch self {
        case .clearSafeMode: "Clear & Respring"
        }
    }

    var message: String {
        switch self {
        case .clearSafeMode: "Insula’s Safe Mode files will be cleared, then SpringBoard will restart."
        }
    }
}
