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
                NavigationLink {
                    InsulaStatusView()
                } label: {
                    Label("Insula Status", systemImage: "stethoscope")
                }
            } footer: {
                Text("Shows why Insula might be off: safe mode, the switches, the respring-loop guard and the last startup check.")
            }

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

// MARK: - Insula Status (0.4.1, IDEAS #17)

// What SpringBoard answers to the "recoveryState" request. Every field is optional: Insula older than 0.4.1 sends only
// safeMode and elementsOff, and the page then says that some details need Insula 0.4.1 or later.
private struct InsulaStatusSnapshot: Decodable {
    struct SafeMode: Decodable {
        let time: Double?
        let reason: String?
    }

    struct ElementsOff: Decodable {
        let time: Double?
        let failures: Int?
    }

    struct LoopGuard: Decodable {
        let enabled: Bool?
        let launches: Int?
        let maxLaunches: Int?
        let windowSeconds: Int?
    }

    struct SelfCheck: Decodable {
        let time: Double?
        let result: String?
        let issues: [String]?
    }

    let safeMode: SafeMode?
    let elementsOff: ElementsOff?
    let islandEnabled: Bool?
    let appleMode: Bool?
    let hooksInstalled: Bool?
    let build: String?
    let loopGuard: LoopGuard?
    let selfCheck: SelfCheck?

    enum CodingKeys: String, CodingKey {
        case safeMode, elementsOff, islandEnabled, appleMode, hooksInstalled, build, selfCheck
        case loopGuard = "guard"
    }

    // The main reasons Insula is not showing, most important first. Empty when nothing is switched off.
    var reasons: [String] {
        var list: [String] = []
        if safeMode != nil {
            list.append("Safe mode is on: Insula switched itself off after repeated SpringBoard restarts, so its hooks are not installed.")
        }
        if islandEnabled == false {
            list.append("The Insula switch is off.")
        }
        if appleMode == true {
            list.append("Apple Mode is on: every customization is paused.")
        }
        if elementsOff != nil {
            list.append("Island elements are switched off until the next respring.")
        }
        if selfCheck?.result == "warn" {
            list.append("The last startup check found a problem (see Startup Check below).")
        }
        return list
    }
}

struct InsulaStatusView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var snapshot: InsulaStatusSnapshot?
    @State private var errorText: String?
    @State private var isLoading = false

    var body: some View {
        Form {
            AppleModeBanner()
            RecoveryStatusBanner()

            if let errorText {
                Section {
                    Label("No answer from SpringBoard", systemImage: "exclamationmark.triangle")
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Summary")
                } footer: {
                    Text("If Insula is installed, it may be switched off in your tweak manager or injection may be off, or SpringBoard may still be starting. Pull down to try again.")
                }
            } else if let snapshot {
                summarySection(snapshot)
                detailsSection(snapshot)
                guardSection(snapshot)
                selfCheckSection(snapshot)
            } else {
                Section {
                    HStack {
                        ProgressView()
                        Text("Asking SpringBoard…")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Insula Status")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .refreshable { await refresh() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { Task { await refresh() } }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private func summarySection(_ snapshot: InsulaStatusSnapshot) -> some View {
        let reasons = snapshot.reasons
        Section {
            if reasons.isEmpty {
                Label("Nothing is switched off", systemImage: "checkmark.circle")
                Text("Insula is loaded in SpringBoard and its hooks are installed.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(reasons, id: \.self) { reason in
                    Label(reason, systemImage: "exclamationmark.circle")
                }
            }
        } header: {
            Text("Summary")
        } footer: {
            if snapshot.build == nil {
                Text("Some details need Insula 0.4.1 or later. Only safe mode and Island elements are shown with this Insula version.")
            }
        }
    }

    @ViewBuilder
    private func detailsSection(_ snapshot: InsulaStatusSnapshot) -> some View {
        if snapshot.build != nil {
            Section {
                row("Insula switch", flag(snapshot.islandEnabled, on: "On", off: "Off"))
                row("Apple Mode", flag(snapshot.appleMode, on: "On", off: "Off"))
                row("Safe mode", snapshot.safeMode == nil ? "Off" : "On" + timeText(snapshot.safeMode?.time))
                row("Hooks installed", flag(snapshot.hooksInstalled, on: "Yes", off: "No"))
                row("Island elements", snapshot.elementsOff == nil ? "On" : "Off until respring" + timeText(snapshot.elementsOff?.time))
                row("Running build", snapshot.build ?? "")
            } header: {
                Text("Now")
            } footer: {
                if let reason = snapshot.safeMode?.reason {
                    Text("Safe mode reason: \(reason).")
                }
            }
        }
    }

    @ViewBuilder
    private func guardSection(_ snapshot: InsulaStatusSnapshot) -> some View {
        if let loopGuard = snapshot.loopGuard {
            Section {
                if loopGuard.enabled == false {
                    row("Respring-loop guard", "Off")
                } else {
                    row("Respring-loop guard", "On")
                    row(
                        "SpringBoard launches counted",
                        "\(loopGuard.launches ?? 0) of \(loopGuard.maxLaunches ?? 0) in \(loopGuard.windowSeconds ?? 0) s"
                    )
                }
            } header: {
                Text("Respring-Loop Guard")
            } footer: {
                Text("Safe mode starts when SpringBoard restarts that many times inside the time window. A launch that stays up for a while clears the count, and a respring you ask for in Insula or Tellus is not counted.")
            }
        }
    }

    @ViewBuilder
    private func selfCheckSection(_ snapshot: InsulaStatusSnapshot) -> some View {
        if snapshot.build != nil {
            Section {
                if let check = snapshot.selfCheck {
                    row("Result", resultText(check.result) + timeText(check.time))
                    ForEach(check.issues ?? [], id: \.self) { issue in
                        Text(issue)
                            .font(.footnote)
                    }
                } else {
                    row("Result", "Not run yet")
                }
            } header: {
                Text("Startup Check")
            } footer: {
                Text("Insula compares the Island setting with the device identity a few seconds after SpringBoard starts. The Insula log has the full details.")
            }
        }
    }

    // MARK: Helpers

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func flag(_ value: Bool?, on: String, off: String) -> String {
        guard let value else { return "Unknown" }
        return value ? on : off
    }

    private func resultText(_ result: String?) -> String {
        switch result {
        case "ok": return "OK"
        case "warn": return "Problem found"
        case "unknown": return "Could not check"
        default: return "Unknown"
        }
    }

    private func timeText(_ timestamp: Double?) -> String {
        guard let timestamp else { return "" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return " (\(formatter.string(from: Date(timeIntervalSince1970: timestamp))))"
    }

    private func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let response = try await DiagnosticsBridge.perform("recoveryState")
            snapshot = try JSONDecoder().decode(InsulaStatusSnapshot.self, from: Data(response.utf8))
            errorText = nil
        } catch {
            snapshot = nil
            errorText = error.localizedDescription
        }
    }
}
