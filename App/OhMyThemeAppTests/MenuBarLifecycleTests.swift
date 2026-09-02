import XCTest

@testable import OhMyTheme

/// Smoke tests for the menu-bar lifecycle behavior the app owns.
final class MenuBarLifecycleTests: XCTestCase {
    func testLaunchClearsRememberedHiddenMenuBarItemPreferences() {
        let defaults = RecordingMenuBarVisibilityDefaults(
            keys: [
                "NSStatusItem Visible OhMyThemeItem-0",
                "NSStatusItem Preferred Position OhMyThemeItem-0",
                "OhMyThemeLaunchAtLogin",
            ]
        )

        let clearedKeys = MenuBarPresence.clearHiddenStatusItemPreferences(in: defaults)

        XCTAssertEqual(clearedKeys, ["NSStatusItem Visible OhMyThemeItem-0"])
        XCTAssertEqual(defaults.removedKeys, ["NSStatusItem Visible OhMyThemeItem-0"])
    }

    func testLaunchLeavesUnrelatedPreferencesAlone() {
        let defaults = RecordingMenuBarVisibilityDefaults(keys: ["OhMyThemeLaunchAtLogin"])

        let clearedKeys = MenuBarPresence.clearHiddenStatusItemPreferences(in: defaults)

        XCTAssertTrue(clearedKeys.isEmpty)
        XCTAssertTrue(defaults.removedKeys.isEmpty)
    }
}

private final class RecordingMenuBarVisibilityDefaults: MenuBarVisibilityDefaults {
    private let keys: [String]
    private(set) var removedKeys: [String] = []

    init(keys: [String]) {
        self.keys = keys
    }

    func persistedKeys() -> [String] {
        keys
    }

    func removeObject(forKey defaultName: String) {
        removedKeys.append(defaultName)
    }
}
