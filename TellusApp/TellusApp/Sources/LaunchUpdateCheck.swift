import Foundation

// The optional check for updates when Tellus opens. It never installs anything: it only works out how many components have a newer
// release and shows that as a badge on About. Off by default (UpdateSettings.checkOnLaunch).
//
// What it avoids, so it is polite to GitHub's limit of 60 unauthenticated requests an hour per address:
//  - GitHub's answer is trusted for an hour, so reopening Tellus asks nothing;
//  - when it does ask, it sends the ETag of the last answer, and "304 Not Modified" does not use up the limit;
//  - after a failed request (offline, rate limited, a server error) it does not ask again for 15 minutes and shows what it knew.
// Failures are silent: the check is a convenience and must never get in the way. The check screen under About still shows errors.

/// What the launch check remembers between runs (a few hundred bytes, in Tellus's preferences).
struct LaunchCheckCache: Codable, Equatable {
    /// "stable" or "prerelease": the ETag belongs to one of two different GitHub URLs.
    var mode: String
    var etag: String?
    /// Seconds since 1970 of the last answer from GitHub (a release or "not modified"); 0 if there never was one.
    var checkedAt: Double
    /// Seconds since 1970 of the last failed request, if it was after the last answer.
    var failedAt: Double?
    var tag: String
    /// Package ID to version, for the packages attached to that release.
    var versions: [String: String]
}

/// The decisions of the launch check, kept free of side effects.
enum LaunchCheckPolicy {
    static let trustedSeconds: Double = 60 * 60
    static let failureBackoffSeconds: Double = 15 * 60

    enum Action: Equatable {
        case useCache
        case ask(etag: String?)
    }

    static func mode(includePrereleases: Bool) -> String {
        includePrereleases ? "prerelease" : "stable"
    }

    static func action(cache: LaunchCheckCache?, mode: String, now: Date, force: Bool) -> Action {
        guard let cache = cache, cache.mode == mode else { return .ask(etag: nil) }
        if force { return .ask(etag: cache.etag) }
        let seconds = now.timeIntervalSince1970
        if cache.checkedAt > 0, seconds >= cache.checkedAt, seconds - cache.checkedAt < trustedSeconds { return .useCache }
        if let failed = cache.failedAt, failed >= cache.checkedAt, seconds >= failed, seconds - failed < failureBackoffSeconds {
            return .useCache
        }
        return .ask(etag: cache.etag)
    }

    /// How many components have a newer version in `versions` than the installed one.
    static func updateCount(versions: [String: String], installed: [UpdateComponent: InstalledVersion]) -> Int {
        var count = 0
        for component in UpdateComponent.allCases {
            guard let available = versions[component.packageID] else { continue }
            let status = UpdateReportBuilder.status(installed: installed[component] ?? .unknown, available: available)
            if status == .updateAvailable { count += 1 }
        }
        return count
    }
}

@MainActor
final class LaunchUpdateCheck: ObservableObject {
    static let shared = LaunchUpdateCheck()

    /// Components with an update, for the badge. 0 while the check is off, has not run, or knows nothing.
    @Published private(set) var updateCount = 0
    @Published private(set) var lastChecked: Date?
    /// What the last run did, in plain words (shown in About while the check is on), so the cache and the ETag can be seen working.
    @Published private(set) var lastOutcome: String?

    private let settings = UpdateSettings.shared
    private let client = GitHubReleaseClient()
    private var startedThisLaunch = false
    private var running = false

    private init() {}

    /// Called when Tellus opens; it runs once per launch, in the background, and does nothing while the setting is off.
    func runAtLaunch() {
        guard !startedThisLaunch else { return }
        startedThisLaunch = true
        // Not tied to the screen: leaving the main list must not cancel it.
        Task { await self.run(force: false) }
    }

    /// The switch in About was turned on or off.
    func settingChanged() {
        if settings.checkOnLaunch {
            Task { await self.run(force: true) }
        } else {
            updateCount = 0
            lastOutcome = nil
        }
    }

    /// The Check for Updates screen has just looked at GitHub and the installed versions: its numbers are newer than ours.
    func updateFromScreen(count: Int) {
        guard settings.checkOnLaunch else { return }
        updateCount = count
    }

    private func run(force: Bool) async {
        guard settings.checkOnLaunch else {
            updateCount = 0
            return
        }
        guard !running else { return }
        running = true
        defer { running = false }

        let includePrereleases = settings.includePrereleases
        let mode = LaunchCheckPolicy.mode(includePrereleases: includePrereleases)
        let now = Date()
        var cache = settings.loadLaunchCache()

        switch LaunchCheckPolicy.action(cache: cache, mode: mode, now: now, force: force) {
        case .useCache:
            lastOutcome = "Used the saved answer"
        case .ask(let etag):
            do {
                let answer = try await client.fetchLatestReleaseConditional(includePrereleases: includePrereleases, etag: etag)
                switch answer {
                case .notModified:
                    cache?.checkedAt = now.timeIntervalSince1970
                    cache?.failedAt = nil
                    lastOutcome = "Nothing new (not modified)"
                case .release(let release, let newETag):
                    var versions: [String: String] = [:]
                    for (component, package) in release.availablePackages() {
                        versions[component.packageID] = package.version
                    }
                    cache = LaunchCheckCache(mode: mode, etag: newETag, checkedAt: now.timeIntervalSince1970,
                                             failedAt: nil, tag: release.tagName, versions: versions)
                    lastOutcome = "New answer from GitHub"
                }
            } catch is CancellationError {
                return
            } catch {
                // Offline, rate limited or an odd answer: remember when, keep what was known, and stay quiet.
                var failed = cache ?? LaunchCheckCache(mode: mode, etag: nil, checkedAt: 0, failedAt: nil, tag: "", versions: [:])
                if failed.mode != mode {
                    failed = LaunchCheckCache(mode: mode, etag: nil, checkedAt: 0, failedAt: nil, tag: "", versions: [:])
                }
                failed.failedAt = now.timeIntervalSince1970
                cache = failed
                lastOutcome = "Could not reach GitHub; it will try again later"
            }
            settings.saveLaunchCache(cache)
        }

        guard let known = cache, !known.versions.isEmpty else {
            updateCount = 0
            return
        }
        let installed = await InstalledVersionReader.collect()
        updateCount = LaunchCheckPolicy.updateCount(versions: known.versions, installed: installed)
        lastChecked = known.checkedAt > 0 ? Date(timeIntervalSince1970: known.checkedAt) : nil
    }
}
