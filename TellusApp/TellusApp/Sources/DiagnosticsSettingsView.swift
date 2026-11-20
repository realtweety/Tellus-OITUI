import SwiftUI
import UIKit

struct DiagnosticsSettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var preferences = PreferenceStore(domain: .insula)
    @State private var message: String?
    @State private var isWorking = false
    @State private var confirmClearLogs = false
    @State private var confirmShareReport = false
    @State private var showShareSheet = false
    @State private var reportFileURL: URL?

    private var logLevel: Int {
        preferences.integer(forKey: "DiagnosticsLevel", default: 0)
    }

    var body: some View {
        Form {
            AppleModeBanner()
            RecoveryStatusBanner()

            Section {
                Picker("Log Detail", selection: levelBinding) {
                    Text("Normal").tag(0)
                    Text("Detailed").tag(1)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Logging")
            } footer: {
                Text("Normal keeps logs shorter. Detailed adds events and takes effect immediately, but logs may contain personal details such as app names.")
            }

            Section {
                Button("Run Status Bar Check") { runStatusBarCheck() }
                    .disabled(logLevel < 1)
            } header: {
                Text("Status Bar")
            } footer: {
                Text(logLevel < 1
                     ? "Set Log Detail to Detailed to request a status bar check. SpringBoard writes its report to the Insula log."
                     : "Requests a status bar report from SpringBoard. The report is written to the Insula log.")
            }

            Section {
                Button {
                    Task { await copyShortReport() }
                } label: {
                    actionLabel("Copy Report to Clipboard")
                }
                .disabled(isWorking)

                Button {
                    confirmShareReport = true
                } label: {
                    actionLabel("Share Full Report")
                }
                .disabled(isWorking)
            } header: {
                Text("Report")
            } footer: {
                Text("The report removes notification text and download file names, but may contain app names. Read it before sharing.")
            }

            Section {
                Label(
                    preferences.synchronizationSucceeded ? "Preferences available" : "Could not synchronize preferences",
                    systemImage: preferences.synchronizationSucceeded ? "checkmark.circle" : "exclamationmark.circle"
                )
            } header: {
                Text("Preference Connection")
            }

            Section {
                Button("Clear Log Files", role: .destructive) {
                    confirmClearLogs = true
                }
                .disabled(isWorking)
            } header: {
                Text("Log Files")
            } footer: {
                Text("Deleting the log files is safe; new log entries start fresh files.")
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Status Bar Check", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
        .confirmationDialog("Share Full Report?", isPresented: $confirmShareReport, titleVisibility: .visible) {
            Button("Generate and Share") {
                Task { await shareFullReport() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The report can include app names and detailed system events. Review it before sending.")
        }
        .confirmationDialog("Clear Log Files?", isPresented: $confirmClearLogs, titleVisibility: .visible) {
            Button("Clear Log Files", role: .destructive) {
                Task { await clearLogs() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes Insula’s current and rotated log files. New log entries start fresh files.")
        }
        .sheet(isPresented: $showShareSheet, onDismiss: removeTemporaryReport) {
            if let reportFileURL {
                ActivityView(activityItems: [reportFileURL])
                    .ignoresSafeArea()
            }
        }
        .onAppear { preferences.reload() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { preferences.reload() }
        }
    }

    private var levelBinding: Binding<Int> {
        Binding(
            get: { preferences.integer(forKey: "DiagnosticsLevel", default: 0) },
            set: { _ = preferences.write(["DiagnosticsLevel": NSNumber(value: $0)]) }
        )
    }

    private func runStatusBarCheck() {
        guard logLevel >= 1 else {
            message = "Set Log Detail to Detailed first."
            return
        }
        preferences.post("com.wilburt.oiti/Dump")
        message = "SpringBoard was asked to write a status bar report to the Insula log."
    }

    @ViewBuilder
    private func actionLabel(_ title: String) -> some View {
        if isWorking {
            HStack {
                Text(title)
                Spacer()
                ProgressView()
            }
        } else {
            Text(title)
        }
    }

    private func copyShortReport() async {
        await performReport(action: "shortReport") { report in
            UIPasteboard.general.string = report
            let lineCount = report.components(separatedBy: "\n").count
            message = "\(lineCount) lines (\((report.count + 1023) / 1024) KB) copied. Read the report before sharing; app names may appear, especially with Detailed logging enabled. Notification text and download file names are removed."
        }
    }

    private func shareFullReport() async {
        await performReport(action: "fullReport") { report in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Insula-report-\(UUID().uuidString).txt")
            do {
                try report.write(to: url, atomically: true, encoding: .utf8)
                reportFileURL = url
                showShareSheet = true
            } catch {
                message = "The report could not be saved for sharing: \(error.localizedDescription)"
            }
        }
    }

    private func clearLogs() async {
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await DiagnosticsBridge.perform("clearLogs")
            message = "Insula log files were cleared. New log entries will create fresh files."
        } catch {
            message = error.localizedDescription
        }
    }

    private func performReport(action: String, completion: (String) -> Void) async {
        isWorking = true
        defer { isWorking = false }
        do {
            completion(try await DiagnosticsBridge.perform(action))
        } catch {
            message = error.localizedDescription
        }
    }

    private func removeTemporaryReport() {
        guard let reportFileURL else { return }
        try? FileManager.default.removeItem(at: reportFileURL)
        self.reportFileURL = nil
    }
}

private struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
