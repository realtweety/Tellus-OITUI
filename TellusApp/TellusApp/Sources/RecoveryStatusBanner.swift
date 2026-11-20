import CoreFoundation
import SwiftUI

struct RecoveryStatusBanner: View {
    @State private var snapshot: RecoverySnapshot?
    @State private var confirmation: RecoveryBannerAction?

    var body: some View {
        Group {
            if let safeMode = snapshot?.safeMode {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Insula Safe Mode Is On")
                            .font(.headline)
                        Text("Insula switched itself off after \(safeMode.reason ?? "repeated SpringBoard restarts")\(formattedTime(safeMode.time)). Your settings are saved.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Clear Safe Mode & Respring", role: .destructive) {
                            confirmation = .clearSafeMode
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(Color.orange.opacity(0.16))
            }

            if let elementsOff = snapshot?.elementsOff {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Island Elements Are Switched Off")
                            .font(.headline)
                        Text("SpringBoard raised \(elementsOff.failures ?? 0) errors while an Island element was showing\(formattedTime(elementsOff.time)). Notifications, the startup animation, and the Detailed download look are off until you respring.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Respring", role: .destructive) {
                            confirmation = .respring
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(Color.yellow.opacity(0.16))
            }
        }
        .task { await refresh() }
        .confirmationDialog(
            confirmation?.title ?? "",
            isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
            titleVisibility: .visible
        ) {
            if let confirmation {
                Button(confirmation.buttonTitle, role: .destructive) {
                    post(confirmation.notification)
                    self.confirmation = nil
                }
            }
            Button("Cancel", role: .cancel) { confirmation = nil }
        } message: {
            Text(confirmation?.message ?? "")
        }
    }

    private func refresh() async {
        do {
            let response = try await DiagnosticsBridge.perform("recoveryState")
            snapshot = try JSONDecoder().decode(RecoverySnapshot.self, from: Data(response.utf8))
        } catch {
            snapshot = nil
        }
    }

    private func formattedTime(_ timestamp: Double?) -> String {
        guard let timestamp else { return "" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return " (\(formatter.string(from: Date(timeIntervalSince1970: timestamp))))"
    }

    private func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil,
            nil,
            true
        )
    }
}

private struct RecoverySnapshot: Decodable {
    let safeMode: SafeModeFlag?
    let elementsOff: ElementsOffFlag?
}

private struct SafeModeFlag: Decodable {
    let time: Double?
    let reason: String?
}

private struct ElementsOffFlag: Decodable {
    let time: Double?
    let failures: Int?
}

private enum RecoveryBannerAction {
    case clearSafeMode
    case respring

    var title: String {
        switch self {
        case .clearSafeMode: "Clear safe mode?"
        case .respring: "Respring?"
        }
    }

    var buttonTitle: String {
        switch self {
        case .clearSafeMode: "Clear & Respring"
        case .respring: "Respring"
        }
    }

    var message: String {
        switch self {
        case .clearSafeMode: "Insula’s Safe Mode files will be cleared, then SpringBoard will restart."
        case .respring: "SpringBoard will restart and Island elements will be re-enabled."
        }
    }

    var notification: String {
        switch self {
        case .clearSafeMode: "com.wilburt.oiti/ClearSafeModeAndRespring"
        case .respring: "com.wilburt.oiti/Respring"
        }
    }
}
