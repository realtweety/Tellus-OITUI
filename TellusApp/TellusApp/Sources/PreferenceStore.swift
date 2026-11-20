import Combine
import CoreFoundation
import Foundation

struct PreferenceDomain {
    let identifier: String
    let changedNotification: String

    static let insula = PreferenceDomain(
        identifier: "com.wilburt.oiti.prefs",
        changedNotification: "com.wilburt.oiti/PrefsChanged"
    )

    static let litus = PreferenceDomain(
        identifier: "com.wilburt.oits.prefs",
        changedNotification: "com.wilburt.oits/PrefsChanged"
    )
}

@MainActor
final class PreferenceStore: ObservableObject {
    @Published private(set) var snapshot: [String: Any] = [:]
    @Published private(set) var synchronizationSucceeded = false

    private let domain: PreferenceDomain
    private var sliderLastWrite: [String: TimeInterval] = [:]
    private var pendingSliderWrites: [String: DispatchWorkItem] = [:]
    private var latestSliderValues: [String: Double] = [:]

    init(domain: PreferenceDomain) {
        self.domain = domain
    }

    @discardableResult
    func reload() -> Bool {
        let domainName = domain.identifier as CFString
        synchronizationSucceeded = CFPreferencesAppSynchronize(domainName)

        if let values = CFPreferencesCopyMultiple(
            nil,
            domainName,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) as? [String: Any] {
            snapshot = values
        } else {
            snapshot = [:]
        }

        return synchronizationSucceeded
    }

    func integer(forKey key: String, default defaultValue: Int) -> Int {
        (snapshot[key] as? NSNumber)?.intValue ?? defaultValue
    }

    func bool(forKey key: String, default defaultValue: Bool) -> Bool {
        (snapshot[key] as? NSNumber)?.boolValue ?? defaultValue
    }

    func double(forKey key: String, default defaultValue: Double) -> Double {
        if let value = snapshot[key] as? NSNumber { return value.doubleValue }
        if let value = snapshot[key] as? String, let number = Double(value) { return number }
        return defaultValue
    }

    func string(forKey key: String, default defaultValue: String) -> String {
        if let value = snapshot[key] as? String { return value }
        if let value = snapshot[key] as? NSNumber { return value.stringValue }
        return defaultValue
    }

    /// Writes related values together, synchronizes them, posts the existing
    /// domain notification, and confirms that the values can be read back.
    func write(_ updates: [String: Any]) -> Bool {
        let domainName = domain.identifier as CFString
        for (key, value) in updates {
            CFPreferencesSetAppValue(key as CFString, value as CFPropertyList, domainName)
        }

        let synchronized = CFPreferencesAppSynchronize(domainName)
        synchronizationSucceeded = synchronized
        let reloaded = reload()

        guard synchronized && reloaded else { return false }
        let valuesMatch = updates.allSatisfy { key, expected in
            guard let actual = snapshot[key] as? NSObject,
                  let expected = expected as? NSObject else {
                return false
            }
            return actual.isEqual(expected)
        }
        guard valuesMatch else { return false }

        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(domain.changedNotification as CFString),
            nil,
            nil,
            true
        )
        return true
    }

    /// Matches the Settings sliders: persist a live value at most every 120 ms,
    /// then flush the final value when the user releases the slider.
    func updateSlider(_ value: Double, forKey key: String, finished: Bool = false) {
        latestSliderValues[key] = value

        if finished {
            pendingSliderWrites[key]?.cancel()
            pendingSliderWrites.removeValue(forKey: key)
            commitSliderValue(forKey: key)
            return
        }

        guard pendingSliderWrites[key] == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let delay = max(0, 0.12 - (now - sliderLastWrite[key, default: 0]))
        if delay == 0 {
            commitSliderValue(forKey: key)
            return
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingSliderWrites.removeValue(forKey: key)
            self.commitSliderValue(forKey: key)
        }
        pendingSliderWrites[key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func commitSliderValue(forKey key: String) {
        guard let value = latestSliderValues[key] else { return }
        _ = write([key: NSNumber(value: value)])
        sliderLastWrite[key] = ProcessInfo.processInfo.systemUptime
    }

    func post(_ notification: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(notification as CFString),
            nil,
            nil,
            true
        )
    }
}
