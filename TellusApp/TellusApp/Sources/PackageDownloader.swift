import Foundation
import CryptoKit

// Downloads a release package and checks it against the release's SHA256SUMS list. This file never installs anything: a
// checked .deb is only stored in the app's cache directory. A release must also carry SHA256SUMS.sig, the owner's Ed25519
// signature of SHA256SUMS. The app does NOT verify that signature (the public keys live only in the root helper, which is the
// authority and checks it again at install time); it only makes sure the signature is there and has the right size, and keeps the
// exact bytes of both files so the installer can hand them to the helper.

enum PackageDownloadError: LocalizedError {
    case invalidFileName
    case invalidDownloadURL
    case releaseNotSigned
    case signatureUnreadable
    case checksumListUnreadable
    case checksumListMissingPackage
    case checksumSourcesDisagree
    case offline
    case timedOut
    case httpStatus(Int)
    case unexpectedHost
    case sizeMismatch
    case notADebianArchive
    case hashMismatch
    case fileSystem(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .invalidFileName:
            return "The release lists a package file name that is not safe to use."
        case .invalidDownloadURL:
            return "The release lists a download address that is not the official repository."
        case .releaseNotSigned:
            return "This release is not signed, so Tellus will not install it. You can still install its .deb yourself with Sileo, Zebra or dpkg."
        case .signatureUnreadable:
            return "The release's signature file is not a valid signature (it must be exactly 64 bytes)."
        case .checksumListUnreadable:
            return "The release's checksum list could not be read."
        case .checksumListMissingPackage:
            return "The release's checksum list does not include this package."
        case .checksumSourcesDisagree:
            return "GitHub's digest and the release's checksum list disagree, so the package was not downloaded."
        case .offline:
            return "No internet connection. Connect to a network and try again."
        case .timedOut:
            return "The download timed out. Try again in a moment."
        case .httpStatus(let code):
            return "GitHub returned an unexpected response while downloading (HTTP \(code))."
        case .unexpectedHost:
            return "The download was redirected somewhere unexpected and was discarded."
        case .sizeMismatch:
            return "The downloaded file is not the size the release lists. It was discarded."
        case .notADebianArchive:
            return "The downloaded file is not a Debian package. It was discarded."
        case .hashMismatch:
            return "The downloaded file does not match its checksum. It was discarded."
        case .fileSystem(let message):
            return "The package could not be saved: \(message)"
        case .network(let message):
            return "The download failed: \(message)"
        }
    }
}

struct VerifiedPackage {
    let package: AvailablePackage
    let fileURL: URL
    let sha256: String
    /// The exact bytes of the release's `SHA256SUMS` and `SHA256SUMS.sig`. The installer puts them next to the package right before
    /// it calls the root helper, which verifies the signature and takes the expected hash from the manifest.
    let manifest: Data
    let signature: Data
}

struct PackageDownloader {
    var session: URLSession = .shared

    /// Folders to try for storing verified packages, best first; the first one that works is used.
    private static func storageCandidates() -> [URL] {
        // Tellus may not write inside its own container, but it can write to these shared folders.
        // The root helper only accepts files from the first two.
        var directories = [
            URL(fileURLWithPath: "/var/mobile/Library/Caches/TellusUpdates", isDirectory: true),
            URL(fileURLWithPath: "/var/jb/var/mobile/Library/Caches/TellusUpdates", isDirectory: true)
        ]
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            directories.append(caches.appendingPathComponent("TellusUpdates", isDirectory: true))
        }
        directories.append(FileManager.default.temporaryDirectory.appendingPathComponent("TellusUpdates", isDirectory: true))
        return directories
    }

    private static func store(_ data: Data, named fileName: String) throws -> URL {
        var failures: [String] = []
        for directory in storageCandidates() {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let destination = directory.appendingPathComponent(fileName)
                try data.write(to: destination, options: .atomic)
                return destination
            } catch {
                failures.append("\(directory.path): \(error.localizedDescription)")
            }
        }
        throw PackageDownloadError.fileSystem("no writable folder (" + failures.joined(separator: "; ") + ")")
    }

    func downloadAndVerify(_ package: AvailablePackage, checksumsURL: URL?, signatureURL: URL?) async throws -> VerifiedPackage {
        let fileName = try Self.validatedFileName(package.fileName)
        guard let downloadURL = package.downloadURL else { throw PackageDownloadError.invalidDownloadURL }
        try Self.validateReleaseAssetURL(downloadURL)

        // A release without both files cannot be installed by Tellus.
        guard let checksumsURL = checksumsURL, let signatureURL = signatureURL else { throw PackageDownloadError.releaseNotSigned }
        try Self.validateReleaseAssetURL(checksumsURL)
        try Self.validateReleaseAssetURL(signatureURL)

        // Decide what the file must hash to before downloading it.
        let manifest = try await fetchSmallFile(checksumsURL, maximumBytes: 64 * 1024)
        let signature = try await fetchSmallFile(signatureURL, maximumBytes: 1024)
        guard signature.count == 64 else { throw PackageDownloadError.signatureUnreadable }
        let expected = try Self.expectedSHA256(for: package, fileName: fileName, manifest: manifest)

        // Packages are small, so the bytes are held in memory, checked, and only then written to disk.
        // (URLSession's download mode writes its own temporary file, which Tellus is not always allowed to do.)
        let maximumBytes = package.size ?? 50 * 1024 * 1024
        let data = try await fetchData(downloadURL, maximumBytes: maximumBytes)

        if let expectedSize = package.size, data.count != expectedSize {
            throw PackageDownloadError.sizeMismatch
        }

        // A .deb is an `ar` archive, which starts with `!<arch>` and a newline.
        guard data.starts(with: Data("!<arch>\n".utf8)) else {
            throw PackageDownloadError.notADebianArchive
        }

        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else { throw PackageDownloadError.hashMismatch }

        let destination = try Self.store(data, named: fileName)
        return VerifiedPackage(package: package, fileURL: destination, sha256: actual, manifest: manifest, signature: signature)
    }

    // MARK: Checksums

    /// The package's hash from the release's `SHA256SUMS` bytes. GitHub's own API digest, when it has one, must agree.
    private static func expectedSHA256(for package: AvailablePackage, fileName: String, manifest: Data) throws -> String {
        let list = try parseChecksumList(manifest)
        guard let listed = list[fileName] else { throw PackageDownloadError.checksumListMissingPackage }
        if let digest = package.apiDigest, digest != listed { throw PackageDownloadError.checksumSourcesDisagree }
        return listed
    }

    private static func parseChecksumList(_ data: Data) throws -> [String: String] {
        // The list is a few hundred bytes; anything large is not a checksum list.
        guard data.count <= 64 * 1024, let text = String(data: data, encoding: .utf8) else {
            throw PackageDownloadError.checksumListUnreadable
        }

        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            // "<64 hex>  <file name>" (shasum text mode) or "<64 hex> *<file name>" (binary mode)
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let hash = parts[0].lowercased()
            var name = String(parts[1]).trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("*") { name.removeFirst() }
            guard hash.count == 64, hash.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else { continue }
            result[name] = hash
        }
        guard !result.isEmpty else { throw PackageDownloadError.checksumListUnreadable }
        return result
    }

    // MARK: Fetching

    /// A small release asset (the checksum list or the signature), exactly as GitHub serves it.
    private func fetchSmallFile(_ url: URL, maximumBytes: Int) async throws -> Data {
        let request = Self.request(for: url, timeout: 15)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw Self.map(error)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PackageDownloadError.network(error.localizedDescription)
        }
        try Self.checkResponse(response)
        guard data.count <= maximumBytes else { throw PackageDownloadError.checksumListUnreadable }
        return data
    }

    private func fetchData(_ url: URL, maximumBytes: Int) async throws -> Data {
        let request = Self.request(for: url, timeout: 60)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw Self.map(error)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PackageDownloadError.network(error.localizedDescription)
        }
        try Self.checkResponse(response)
        guard data.count <= maximumBytes else { throw PackageDownloadError.sizeMismatch }
        return data
    }

    private static func request(for url: URL, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Tellus-App", forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func checkResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw PackageDownloadError.httpStatus(0) }
        guard http.statusCode == 200 else { throw PackageDownloadError.httpStatus(http.statusCode) }
        // Release assets redirect to GitHub's asset storage; nothing else is acceptable.
        if let host = http.url?.host?.lowercased() {
            let allowed = host == "github.com" || host.hasSuffix(".githubusercontent.com")
            guard allowed else { throw PackageDownloadError.unexpectedHost }
        }
    }

    private static func map(_ error: URLError) -> Error {
        switch error.code {
        case .cancelled:
            return CancellationError()
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            return PackageDownloadError.offline
        case .timedOut:
            return PackageDownloadError.timedOut
        default:
            return PackageDownloadError.network(error.localizedDescription)
        }
    }

    // MARK: Validation

    /// Only plain `.deb` file names, never a path.
    private static func validatedFileName(_ name: String) throws -> String {
        guard name.hasSuffix(".deb"),
              !name.isEmpty,
              !name.contains("/"),
              !name.contains("\\"),
              !name.hasPrefix("."),
              name == (name as NSString).lastPathComponent else {
            throw PackageDownloadError.invalidFileName
        }
        return name
    }

    /// Downloads must come from this repository's release assets on github.com over HTTPS.
    private static func validateReleaseAssetURL(_ url: URL) throws {
        let prefix = "/\(GitHubReleaseClient.repository)/releases/download/"
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "github.com",
              url.path.hasPrefix(prefix) else {
            throw PackageDownloadError.invalidDownloadURL
        }
    }
}
