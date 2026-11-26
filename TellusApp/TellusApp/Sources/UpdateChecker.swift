import Foundation

// Read-only update checking for Tellus. This file holds no UI: it fetches the
// latest GitHub release, reads package versions from the attached .deb file
// names, compares them with what is installed and returns a report. Nothing
// here downloads or installs a package.

// MARK: - Components

enum UpdateComponent: CaseIterable, Identifiable, Hashable {
    case tellus
    case insula
    case litus
    case oitCore

    var id: Self { self }

    var displayName: String {
        switch self {
        case .tellus: return "Tellus"
        case .insula: return "Insula"
        case .litus: return "Litus"
        case .oitCore: return "OITCore"
        }
    }

    /// The Debian package identifier, as used in `control` files and in the
    /// file names of the .deb assets attached to releases.
    var packageID: String {
        switch self {
        case .tellus: return "com.wilburt.tellus"
        case .insula: return "com.wilburt.oiti"
        case .litus: return "com.wilburt.oits"
        case .oitCore: return "com.wilburt.oitcore"
        }
    }
}

// MARK: - Debian version comparison

/// Version ordering with the same rules as dpkg (epoch, upstream version,
/// revision; `~` sorts before everything). This matters because installed
/// versions look like `0.3.8-1+debug` while a release's .deb is `0.3.7`.
struct DebianVersion: Comparable, Equatable {
    let raw: String
    private let epoch: Int
    private let upstream: String
    private let revision: String

    init?(_ text: String) {
        var rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty else { return nil }

        var epoch = 0
        if let colon = rest.firstIndex(of: ":") {
            guard let value = Int(rest[rest.startIndex..<colon]) else { return nil }
            epoch = value
            rest = String(rest[rest.index(after: colon)...])
        }

        var revision = ""
        if let dash = rest.lastIndex(of: "-") {
            revision = String(rest[rest.index(after: dash)...])
            rest = String(rest[rest.startIndex..<dash])
        }

        // dpkg requires the upstream version to start with a digit.
        guard let first = rest.first, first.isASCIIDigit else { return nil }

        self.raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.epoch = epoch
        self.upstream = rest
        self.revision = revision
    }

    private static func order(_ character: Character?) -> Int {
        guard let character = character else { return 0 }
        if character.isASCIIDigit { return 0 }
        if character == "~" { return -1 }
        if character.isASCII && character.isLetter { return Int(character.asciiValue ?? 0) }
        return Int(character.asciiValue ?? 0) + 256
    }

    private static func compareFragments(_ left: String, _ right: String) -> Int {
        let a = Array(left)
        let b = Array(right)
        var i = 0
        var j = 0

        while i < a.count || j < b.count {
            while (i < a.count && !a[i].isASCIIDigit) || (j < b.count && !b[j].isASCIIDigit) {
                let leftOrder = order(i < a.count ? a[i] : nil)
                let rightOrder = order(j < b.count ? b[j] : nil)
                if leftOrder != rightOrder { return leftOrder < rightOrder ? -1 : 1 }
                i += 1
                j += 1
            }

            while i < a.count && a[i] == "0" { i += 1 }
            while j < b.count && b[j] == "0" { j += 1 }

            var firstDifference = 0
            while i < a.count && a[i].isASCIIDigit && j < b.count && b[j].isASCIIDigit {
                if firstDifference == 0 {
                    firstDifference = Int(a[i].asciiValue ?? 0) - Int(b[j].asciiValue ?? 0)
                }
                i += 1
                j += 1
            }

            if i < a.count && a[i].isASCIIDigit { return 1 }
            if j < b.count && b[j].isASCIIDigit { return -1 }
            if firstDifference != 0 { return firstDifference < 0 ? -1 : 1 }
        }
        return 0
    }

    private static func compare(_ left: DebianVersion, _ right: DebianVersion) -> Int {
        if left.epoch != right.epoch { return left.epoch < right.epoch ? -1 : 1 }
        let upstreamResult = compareFragments(left.upstream, right.upstream)
        if upstreamResult != 0 { return upstreamResult }
        return compareFragments(left.revision, right.revision)
    }

    static func < (left: DebianVersion, right: DebianVersion) -> Bool {
        compare(left, right) < 0
    }

    static func == (left: DebianVersion, right: DebianVersion) -> Bool {
        compare(left, right) == 0
    }
}

private extension Character {
    var isASCIIDigit: Bool { self >= "0" && self <= "9" }
}

// MARK: - GitHub release metadata

/// The subset of GitHub's release JSON that Tellus uses. Every field except
/// `tag_name` is optional so a partial or odd release never breaks decoding.
struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String?
        let size: Int?
        let browserDownloadURL: String?
        let digest: String?

        private enum CodingKeys: String, CodingKey {
            case name
            case size
            case digest
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let name: String?
    let body: String?
    let htmlURL: String?
    let publishedAt: String?
    let isPrerelease: Bool
    let assets: [Asset]

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
        case publishedAt = "published_at"
        case prerelease
        case assets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tagName = try container.decode(String.self, forKey: .tagName)
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        body = try? container.decodeIfPresent(String.self, forKey: .body)
        htmlURL = try? container.decodeIfPresent(String.self, forKey: .htmlURL)
        publishedAt = try? container.decodeIfPresent(String.self, forKey: .publishedAt)
        isPrerelease = (try? container.decodeIfPresent(Bool.self, forKey: .prerelease)) ?? false
        assets = (try? container.decodeIfPresent([Asset].self, forKey: .assets)) ?? []
    }

    /// Packages found in the attached `<package-id>_<version>_<arch>.deb` assets.
    /// A component without a matching asset is simply absent.
    func availablePackages() -> [UpdateComponent: AvailablePackage] {
        var result: [UpdateComponent: AvailablePackage] = [:]
        for asset in assets {
            guard let fileName = asset.name, fileName.hasSuffix(".deb") else { continue }
            for component in UpdateComponent.allCases {
                let prefix = component.packageID + "_"
                guard fileName.hasPrefix(prefix) else { continue }
                let remainder = String(fileName.dropFirst(prefix.count).dropLast(".deb".count))
                let version = remainder.split(separator: "_", maxSplits: 1, omittingEmptySubsequences: false)
                    .first.map(String.init) ?? ""
                guard let parsed = DebianVersion(version) else { continue }
                if let existing = result[component], let existingVersion = DebianVersion(existing.version),
                   existingVersion >= parsed { continue }
                result[component] = AvailablePackage(
                    component: component,
                    version: parsed.raw,
                    fileName: fileName,
                    downloadURL: asset.browserDownloadURL.flatMap { URL(string: $0) },
                    size: asset.size,
                    apiDigest: Self.sha256Hex(fromDigest: asset.digest)
                )
            }
        }
        return result
    }

    /// The `SHA256SUMS` asset that release workflow runs attach, if this release has one.
    var checksumsURL: URL? {
        assets.first(where: { $0.name == "SHA256SUMS" })?
            .browserDownloadURL.flatMap { URL(string: $0) }
    }

    /// The `SHA256SUMS.sig` asset: a raw 64-byte Ed25519 signature of `SHA256SUMS`, made by the owner after the release files were tested.
    var signatureURL: URL? {
        assets.first(where: { $0.name == "SHA256SUMS.sig" })?
            .browserDownloadURL.flatMap { URL(string: $0) }
    }

    /// GitHub reports asset digests as `sha256:<64 hex digits>`.
    private static func sha256Hex(fromDigest digest: String?) -> String? {
        guard let digest = digest?.lowercased(), digest.hasPrefix("sha256:") else { return nil }
        let hex = String(digest.dropFirst("sha256:".count))
        let isHex = hex.count == 64 && hex.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
        return isHex ? hex : nil
    }
}

/// One downloadable package from a release.
struct AvailablePackage {
    let component: UpdateComponent
    let version: String
    let fileName: String
    let downloadURL: URL?
    let size: Int?
    /// SHA-256 (lowercase hex) reported by GitHub's API for the asset, when present.
    let apiDigest: String?
}

// MARK: - Errors

enum UpdateCheckError: LocalizedError {
    case offline
    case timedOut
    case noRelease
    case rateLimited
    case httpStatus(Int)
    case malformedResponse
    case network(String)

    var errorDescription: String? {
        switch self {
        case .offline:
            return "No internet connection. Connect to a network and try again."
        case .timedOut:
            return "GitHub did not respond in time. Try again in a moment."
        case .noRelease:
            return "No published release was found for the Tellus repository."
        case .rateLimited:
            return "GitHub is limiting requests from this network. Try again later."
        case .httpStatus(let code):
            return "GitHub returned an unexpected response (HTTP \(code))."
        case .malformedResponse:
            return "GitHub's release information could not be read."
        case .network(let message):
            return "The update check failed: \(message)"
        }
    }
}

// MARK: - Client

/// Decodes one list element without letting a malformed neighbour break the whole list.
private struct LossyRelease: Decodable {
    let release: GitHubRelease?

    init(from decoder: Decoder) throws {
        release = try? GitHubRelease(from: decoder)
    }
}

/// The answer to a request that carried the ETag of an earlier answer.
enum ConditionalRelease {
    case notModified
    case release(GitHubRelease, etag: String?)
}

struct GitHubReleaseClient {
    static let repository = "realtweety/Tellus-OITUI"
    // `/releases/latest` skips drafts and pre-releases, which is what a normal
    // user wants to be told about.
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    // The release list includes pre-releases, newest first.
    static let releaseListURL = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=10")!

    var session: URLSession = .shared

    /// The newest release. Pre-releases are only considered when asked for.
    func fetchLatestRelease(includePrereleases: Bool = false) async throws -> GitHubRelease {
        let url = includePrereleases ? Self.releaseListURL : Self.latestReleaseURL
        let (data, http) = try await perform(Self.request(for: url, etag: nil))
        try Self.checkStatus(http)
        return try Self.decodeRelease(from: data, includePrereleases: includePrereleases)
    }

    /// Like `fetchLatestRelease`, but sends the ETag of an earlier answer. If nothing changed, GitHub answers "304 Not Modified",
    /// which does not count against the limit of unauthenticated requests.
    func fetchLatestReleaseConditional(includePrereleases: Bool, etag: String?) async throws -> ConditionalRelease {
        let url = includePrereleases ? Self.releaseListURL : Self.latestReleaseURL
        let (data, http) = try await perform(Self.request(for: url, etag: etag))
        if http.statusCode == 304 { return .notModified }
        try Self.checkStatus(http)
        let release = try Self.decodeRelease(from: data, includePrereleases: includePrereleases)
        return .release(release, etag: http.value(forHTTPHeaderField: "ETag"))
    }

    private static func request(for url: URL, etag: String?) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Tellus-App", forHTTPHeaderField: "User-Agent")
        if let etag = etag, !etag.isEmpty {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        return request
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .cancelled:
                throw CancellationError()
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                throw UpdateCheckError.offline
            case .timedOut:
                throw UpdateCheckError.timedOut
            default:
                throw UpdateCheckError.network(error.localizedDescription)
            }
        }

        guard let http = response as? HTTPURLResponse else {
            throw UpdateCheckError.malformedResponse
        }
        return (data, http)
    }

    private static func checkStatus(_ http: HTTPURLResponse) throws {
        switch http.statusCode {
        case 200:
            return
        case 404:
            throw UpdateCheckError.noRelease
        case 429:
            throw UpdateCheckError.rateLimited
        case 403:
            // GitHub answers 403 when the unauthenticated rate limit is used up.
            if http.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0" {
                throw UpdateCheckError.rateLimited
            }
            throw UpdateCheckError.httpStatus(403)
        default:
            throw UpdateCheckError.httpStatus(http.statusCode)
        }
    }

    private static func decodeRelease(from data: Data, includePrereleases: Bool) throws -> GitHubRelease {
        if includePrereleases {
            let candidates: [LossyRelease]
            do {
                candidates = try JSONDecoder().decode([LossyRelease].self, from: data)
            } catch {
                throw UpdateCheckError.malformedResponse
            }
            guard let release = candidates.compactMap({ $0.release }).first(where: { !$0.tagName.isEmpty }) else {
                throw UpdateCheckError.noRelease
            }
            return release
        }

        do {
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            guard !release.tagName.isEmpty else { throw UpdateCheckError.malformedResponse }
            return release
        } catch {
            throw UpdateCheckError.malformedResponse
        }
    }
}

// MARK: - Report

enum InstalledVersion: Equatable {
    case version(String)
    case notInstalled
    case unknown
}

enum UpdateStatus: Equatable {
    case updateAvailable
    case upToDate
    case installedIsNewer
    case notInstalled
    case notPublished
    case cannotCompare
}

struct ComponentUpdate: Identifiable {
    let component: UpdateComponent
    let installed: InstalledVersion
    let package: AvailablePackage?
    let status: UpdateStatus

    var id: UpdateComponent { component }
    var availableVersion: String? { package?.version }
}

struct UpdateReport {
    let releaseTitle: String
    let tagName: String
    let publishedAt: Date?
    let isPrerelease: Bool
    let releaseURL: URL?
    let notes: String?
    let checksumsURL: URL?
    let signatureURL: URL?
    let components: [ComponentUpdate]

    var updatesAvailable: [ComponentUpdate] {
        components.filter { $0.status == .updateAvailable }
    }
}

enum UpdateReportBuilder {
    static func build(release: GitHubRelease, installed: [UpdateComponent: InstalledVersion]) -> UpdateReport {
        let packages = release.availablePackages()
        var components: [ComponentUpdate] = []

        for component in UpdateComponent.allCases {
            let installedVersion = installed[component] ?? .unknown
            let package = packages[component]

            // A component that is neither installed nor in the release is not interesting.
            if installedVersion == .notInstalled && package == nil { continue }

            components.append(ComponentUpdate(
                component: component,
                installed: installedVersion,
                package: package,
                status: status(installed: installedVersion, available: package?.version)
            ))
        }

        let notes = release.body?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = release.name.flatMap { $0.isEmpty ? nil : $0 } ?? release.tagName

        return UpdateReport(
            releaseTitle: title,
            tagName: release.tagName,
            publishedAt: release.publishedAt.flatMap { ISO8601DateFormatter().date(from: $0) },
            isPrerelease: release.isPrerelease,
            releaseURL: release.htmlURL.flatMap { URL(string: $0) },
            notes: (notes?.isEmpty ?? true) ? nil : notes,
            checksumsURL: release.checksumsURL,
            signatureURL: release.signatureURL,
            components: components
        )
    }

    static func status(installed: InstalledVersion, available: String?) -> UpdateStatus {
        guard let available = available else { return .notPublished }
        switch installed {
        case .notInstalled:
            return .notInstalled
        case .unknown:
            return .cannotCompare
        case .version(let text):
            guard let installedVersion = DebianVersion(text), let availableVersion = DebianVersion(available) else {
                return .cannotCompare
            }
            if installedVersion < availableVersion { return .updateAvailable }
            if installedVersion == availableVersion { return .upToDate }
            return .installedIsNewer
        }
    }
}

// MARK: - Installed versions

enum InstalledVersionReader {
    private static let statusPaths = ["/var/jb/var/lib/dpkg/status", "/var/lib/dpkg/status"]

    /// Tellus reads its own version from the build configuration (Info.plist).
    static func tellusVersion() -> InstalledVersion {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String, !version.isEmpty {
            return .version(version)
        }
        return .unknown
    }

    /// Insula's version comes from the existing SpringBoard bridge, which is
    /// the only place that reliably knows it.
    @MainActor
    static func insulaVersion() async -> InstalledVersion {
        do {
            let text = try await DiagnosticsBridge.perform("insulaVersion")
                .replacingOccurrences(of: "Insula (OITI) version ", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty || text == "unknown" { return .unknown }
            return .version(text)
        } catch {
            return .unknown
        }
    }

    /// Reads package versions straight from dpkg's status file. Whether the
    /// app's sandbox allows this on a device is unverified; when the file
    /// cannot be read the packages are reported as `.unknown`, not as missing.
    static func dpkgVersions(for components: [UpdateComponent]) -> [UpdateComponent: InstalledVersion] {
        var status: String?
        for path in statusPaths {
            if let text = try? String(contentsOfFile: path, encoding: .utf8) {
                status = text
                break
            }
        }

        guard let status = status else {
            return Dictionary(uniqueKeysWithValues: components.map { ($0, InstalledVersion.unknown) })
        }

        var result: [UpdateComponent: InstalledVersion] = [:]
        for component in components { result[component] = .notInstalled }

        for paragraph in status.components(separatedBy: "\n\n") {
            let lines = paragraph.components(separatedBy: "\n")
            guard let packageLine = lines.first(where: { $0.hasPrefix("Package: ") }) else { continue }
            let packageID = String(packageLine.dropFirst("Package: ".count)).trimmingCharacters(in: .whitespaces)
            guard let component = components.first(where: { $0.packageID == packageID }) else { continue }
            if let versionLine = lines.first(where: { $0.hasPrefix("Version: ") }) {
                let version = String(versionLine.dropFirst("Version: ".count)).trimmingCharacters(in: .whitespaces)
                result[component] = version.isEmpty ? .unknown : .version(version)
            }
        }
        return result
    }

    @MainActor
    static func collect() async -> [UpdateComponent: InstalledVersion] {
        // File reading happens off the main thread.
        var installed = await Task.detached(priority: .userInitiated) {
            dpkgVersions(for: [.litus, .oitCore])
        }.value
        installed[.tellus] = tellusVersion()
        installed[.insula] = await insulaVersion()
        return installed
    }
}
