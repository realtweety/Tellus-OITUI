import Foundation

// Installs a package that PackageDownloader has already checked, by asking the root helper to do it. The helper does not trust
// this app: it verifies the Ed25519 signature of SHA256SUMS itself, takes the expected hash from that signed list, and repeats
// every other check, and it only accepts Tellus's own packages. This file only puts the release's SHA256SUMS and SHA256SUMS.sig
// next to the package (under exactly those names) and starts the helper, so it is deliberately thin.

struct InstallOutcome {
    let succeeded: Bool
    /// One plain sentence for the user.
    let summary: String
    /// What the helper printed, for the "Details" view.
    let log: String
}

struct PackageInstaller {
    static let helperPath = "/var/jb/usr/libexec/tellus-helper"

    /// The helper only accepts these exact file names, in the same folder as the package.
    static let manifestFileName = "SHA256SUMS"
    static let signatureFileName = "SHA256SUMS.sig"

    /// Components Tellus may install. Litus is not hooked up yet.
    static let installableComponents: Set<UpdateComponent> = [.insula, .oitCore, .tellus]

    func install(_ verified: VerifiedPackage) async -> InstallOutcome {
        let component = verified.package.component
        guard Self.installableComponents.contains(component) else {
            return InstallOutcome(succeeded: false,
                                  summary: "\(component.displayName) cannot be installed from Tellus yet.",
                                  log: "")
        }

        // The manifest and signature go into the same folder as the package, right before the helper runs, so a different
        // download in between can never change them.
        let folder = verified.fileURL.deletingLastPathComponent()
        let manifestURL = folder.appendingPathComponent(Self.manifestFileName)
        let signatureURL = folder.appendingPathComponent(Self.signatureFileName)
        do {
            try verified.manifest.write(to: manifestURL, options: .atomic)
            try verified.signature.write(to: signatureURL, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: manifestURL)
            try? FileManager.default.removeItem(at: signatureURL)
            return InstallOutcome(succeeded: false,
                                  summary: "\(component.displayName) was not installed: the signed checksum list could not be saved (\(error.localizedDescription)).",
                                  log: "")
        }

        let path = verified.fileURL.path
        let manifestPath = manifestURL.path
        let signaturePath = signatureURL.path
        let packageID = component.packageID

        let outcome = await Task.detached(priority: .userInitiated) {
            Self.runHelper(path: path, manifestPath: manifestPath, signaturePath: signaturePath,
                           packageID: packageID, displayName: component.displayName)
        }.value

        try? FileManager.default.removeItem(at: manifestURL)
        try? FileManager.default.removeItem(at: signatureURL)
        if outcome.succeeded {
            // The verified file is no longer needed.
            try? FileManager.default.removeItem(at: verified.fileURL)
        }
        return outcome
    }

    /// Blocking: runs on a background task.
    private static func runHelper(path: String, manifestPath: String, signaturePath: String,
                                  packageID: String, displayName: String) -> InstallOutcome {
        var buffer = [CChar](repeating: 0, count: 16384)
        var status: Int32 = -1

        // Up to five minutes. If that runs out the install is NOT killed: it keeps running without Tellus.
        let result = tellus_spawn_capture_ex(helperPath, "--install", path, manifestPath, signaturePath, packageID,
                                             1, 300_000, 0, &buffer, buffer.count, &status)
        let log = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)

        if result == ETIMEDOUT {
            return InstallOutcome(
                succeeded: false,
                summary: "The install of \(displayName) is taking longer than expected and is still running. Check again in a minute.",
                log: log
            )
        }
        if result != 0 {
            let reason = String(cString: strerror(result))
            return InstallOutcome(
                succeeded: false,
                summary: "The installer could not be started (\(reason)).",
                log: log
            )
        }
        if status == 0 {
            let summary = packageID == UpdateComponent.tellus.packageID
                ? "Tellus was updated. Close and reopen Tellus to use the new version."
                : "\(displayName) was installed."
            return InstallOutcome(succeeded: true, summary: summary, log: log)
        }

        // The helper's refusals about the signed checksum list and the version get a plain explanation.
        let reasons: [Int32: String] = [
            18: "the package does not match the signed checksum list",
            21: "the signed checksum list or its signature is missing or not usable",
            22: "the release is not signed by a key that Tellus trusts",
            23: "the signed checksum list does not list this package",
            24: "that version is older than the installed one, and Tellus does not downgrade",
            25: "the installed version could not be compared with the new one"
        ]
        if let reason = reasons[status] {
            return InstallOutcome(succeeded: false, summary: "\(displayName) was not installed: \(reason).", log: log)
        }

        let lastError = log.split(separator: "\n").last(where: { $0.hasPrefix("ERROR:") })
            .map { String($0.dropFirst("ERROR:".count)).trimmingCharacters(in: .whitespaces) }
        return InstallOutcome(
            succeeded: false,
            summary: "\(displayName) was not installed" + (lastError.map { ": \($0)." } ?? " (exit \(status))."),
            log: log
        )
    }
}
