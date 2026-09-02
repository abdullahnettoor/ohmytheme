import Foundation

/// The user defaults entries that decide whether an AppKit status item is shown.
///
/// AppKit writes these when a user removes a menu-bar item by holding Command and
/// dragging it out of the menu bar.
protocol MenuBarVisibilityDefaults: AnyObject {
    func persistedKeys() -> [String]
    func removeObject(forKey defaultName: String)
}

extension UserDefaults: MenuBarVisibilityDefaults {
    func persistedKeys() -> [String] {
        Array(dictionaryRepresentation().keys)
    }
}

/// Keeps Oh My Theme reachable from the menu bar across ordinary relaunches.
enum MenuBarPresence {
    /// The prefix AppKit uses for per-status-item visibility preferences.
    static let visibilityKeyPrefix = "NSStatusItem Visible"

    /// Removes remembered "this status item is hidden" preferences so that relaunching
    /// the app restores its menu-bar item after the user removed it.
    ///
    /// - Returns: the keys that were removed, so the behavior is observable in tests.
    @discardableResult
    static func clearHiddenStatusItemPreferences(in defaults: MenuBarVisibilityDefaults) -> [String] {
        let hiddenItemKeys = defaults.persistedKeys().filter { $0.hasPrefix(visibilityKeyPrefix) }
        for key in hiddenItemKeys {
            defaults.removeObject(forKey: key)
        }
        return hiddenItemKeys.sorted()
    }
}
