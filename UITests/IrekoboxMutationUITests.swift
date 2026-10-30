import XCTest

/// MUTATION / LIFECYCLE UI tests for Irekobox.
///
/// SAFETY: This suite is permitted to MUTATE state — but only DISPOSABLE
/// fixtures prefixed `ib-uitest-`. It never touches the pre-existing containers
/// (postgres_pgvector, redis), never deletes the `buildkit` builder shim, never
/// touches registries, never pushes/pulls beyond the already-local `alpine`
/// image, and never prunes.
///
/// ── WHY FIXTURES ARE CREATED OUT-OF-PROCESS ──────────────────────────────────
/// The XCUITest runner (IrekoboxUITests-Runner.app) is SANDBOXED by the
/// XCTest template; its only mach-lookup exceptions are test-infra services. So
/// any `container …` spawned FROM INSIDE the test process fails with
///   Error: interrupted: "XPC connection error: Connection invalid"
/// i.e. the runner cannot reach the `container-apiserver`. The app under test is
/// NOT sandboxed, so driving its UI (which performs the CLI calls) works fine.
///
/// Therefore container fixtures — which have no in-app "create" affordance
/// without an image-run flow — are created/destroyed by `scripts/run-mutation-
/// uitests.sh` AROUND this suite, and verification happens THROUGH THE UI
/// (badges, row presence) rather than by re-querying the CLI. Volume/network
/// create+delete and the duplicate-volume error toast ARE driven through the UI
/// (the app makes those calls), so they self-seed.
///
/// ── PICKER SAFETY ────────────────────────────────────────────────────────────
/// An open NSOpenPanel HANGS the runner in an infinite relaunch loop on this
/// machine, so this suite triggers NO file/folder picker: it never clicks
/// Projects → "Add Project" or Images → Build → "Choose…". (Stacks import is covered
/// headlessly in Tests/AppCoreTests/StackImportTests.swift.)
///
/// Several tests double as AUDIT EVIDENCE: they PASS by proving an UNSAFE
/// behavior (e.g. delete-without-confirmation). Those assertions are flagged
/// INVERT-ON-FIX so they fail loudly once the gap is closed.
final class IrekoboxMutationUITests: XCTestCase {
    var app: XCUIApplication!

    // Container fixtures (pre-created out-of-process by the wrapper script).
    let cWeb = "ib-uitest-web"      // starts STOPPED  — lifecycle-from-list
    let cDel = "ib-uitest-del"      // starts RUNNING  — delete-without-confirm
    let cDetail = "ib-uitest-det"   // starts STOPPED  — detail-view lifecycle
    let cEdit = "ib-uitest-edit"    // starts RUNNING  — edit sheet

    // UI-created disposables (no pre-seeding needed — the app creates them).
    let volName = "ib-uitest-vol"
    let netName = "ib-uitest-net"
    let dupVol  = "ib-uitest-dup"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // Disable Cocoa window/state restoration so a relaunch never restores a
        // modal panel that would block event synthesis for the whole suite.
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES",
                                "-NSQuitAlwaysKeepsWindows", "NO"]
        app.launchForTesting()
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    // MARK: - Shared navigation / polling helpers

    private func openContainers() {
        app.selectSidebar("Containers")
        let list = app.descendants(matching: .any)["containers.list"]
        XCTAssertTrue(list.waitForExistence(timeout: UI.timeout),
                      "Containers list should render (fixtures exist)")
    }

    /// The navigable row element (the NavigationLink "info" button). The row id
    /// is on the info link only — the action buttons carry their own
    /// `container.action.*` ids — so this resolves to a single element.
    private func row(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)["containers.row.\(id)"].firstMatch
    }

    /// Backwards-compatible alias used by detail-navigation tests.
    private func rowInfo(_ id: String) -> XCUIElement { row(id) }

    /// Skip cleanly if a required fixture row is missing (e.g. the suite was run
    /// without the wrapper script that seeds container fixtures).
    private func requireRow(_ id: String) throws -> XCUIElement {
        openContainers()
        let r = row(id)
        if !r.waitForExistence(timeout: UI.timeout) {
            throw XCTSkip("Fixture container '\(id)' not present. Run via " +
                          "scripts/run-mutation-uitests.sh, which seeds container " +
                          "fixtures out-of-process (the sandboxed runner can't).")
        }
        return r
    }

    /// Poll a UI predicate until it holds or the timeout elapses.
    @discardableResult
    private func waitUntil(timeout: TimeInterval = UI.timeout,
                           _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            usleep(300_000)
        }
        return predicate()
    }

    /// The state badge text is absorbed into the row INFO button's composite
    /// accessibility label (e.g. "ib-uitest-web, alpine:latest, 4 CPU · 1.07 GB,
    /// Stopped"). So "badge visible" means that label contains the state word.
    /// Fall back to a standalone static text if one ever surfaces.
    private func badgeVisible(_ text: String, in r: XCUIElement) -> Bool {
        if r.exists, r.label.localizedCaseInsensitiveContains(text) { return true }
        return r.staticTexts[text].exists || app.staticTexts[text].exists
    }

    /// Select a detail tab by its label: a segment of the toolbar's
    /// segmented control, surfaced as a radio button ("Overview"/"Logs"/…).
    private func selectDetailTab(_ label: String) {
        let tab = app.radioButtons[label].firstMatch
        if tab.waitForExistence(timeout: 5) { tab.click() }
    }

    // ELEMENT-REACHABILITY NOTE: a container List row was originally a single
    // NavigationLink wrapping its info AND its inline start/stop/delete buttons.
    // SwiftUI on macOS FLATTENS such a NavigationLink into ONE accessibility
    // Button, absorbing the inner buttons so they were unreachable and coordinate
    // clicks merely navigated. ContainersView now renders the NavigationLink
    // (info, carrying the `containers.row.<id>` id) and the action buttons as
    // SIBLINGS in the List row, each keeping its own `container.action.*` id — so
    // both the row link and the buttons are independent, reachable elements.

    /// A row's inline action button, by container id and action.
    /// `action` ∈ {"start","stop","delete"}.
    private func actionButton(_ containerID: String, _ action: String) -> XCUIElement {
        app.descendants(matching: .any)["container.action.\(action).\(containerID)"].firstMatch
    }

    // MARK: - Test 1: Container lifecycle from the list

    func testContainerLifecycleFromList() throws {
        let r = try requireRow(cWeb)

        // Fixture starts STOPPED → the row exposes a reachable Start button.
        let startBtn = actionButton(cWeb, "start")
        XCTAssertTrue(startBtn.waitForExistence(timeout: UI.timeout),
                      "Stopped row should expose a Start button")
        let t0 = Date()
        startBtn.click()

        // Busy spinner while the start is in flight (best-effort; the poll is fast).
        let sawSpinner = waitUntil(timeout: 3) { app.activityIndicators.firstMatch.exists }

        // The Stop button appearing (start→stop swap) confirms the row now reflects
        // Running; also accept the "Running" badge label.
        let stopBtn = actionButton(cWeb, "stop")
        let uiRunning = waitUntil(timeout: 25) { stopBtn.exists || self.badgeVisible("Running", in: r) }
        let runningLatency = Date().timeIntervalSince(t0)
        XCTAssertTrue(uiRunning, "Row should reflect Running (Stop button + badge) after the list refreshes")
        XCTContext.runActivity(named: "Start latency / feedback") { a in
            a.add(XCTAttachment(string:
                "sawBusySpinner=\(sawSpinner) running-latency=\(String(format: "%.1fs", runningLatency))"))
        }

        // Stop from the list.
        XCTAssertTrue(stopBtn.waitForExistence(timeout: UI.timeout), "Running row should expose a Stop button")
        let t1 = Date()
        stopBtn.click()
        let uiStopped = waitUntil(timeout: 25) { self.actionButton(self.cWeb, "start").exists
            || self.badgeVisible("Stopped", in: r) }
        let stopLatency = Date().timeIntervalSince(t1)
        XCTAssertTrue(uiStopped, "Row should return to Stopped after the list refreshes")
        XCTContext.runActivity(named: "Stop latency") { a in
            a.add(XCTAttachment(string: "stopped-latency=\(String(format: "%.1fs", stopLatency))"))
        }
    }

    // MARK: - Test 2: Delete requires confirmation (regression guard)

    /// Destructive delete now goes through a confirmation dialog. This asserts
    /// the dialog appears (and that cancelling does NOT delete, then confirming
    /// does) — the inverse of the original audit finding, now that it's fixed.
    func testDeleteFromListRequiresConfirmation() throws {
        let r = try requireRow(cDel)

        let trash = actionButton(cDel, "delete")
        XCTAssertTrue(trash.waitForExistence(timeout: UI.timeout), "Row should expose a delete (trash) button")
        trash.click()

        // A confirmation must appear before anything is deleted. (The row trash's
        // own a11y label is "Delete container …", so a bare "Delete" button is
        // unambiguously the dialog's confirm button.)
        XCTAssertTrue(confirmationVisible("Cancel"),
                      "A confirmation must appear before a destructive delete")

        // Cancelling leaves the row intact.
        confirmationButton("Cancel").click()
        XCTAssertTrue(r.exists, "Row should survive a cancelled delete")

        // Confirming deletes it.
        trash.click()
        XCTAssertTrue(confirmDelete(), "Confirm dialog should expose a Delete button")
        XCTAssertTrue(waitUntil(timeout: 25) { !r.exists },
                      "Row should disappear after a confirmed delete + reload")
    }

    // MARK: - Test 3: Detail view lifecycle (Start, Stats, Logs, Stop)

    /// The detail-header Start/Stop button: matches the label but is NOT one of
    /// the list row's action buttons (which carry a `containers.row.*` id).
    private func headerButton(_ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(
            format: "label == %@ AND NOT (identifier BEGINSWITH 'containers.row.')", label)).firstMatch
    }

    func testDetailViewLifecycle() throws {
        _ = try requireRow(cDetail)   // starts STOPPED; ensures the row is present
        rowInfo(cDetail).doubleClick()   // click selects; double-click opens the detail

        XCTAssertTrue(app.descendants(matching: .any)["containerDetail.more"].waitForExistence(timeout: UI.timeout),
                      "Detail header should render (More menu present)")

        // Start from the header (borderedProminent "Start"; no a11y id → by label,
        // disambiguated from row Start buttons).
        let startLabel = headerButton("Start")
        XCTAssertTrue(startLabel.waitForExistence(timeout: UI.timeout),
                      "Header Start button should render for a stopped container")
        startLabel.click()

        // Header should reflect Running (header refresh() runs post-start). The
        // Overview tab shows a "State: Running" InfoRow; accept either signal.
        let headerRunning = waitUntil(timeout: 25) {
            app.descendants(matching: .any)["containerDetail.header"].staticTexts["Running"].exists
                || app.staticTexts["Running"].exists
                || self.headerButton("Stop").exists   // Start→Stop swap confirms running
        }
        XCTAssertTrue(headerRunning, "Detail header should reflect Running after Start")

        // Stats tab: the CPU and memory charts appear once two samples exist
        // (rates need a previous sample, about two seconds).
        XCTAssertTrue(app.tabGroups.firstMatch.waitForExistence(timeout: UI.timeout),
                      "Detail tab bar should render")
        selectDetailTab("Stats")
        let cpuChart = app.descendants(matching: .any)["stats.chart.cpu"].firstMatch
        let memoryChart = app.descendants(matching: .any)["stats.chart.memory"].firstMatch
        let chartsOK = waitUntil(timeout: 15) { cpuChart.exists && memoryChart.exists }
        XCTAssertTrue(chartsOK, "Stats tab should render CPU and memory charts for a running container")

        // Logs tab: log lines or the "No Output Yet" empty state (alpine sleep
        // produces no output → empty state expected, but accept either).
        selectDetailTab("Logs")
        let emptyLogs = app.staticTexts["No Output Yet"]
        let logsOK = waitUntil(timeout: 10) { emptyLogs.exists || app.scrollViews.firstMatch.exists }
        XCTAssertTrue(logsOK, "Logs tab should show log lines or the 'No output yet' empty state")

        // SKIP the Console tab (PTY).

        // Stop from the header (return to Overview so the buttons are unobstructed).
        selectDetailTab("Overview")
        let stopLabel = headerButton("Stop")
        XCTAssertTrue(stopLabel.waitForExistence(timeout: UI.timeout),
                      "Header Stop button should render for a running container")
        stopLabel.click()
        let headerStopped = waitUntil(timeout: 25) {
            app.descendants(matching: .any)["containerDetail.header"].staticTexts["Stopped"].exists
                || app.staticTexts["Stopped"].exists
                || self.headerButton("Start").exists
        }
        XCTAssertTrue(headerStopped, "Detail header should reflect Stopped after Stop")
    }

    // MARK: - Test 4: Edit sheet (sections, validation, Esc probe, cancel)

    func testEditSheetSectionsValidationAndCancel() throws {
        _ = try requireRow(cEdit)   // starts RUNNING; ensures the row is present
        rowInfo(cEdit).doubleClick()   // click selects; double-click opens the detail

        // The Edit button now keeps its own id (the header uses
        // .accessibilityElement(children: .contain) so child ids are preserved).
        app.descendants(matching: .any)["containerDetail.more"].firstMatch.click()
        let edit = app.descendants(matching: .any)["containerDetail.edit"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: UI.timeout), "Edit… should be in the More menu")
        edit.click()

        // Sheet sections render with prefilled rows.
        for header in ["Networks", "Ports", "Volumes", "Environment"] {
            XCTAssertTrue(app.staticTexts[header].waitForExistence(timeout: UI.timeout),
                          "Edit sheet should show the '\(header)' section")
        }

        // Recreate (borderedProminent) is enabled while the model is valid.
        let recreate = app.descendants(matching: .any)["editSheet.recreate"].firstMatch
        XCTAssertTrue(recreate.waitForExistence(timeout: UI.timeout), "Recreate button should render")
        XCTAssertTrue(recreate.isEnabled, "Recreate should be enabled with valid prefilled rows")

        // Add a valid env row KEY=value. The container has a prefilled PATH row,
        // so the NEW empty row is the LAST editSheet.env.key/value, not the first.
        let envKeysBefore = app.descendants(matching: .any).matching(identifier: "editSheet.env.key").count
        let addVar = app.descendants(matching: .any)["editSheet.env.add"].firstMatch
        XCTAssertTrue(addVar.waitForExistence(timeout: UI.timeout), "Add variable button should exist")
        addVar.click()
        _ = waitUntil(timeout: 5) {
            app.descendants(matching: .any).matching(identifier: "editSheet.env.key").count > envKeysBefore
        }
        let keys = app.descendants(matching: .any).matching(identifier: "editSheet.env.key")
        let vals = app.descendants(matching: .any).matching(identifier: "editSheet.env.value")
        let keyField = keys.element(boundBy: max(0, keys.count - 1))
        if keyField.waitForExistence(timeout: 5) { keyField.click(); keyField.typeText("IB_UITEST") }
        let valField = vals.element(boundBy: max(0, vals.count - 1))
        if valField.waitForExistence(timeout: 5) { valField.click(); valField.typeText("1") }
        XCTAssertTrue(recreate.isEnabled, "Recreate should remain enabled after a valid env row")

        // Invalid input: a port with host "99999" (out of range) → inline error +
        // Recreate disabled.
        let addPort = app.descendants(matching: .any)["editSheet.port.add"].firstMatch
        XCTAssertTrue(addPort.waitForExistence(timeout: UI.timeout), "Add port button should exist")
        addPort.click()
        let hostField = app.descendants(matching: .any)["editSheet.port.host"].firstMatch
        XCTAssertTrue(hostField.waitForExistence(timeout: 5), "New port host field should appear")
        hostField.click(); hostField.typeText("99999")
        let containerField = app.descendants(matching: .any)["editSheet.port.container"].firstMatch
        if containerField.exists { containerField.click(); containerField.typeText("80") }

        let invalidObserved = waitUntil(timeout: 8) { !recreate.isEnabled }
        XCTAssertTrue(invalidObserved,
                      "Recreate should disable when an invalid port (99999) is entered")
        // The inline field error text should be present near the port row.
        let inlineError = waitUntil(timeout: 5) {
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "port")).firstMatch.exists
                || app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "1–65535")).firstMatch.exists
                || app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "range")).firstMatch.exists
        }
        XCTContext.runActivity(named: "Inline port validation message") { a in
            a.add(XCTAttachment(string: "inlineErrorTextObserved=\(inlineError)"))
        }

        // FIXED: Cancel now carries .keyboardShortcut(.cancelAction), so Esc
        // closes the sheet WITHOUT recreating the container.
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.exists, "Edit sheet should be open before pressing Esc")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(waitUntil(timeout: 3) { !app.sheets.firstMatch.exists },
                      "Esc should dismiss the Edit sheet (no recreate)")

        // Confirm we did NOT recreate: we're back on cEdit's detail (cancel does
        // not navigate), and its header still shows the container — i.e. it still
        // exists and was not torn down by a recreate.
        let stillThere = waitUntil(timeout: UI.timeout) {
            app.descendants(matching: .any)["containerDetail.header"].staticTexts["ib-uitest-edit"].exists
                || app.staticTexts["ib-uitest-edit"].exists
        }
        XCTAssertTrue(stillThere, "Container must still exist (we cancelled, never recreated)")
    }

    /// Focus a name field and type `text`. Clicks the field, lets SwiftUI install
    /// the field editor (a settle — single clicks otherwise race focus and drop
    /// leading keys), clears any prefilled text, then types. Requires the U.S.
    /// keyboard layout (the wrapper script selects it; otherwise letters route
    /// through a non-Latin layout and arrive garbled). `field.value` on these
    /// `.roundedBorder` fields is unreliable, so callers verify success by the
    /// resulting row appearing rather than by reading the value back.
    private func focusAndType(_ field: XCUIElement, _ text: String) {
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).click()
        usleep(700_000)
        field.typeKey("a", modifierFlags: .command)
        field.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        usleep(150_000)
        field.typeText(text)
        usleep(300_000)
    }

    // MARK: - Test 5: Volumes create/delete round-trip (UI-driven, self-seeding)

    func testVolumeCreateDeleteRoundTrip() throws {
        app.selectSidebar("Volumes")
        app.descendants(matching: .any)["volumes.new"].firstMatch.click()
        let field = app.descendants(matching: .any)["volumes.nameField"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: UI.timeout), "Volume name field should exist")
        focusAndType(field, volName)

        let create = app.descendants(matching: .any)["volumes.create"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: UI.timeout), "Create button should exist")
        XCTAssertTrue(create.isEnabled, "Create should enable once a name is typed")
        create.click()

        // The UI list is the source of truth (the runner can't query the CLI).
        let vRow = app.staticTexts[volName]
        XCTAssertTrue(waitUntil(timeout: 15) { vRow.exists },
                      "New volume row should appear after Create")

        // Delete via the row trash button — now guarded by a confirmation dialog.
        clickRowTrash(forName: volName, inList: "volumes.list")
        XCTAssertTrue(confirmDelete(),
                      "Deleting a volume should require confirmation")
        XCTAssertTrue(waitUntil(timeout: 15) { !vRow.exists },
                      "Volume row should disappear after a confirmed delete")
    }

    // MARK: - Test 6: Networks create/delete round-trip (UI-driven, self-seeding)

    func testNetworkCreateDeleteRoundTrip() throws {
        app.selectSidebar("Networks")
        app.descendants(matching: .any)["networks.new"].firstMatch.click()
        let field = app.descendants(matching: .any)["networks.nameField"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: UI.timeout), "Network name field should exist")
        focusAndType(field, netName)

        let create = app.descendants(matching: .any)["networks.create"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: UI.timeout), "Create button should exist")
        XCTAssertTrue(create.isEnabled, "Create should enable once a name is typed")
        create.click()

        let nRow = app.staticTexts[netName]
        XCTAssertTrue(waitUntil(timeout: 20) { nRow.exists },
                      "New network row should appear after Create")

        // The built-in `default` network row must exist and carry a 'built-in'
        // badge (the view hides the trash for built-in networks).
        XCTAssertTrue(app.staticTexts["default"].waitForExistence(timeout: 5),
                      "Built-in 'default' network row should render")
        XCTAssertTrue(app.staticTexts["built-in"].firstMatch.exists,
                      "Built-in network should show a 'built-in' badge (and no delete button)")

        clickRowTrash(forName: netName, inList: "networks.list")
        XCTAssertTrue(confirmDelete(),
                      "Deleting a network should require confirmation")
        XCTAssertTrue(waitUntil(timeout: 15) { !nRow.exists },
                      "Network row should disappear after a confirmed delete")
    }

    // MARK: - Test 7: Error toast auto-dismisses (regression guard)

    func testErrorToastAutoDismisses() throws {
        app.selectSidebar("Volumes")
        let new = app.descendants(matching: .any)["volumes.new"].firstMatch
        XCTAssertTrue(new.waitForExistence(timeout: UI.timeout), "New Volume button should exist")
        new.click()
        let field = app.descendants(matching: .any)["volumes.nameField"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: UI.timeout), "Volume name field should exist")
        let create = app.descendants(matching: .any)["volumes.create"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: UI.timeout))

        // Seed the duplicate THROUGH THE UI (the app reaches the apiserver):
        // create ib-uitest-dup once …
        focusAndType(field, dupVol)
        create.click()
        XCTAssertTrue(waitUntil(timeout: 15) { app.staticTexts[dupVol].exists },
                      "Seed volume should be created via the UI first")

        // … then try to create the SAME name again → duplicate-name backend error.
        new.click()
        XCTAssertTrue(field.waitForExistence(timeout: UI.timeout), "New Volume sheet should open again")
        focusAndType(field, dupVol)
        // Ensure the name committed (Create enabled) before clicking, so the
        // backend actually sees the duplicate name.
        _ = waitUntil(timeout: 5) { create.isEnabled }
        create.click()

        let errorAppeared = waitUntil(timeout: 12) { self.errorBarVisible() }
        XCTAssertTrue(errorAppeared, "A red error toast/bar should appear on duplicate-create")

        // FIXED: the toast now auto-dismisses (~5s lifetime). Assert it is gone
        // within ~8s — the inverse of the original "never dismisses" finding.
        XCTAssertTrue(waitUntil(timeout: 8) { !self.errorBarVisible() },
                      "The error toast should auto-dismiss after a few seconds")
        // The sheet stays open after a failed create: close it.
        app.typeKey(.escape, modifierFlags: [])

        // Clean up the seed volume via the UI so the wrapper has nothing to remove.
        clickRowTrash(forName: dupVol, inList: "volumes.list")
        XCTAssertTrue(confirmDelete(), "Deleting the seed volume should require confirmation")
        _ = waitUntil(timeout: 10) { !app.staticTexts[dupVol].exists }
    }

    // MARK: - Confirmation helper

    /// Click the confirm button (default "Delete") in the destructive-action
    /// confirmation. SwiftUI `.confirmationDialog` may surface under sheets,
    /// dialogs, or the window on macOS, so query the button globally. Returns
    /// false if no confirmation button appeared (i.e. the confirmation is missing).
    @discardableResult
    private func confirmDelete(_ title: String = "Delete") -> Bool {
        guard waitUntil(timeout: UI.timeout, { self.confirmationButton(title).exists }) else { return false }
        confirmationButton(title).click()
        return true
    }

    /// Whether a confirmation surface with the given confirm button is visible.
    private func confirmationVisible(_ title: String = "Delete") -> Bool {
        waitUntil(timeout: UI.timeout) { self.confirmationButton(title).exists }
    }

    /// A `.confirmationDialog` button. macOS mirrors the dialog's default button
    /// onto the Touch Bar (an unclickable proxy that the unscoped `app.buttons[…]`
    /// may resolve first); every scope below excludes the Touch Bar, so we try the
    /// likely hosts in turn and return the first that actually exists.
    private func confirmationButton(_ title: String) -> XCUIElement {
        let scopes: [XCUIElementQuery] = [app.dialogs, app.sheets, app.popovers, app.windows]
        for scope in scopes {
            let button = scope.buttons[title].firstMatch
            if button.exists { return button }
        }
        return app.windows.buttons[title].firstMatch
    }

    // MARK: - Row-trash helper

    /// Click the destructive (trash) button belonging to the list row whose name
    /// label is `name`. The row is an HStack with the name as static text and a
    /// trailing borderless trash button (no label); we pick the button that
    /// vertically overlaps the name and sits furthest to its right.
    private func clickRowTrash(forName name: String, inList listID: String) {
        let list = app.descendants(matching: .any)[listID].firstMatch
        let nameText = app.staticTexts[name].firstMatch
        guard nameText.waitForExistence(timeout: 5) else { return }

        // Row delete buttons are labelled "Delete <kind> <name>": use that
        // rather than geometry, which breaks when the window straddles screens.
        let labelled = list.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Delete' AND label ENDSWITH %@",
                                                         " \(name)")).firstMatch
        if labelled.exists {
            labelled.click()
            return
        }

        let buttons = list.buttons.allElementsBoundByIndex
        let nameFrame = nameText.frame
        var best: XCUIElement?
        var bestX: CGFloat = -1
        for b in buttons where b.exists && b.isHittable {
            let f = b.frame
            let verticalOverlap = f.midY > nameFrame.minY - 6 && f.midY < nameFrame.maxY + 6
            if verticalOverlap && f.minX > nameFrame.minX && f.minX > bestX {
                best = b; bestX = f.minX
            }
        }
        if let best {
            best.click()
        } else {
            let c = nameText.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
                .withOffset(CGVector(dx: 380, dy: 0))
            c.click()
        }
    }

    // MARK: - Error bar detection

    /// The ErrorBar is a white-on-red capsule (`Text(model.error)`) pinned to the
    /// bottom. Its content surfaces in the static text's `value` (NOT `label`),
    /// and bulk enumeration is unreliable mid-update, so detect it with a
    /// predicate query over `value` for a backend-error fragment.
    private func errorBarVisible() -> Bool {
        let fragments = ["already exists", "failed", "exit code", "cannot", "in use", "Error"]
        for frag in fragments {
            let q = app.staticTexts.containing(
                NSPredicate(format: "value CONTAINS[c] %@ OR label CONTAINS[c] %@", frag, frag)).firstMatch
            if q.exists { return true }
        }
        return false
    }
}
