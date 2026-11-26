import Combine
import Foundation

// Tellus's own settings for the update screen and the check at launch. They are stored with CFPreferences in a Tellus domain, so
// they live in /var/mobile/Library/Preferences, outside the app bundle: installing or updating Tellus does not reset them. (Insula's
// settings use the same mechanism, which is known to work for this app.)

extension PreferenceDomain {
    static let tellus = PreferenceDomain(
        identifier: "com.wilburt.tellus.prefs",
        changedNotification: "com.wilburt.tellus/PrefsChanged"
    )
}

@MainActor
final class UpdateSettings: ObservableObject {
    static let shared = UpdateSettings()

    private enum Key {
        static let includePrereleases = "updates.includePrereleases"
        static let allowReinstall = "updates.allowReinstall"
        static let checkOnLaunch = "updates.checkOnLaunch"
        static let launchCheckCache = "updates.launchCheckCache"
    }

    private let store = PreferenceStore(domain: .tellus)
    private var isLoading = true

    /// Pre-releases are for testing a release candidate before it is published for everyone. Off until the owner switches it on;
    /// it then stays on.
    @Published var includePrereleases = false {
        didSet { save(Key.includePrereleases, includePrereleases) }
    }

    /// Also offer reinstalling the version that is already installed (Tellus never downgrades). It stays on once switched on;
    /// every install still asks for confirmation.
    @Published var allowReinstall = false {
        didSet { save(Key.allowReinstall, allowReinstall) }
    }

    /// Off by default: check for updates when Tellus opens and show a badge on About.
    @Published var checkOnLaunch = false {
        didSet { save(Key.checkOnLaunch, checkOnLaunch) }
    }

    private init() {
        _ = store.reload()
        includePrereleases = store.bool(forKey: Key.includePrereleases, default: false)
        allowReinstall = store.bool(forKey: Key.allowReinstall, default: false)
        checkOnLaunch = store.bool(forKey: Key.checkOnLaunch, default: false)
        isLoading = false
    }

    private func save(_ key: String, _ value: Bool) {
        guard !isLoading else { return }
        _ = store.write([key: NSNumber(value: value)])
    }

    // MARK: Launch check cache

    func loadLaunchCache() -> LaunchCheckCache? {
        _ = store.reload()
        guard let text = store.snapshot[Key.launchCheckCache] as? String, !text.isEmpty,
              let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(LaunchCheckCache.self, from: data)
    }

    func saveLaunchCache(_ cache: LaunchCheckCache?) {
        var text = ""
        if let cache = cache, let data = try? JSONEncoder().encode(cache), let encoded = String(data: data, encoding: .utf8) {
            text = encoded
        }
        _ = store.write([Key.launchCheckCache: text])
    }
}
