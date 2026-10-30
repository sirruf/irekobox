import XCTest

/// Shared helpers and constants for the Irekobox UI test suite.
///
/// SAFETY: These tests run against the user's REAL `container` backend. Helpers
/// here are deliberately read-only. Nothing in this file (or the suite) taps a
/// destructive control (delete/trash/prune/stop/remove/logout) or starts/stops
/// containers, pulls images, runs migrations, or logs in anywhere.
enum UI {
    /// The sidebar sections, in display order. Raw values must match
    /// `SidebarSection.rawValue` in AppCore. Registries and the engine (formerly
    /// "System") live in Settings.
    static let sidebarSections = [
        "Overview", "Containers", "Compose", "Images", "Volumes", "Networks",
        "Migrate",
    ]

    /// Generous default for first-paint / async list loads.
    static let timeout: TimeInterval = 20
}

extension XCUIApplication {
    /// Launch with a clean, predictable state. Cocoa window/state restoration is
    /// disabled so a relaunch never restores a stale (e.g. previously closed or
    /// off-screen) main window, which would hide the sidebar from XCUITest.
    func launchForTesting() {
        // The suite drives the containers table (cards are the default), unless a test asked otherwise.
        if !launchArguments.contains("-containersLayout") { launchArguments += ["-containersLayout", "table"] }
        launchArguments += ["-ui-testing",
                            "-ApplePersistenceIgnoreState", "YES",
                            "-NSQuitAlwaysKeepsWindows", "NO",
                            // Don't register the background agent (a Login Item)
                            // just because the suite launched the app.
                            "-backgroundAgentEnabled", "NO"]
        launch()
        // Under XCUITest the main window comes from the app's launch fallback
        // about a second in; wait for it so a window opened by the test (e.g.
        // Settings) isn't covered by it right after.
        let main = windows.matching(NSPredicate(format: "identifier BEGINSWITH 'main'")).firstMatch
        _ = main.waitForExistence(timeout: 10)
    }

    /// Open Settings on the given tab ("General", "Engine", "Registries"):
    /// through the app menu's Settings… item, which works with any keyboard
    /// layout (⌘, is a different key on some), falling back to the shortcut.
    func openSettings(tab: String) {
        activate()
        let appMenu = menuBars.menuBarItems.element(boundBy: 1)
        var opened = false
        if appMenu.exists {
            appMenu.click()
            let item = menuItems["Settings…"].firstMatch
            if item.waitForExistence(timeout: 5) {
                item.click()
                opened = true
            }
        }
        if !opened { typeKey(",", modifierFlags: .command) }
        let button = toolbars.buttons[tab].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: UI.timeout), "Settings tab '\(tab)' should exist")
        button.click()
    }

    /// Choose `item` from the menu bar's `menu`, so a test works with any
    /// keyboard layout; returns false when the item wasn't found.
    @discardableResult
    func chooseMenuItem(_ menu: String, _ item: String) -> Bool {
        activate()
        let bar = menuBars.menuBarItems[menu].firstMatch
        guard bar.waitForExistence(timeout: 5) else { return false }
        bar.click()
        let entry = bar.menuItems[item].firstMatch
        guard entry.waitForExistence(timeout: 5) else {
            typeKey(.escape, modifierFlags: [])
            return false
        }
        entry.click()
        return true
    }

    /// Click a sidebar row by its section name.
    func selectSidebar(_ name: String) {
        let row = sidebarRow(name)
        XCTAssertTrue(row.waitForExistence(timeout: UI.timeout),
                      "Sidebar row '\(name)' should exist")
        row.click()
    }

    /// Resolve a sidebar row across the element types XCUITest may expose it as.
    /// On macOS a `List` row Label can surface as a cell, a button, or static text.
    func sidebarRow(_ name: String) -> XCUIElement {
        let byID = descendants(matching: .any)["sidebar.\(name)"].firstMatch
        return byID
    }
}

extension XCUIElement {
    /// Wait, then assert existence with a descriptive message.
    @discardableResult
    func assertAppears(_ message: String, timeout: TimeInterval = UI.timeout) -> Bool {
        let ok = waitForExistence(timeout: timeout)
        XCTAssertTrue(ok, message)
        return ok
    }
}
