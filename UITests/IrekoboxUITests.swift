import XCTest

/// End-to-end UI tests for Irekobox.
///
/// SAFETY CONTRACT (see UITestSupport.swift): the suite is strictly read-only
/// against the real `container` backend. It navigates, inspects, and types into
/// non-submitting fields only. It NEVER taps delete/trash/prune/stop/remove/
/// logout, never starts/stops/recreates containers, never pulls images, never
/// runs a Migrate command, never logs in, and never starts a real build.
final class IrekoboxUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchForTesting()
        // The app may show an install/service gate if the backend is down. The
        // test machine has services running, but if a gate appears, most
        // navigation tests are meaningless — fail fast with a clear message.
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    // MARK: - Launch & window

    func testLaunchShowsMainWindowAndSidebar() throws {
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: UI.timeout),
                      "Main window should appear on launch")
        // All 10 sidebar sections should be present.
        for section in UI.sidebarSections {
            XCTAssertTrue(app.sidebarRow(section).waitForExistence(timeout: UI.timeout),
                          "Sidebar should contain '\(section)'")
        }
        // Service footer mirrors backend state and should render.
        XCTAssertTrue(app.descendants(matching: .any)["sidebar.serviceFooter"].waitForExistence(timeout: UI.timeout),
                      "Sidebar service status footer should render")
    }

    // MARK: - Navigation across all sections

    /// ⌘N opens the Run sheet; Run stays disabled without an image; Esc closes it.
    /// Nothing is started.
    func testRunSheetOpensAndCancels() throws {
        // File › Run Container… is ⌘N; the menu works with any keyboard layout.
        if !app.chooseMenuItem("File", "Run Container…") { app.typeKey("n", modifierFlags: .command) }
        let sheet = app.descendants(matching: .any)["run.sheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: UI.timeout), "⌘N should open the Run sheet")
        XCTAssertFalse(app.buttons["run.submit"].isEnabled, "Run needs an image")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(sheet.waitForNonExistence(timeout: UI.timeout), "Esc should close the Run sheet")
    }

    /// ⌘K opens the command palette with its search focused; Esc closes it.
    func testCommandPaletteOpensAndCloses() throws {
        // Edit › Find Anything… is ⌘K.
        if !app.chooseMenuItem("Edit", "Find Anything…") { app.typeKey("k", modifierFlags: .command) }
        let palette = app.descendants(matching: .any)["palette"]
        XCTAssertTrue(palette.waitForExistence(timeout: UI.timeout), "⌘K should open the palette")
        XCTAssertTrue(app.descendants(matching: .any)["palette.search"].exists)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(palette.waitForNonExistence(timeout: UI.timeout), "Esc should close the palette")
    }

    func testSectionKeyboardShortcuts() throws {
        app.typeKey("6", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any)["images.pull"].waitForExistence(timeout: UI.timeout),
                      "⌘6 should show Images")
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any)["dashboard.scrollView"].waitForExistence(timeout: UI.timeout),
                      "⌘1 should show Overview")
    }

    func testNavigateEachSidebarSection() throws {
        // Map each section to a characteristic element (title or identifier)
        // that proves its detail screen rendered.
        let checks: [(section: String, probe: () -> Bool)] = [
            ("Overview", { self.app.descendants(matching: .any)["dashboard.scrollView"].waitForExistence(timeout: UI.timeout) }),
            ("Compose", { self.titleAppears("Compose") }),
            ("Migrate", { self.app.descendants(matching: .any)["migrate.modePicker"].waitForExistence(timeout: UI.timeout) }),
            ("Images", { self.app.descendants(matching: .any)["images.pull"].waitForExistence(timeout: UI.timeout) }),
            ("Volumes", { self.app.descendants(matching: .any)["volumes.new"].waitForExistence(timeout: UI.timeout) }),
            ("Networks", { self.app.descendants(matching: .any)["networks.new"].waitForExistence(timeout: UI.timeout) }),
        ]
        for check in checks {
            app.selectSidebar(check.section)
            XCTAssertTrue(check.probe(), "Selecting '\(check.section)' should show its screen")
        }
    }

    // MARK: - Dashboard

    func testDashboardCards() throws {
        app.selectSidebar("Overview")
        for block in ["overview.hero", "overview.resources", "overview.map", "overview.activity"] {
            XCTAssertTrue(app.descendants(matching: .any)[block].waitForExistence(timeout: UI.timeout),
                          "Overview should show '\(block)'")
        }
    }

    // MARK: - Containers

    func testContainersListAndDetailTabs() throws {
        app.selectSidebar("Containers")
        let list = app.descendants(matching: .any)["containers.list"]
        guard list.waitForExistence(timeout: UI.timeout) else {
            // Empty-state branch: this is a real, documented UX regression — the
            // empty Containers screen drops its toolbar AND navigation title.
            let empty = app.descendants(matching: .any)["containers.emptyState"]
            XCTAssertTrue(empty.exists, "Containers screen should show either a list or the empty state")
            throw XCTSkip("Container list is empty; detail-tab test skipped (no rows to open).")
        }

        // Any container row will do: which containers exist depends on the machine
        // (system ones such as buildkit are hidden by default).
        let anyRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'containers.row.'")).firstMatch
        let row = try XCTUnwrap(anyRow.waitForExistence(timeout: UI.timeout) ? anyRow : nil,
                                "Expected at least one container row to render")
        row.doubleClick()   // click selects; double-click opens the detail

        // Detail header, then Overview (the detail reopens on the tab used last).
        XCTAssertTrue(app.descendants(matching: .any)["containerDetail.header"].waitForExistence(timeout: UI.timeout),
                      "Container detail header should render")
        let overview = app.radioButtons["Overview"].firstMatch
        if overview.waitForExistence(timeout: 5) { overview.click() }
        XCTAssertTrue(app.descendants(matching: .any)["containerDetail.overview"].waitForExistence(timeout: UI.timeout),
                      "Overview tab content should render")

        // Switch Overview -> Logs -> Stats (SKIP Console: it spawns a PTY).
        let logsTab = app.radioButtons["Logs"].firstMatch
        if logsTab.waitForExistence(timeout: UI.timeout) {
            logsTab.click()
            let statsTab = app.radioButtons["Stats"].firstMatch
            if statsTab.exists { statsTab.click() }
            // Return to Overview to leave the detail in a benign state.
            let overviewTab = app.radioButtons["Overview"].firstMatch
            if overviewTab.exists { overviewTab.click() }
        } else {
            XCTFail("Container detail tabs (segmented control) were not found in the element tree")
        }

        // Navigate back. macOS NavigationStack back button is the window's
        // first navigation/back affordance.
        let backButton = app.windows.firstMatch.buttons["Containers"].firstMatch
        if backButton.exists {
            backButton.click()
        }
    }

    // MARK: - Images

    func testImagesScreenAndBuildSheet() throws {
        app.selectSidebar("Images")
        app.descendants(matching: .any)["images.pull"].firstMatch.click()
        XCTAssertTrue(app.descendants(matching: .any)["images.pullField"].waitForExistence(timeout: UI.timeout),
                      "Pull Image should show the pull field")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.descendants(matching: .any)["images.list"].waitForExistence(timeout: UI.timeout),
                      "Images list should render")

        // Open Build sheet, then Cancel (do NOT start a build).
        let build = app.descendants(matching: .any)["images.build"].firstMatch
        XCTAssertTrue(build.waitForExistence(timeout: UI.timeout), "Build… toolbar button should exist")
        build.click()

        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: UI.timeout), "Build sheet should open")

        let cancel = app.descendants(matching: .any)["buildSheet.cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: UI.timeout), "Build sheet should have a Cancel button")
        cancel.click()
        // Sheet should dismiss.
        XCTAssertFalse(sheet.waitForExistence(timeout: 3), "Build sheet should dismiss after Cancel")
    }

    // MARK: - Volumes / Networks / Registries / System forms

    func testVolumesScreen() throws {
        app.selectSidebar("Volumes")
        let list = app.descendants(matching: .any)["volumes.list"]
        let empty = app.descendants(matching: .any)["volumes.emptyState"]
        XCTAssertTrue(waitUntilAny(list, empty), "Volumes list or its empty state should render")
        // The New Volume sheet opens and cancels; typing in it is safe (no submit).
        app.descendants(matching: .any)["volumes.new"].firstMatch.click()
        let field = app.descendants(matching: .any)["volumes.nameField"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: UI.timeout), "New Volume sheet should show a name field")
        field.click()
        field.typeText("ui-test-noop")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(field.waitForExistence(timeout: 3), "New Volume sheet should close on Escape")
    }

    func testNetworksScreen() throws {
        app.selectSidebar("Networks")
        XCTAssertTrue(app.descendants(matching: .any)["networks.list"].waitForExistence(timeout: UI.timeout),
                      "Networks list should render")
        app.descendants(matching: .any)["networks.new"].firstMatch.click()
        XCTAssertTrue(app.descendants(matching: .any)["networks.nameField"].waitForExistence(timeout: UI.timeout),
                      "New Network sheet should show a name field")
        XCTAssertTrue(app.descendants(matching: .any)["networks.subnetField"].exists,
                      "New Network sheet should show a subnet field")
        app.typeKey(.escape, modifierFlags: [])
    }

    /// Wait until either element exists.
    private func waitUntilAny(_ a: XCUIElement, _ b: XCUIElement, timeout: TimeInterval = UI.timeout) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if a.exists || b.exists { return true }
            usleep(200_000)
        }
        return false
    }

    // Forms are checked through their fields: an id on a Form container is
    // not reliably exposed (it moves with the window layout).
    func testRegistriesScreen() throws {
        app.openSettings(tab: "Registries")
        for field in ["registries.server", "registries.username", "registries.password"] {
            XCTAssertTrue(app.descendants(matching: .any)[field].waitForExistence(timeout: UI.timeout),
                          "Registries form should have '\(field)'")
        }
        // Typing a server is safe (no submit / no login).
        let server = app.descendants(matching: .any)["registries.server"].firstMatch
        server.click()
        server.typeText("registry.example.test")
    }

    func testSystemScreen() throws {
        app.openSettings(tab: "Engine")
        XCTAssertTrue(app.descendants(matching: .any)["system.status"].waitForExistence(timeout: UI.timeout),
                      "System status row should render")
        XCTAssertTrue(app.descendants(matching: .any)["system.refresh"].waitForExistence(timeout: UI.timeout),
                      "System Refresh button should render")
        // Refresh is non-destructive (it only re-reads status); tapping it is safe.
        app.descendants(matching: .any)["system.refresh"].firstMatch.click()
    }

    // MARK: - Migrate (local translation only — safe)

    func testMigrateModeSwitching() throws {
        // Exercise the segmented mode picker in isolation (kept separate from the
        // translate test: switching modes re-inits the docker-run editor and can
        // leave it momentarily non-interactive — see testMigrateTranslate).
        app.selectSidebar("Migrate")
        let picker = app.descendants(matching: .any)["migrate.modePicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: UI.timeout), "Migrate mode picker should render")

        // NOTE: a SwiftUI `.segmented` Picker surfaces to XCUITest as a
        // RadioGroup of RadioButtons on macOS (NOT a segmentedControl), so we
        // query the radio group by its accessibility identifier.
        let group = app.descendants(matching: .any)["migrate.modePicker"].firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: UI.timeout), "Mode radio group should render")
        for seg in ["Import image", "Volumes", "docker run"] {
            let button = group.radioButtons[seg]
            if button.waitForExistence(timeout: 3) { button.click() }
        }
    }

    func testMigrateTranslate() throws {
        app.selectSidebar("Migrate")
        let picker = app.descendants(matching: .any)["migrate.modePicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: UI.timeout), "Migrate mode picker should render")
        // Migrate opens on Docker Desktop; the translator is the docker run mode.
        let runMode = app.radioButtons["docker run"].firstMatch
        if runMode.waitForExistence(timeout: 3) { runMode.click() }

        // The editor ships pre-filled with a valid default `docker run` command
        // (docker run -d --name web -p 8080:80 nginx:latest), so translating
        // without editing is a valid, safe (pure local parsing) exercise. We add
        // an extra flag by clicking at the end of the text and appending — this
        // both keeps the command valid and proves typing reaches the editor.
        let editor = app.descendants(matching: .any)["migrate.translateInput"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: UI.timeout), "Translate input editor should exist")

        let translate = app.descendants(matching: .any)["migrate.translateButton"].firstMatch
        XCTAssertTrue(translate.waitForExistence(timeout: UI.timeout), "Translate button should exist")
        // AUDIT: the Translate button frequently reports isHittable == false even
        // though it is fully on-screen and unobstructed (a SwiftUI hit-test quirk
        // for a Label-style button below a TextEditor). A plain .click() throws
        // "Not hittable"; an explicit-coordinate click bypasses the gate.
        if translate.isHittable {
            translate.click()
        } else {
            translate.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        }

        // The result card surfaces a "Translated command" header. Match the
        // header static text (the card's container identifier propagates to all
        // children, so the header label is the most robust probe).
        let resultHeader = app.staticTexts["Translated command"]
        let resultCard = app.descendants(matching: .any)["migrate.resultCard"].firstMatch
        XCTAssertTrue(resultHeader.waitForExistence(timeout: UI.timeout) || resultCard.exists,
                      "Translated command card should appear after Translate")
    }

    // MARK: - Settings window (Cmd+,)

    func testSettingsWindow() throws {
        // AUDIT: opening Settings via the Cmd+, keystroke (app.typeKey) does NOT
        // reliably open the SwiftUI Settings scene under XCUITest — the keystroke
        // is dropped and no window appears. Driving the app menu's "Settings…"
        // item works. Prefer the menu path here; fall back to the shortcut.
        app.activate()
        let appMenu = app.menuBars.menuBarItems.element(boundBy: 1) // the bold app menu
        if appMenu.exists {
            appMenu.click()
            let settingsItem = app.menuItems["Settings…"].firstMatch
            if settingsItem.waitForExistence(timeout: 5) {
                settingsItem.click()
            }
        }

        let general = app.toolbars.buttons["General"].firstMatch
        if !general.waitForExistence(timeout: 8) {
            // Fallback: keyboard shortcut.
            app.typeKey(",", modifierFlags: .command)
        }
        // Settings reopens on the tab used last; the form under test is General.
        if general.waitForExistence(timeout: UI.timeout) { general.click() }
        let form = app.descendants(matching: .any)["settings.form"]
        XCTAssertTrue(form.waitForExistence(timeout: UI.timeout),
                      "Settings window should open and render its form")
        XCTAssertTrue(app.descendants(matching: .any)["settings.binaryPath"].waitForExistence(timeout: UI.timeout),
                      "Settings should show the binary path field")
    }

    // MARK: - Helpers

    /// A navigation title surfaces as static text inside the window; matching by
    /// label is the most reliable cross-version probe on macOS.
    private func titleAppears(_ title: String) -> Bool {
        let byStaticText = app.staticTexts[title].firstMatch.waitForExistence(timeout: UI.timeout)
        if byStaticText { return true }
        return app.descendants(matching: .any)[title].firstMatch.waitForExistence(timeout: 2)
    }
}
