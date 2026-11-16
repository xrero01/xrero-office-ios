import XCTest

/// Plan S10: Home Screen quick actions and Scan to PDF, on the real Home (XR_HOME=1 in the Autotest build).
/// XR_SHORTCUT=<id> sends a quick action through the same router the system's shortcut item uses; one test also
/// presses the real app icon on the Home Screen. The simulator has no document camera, so Scan must show the honest
/// "not available" alert and keep the app running; XR_SCAN_SAMPLE=1 proves the save-and-open path with drawn pages.
final class ScanQuickActionUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private func launch(_ env: [String: String], lang: String = "en") -> XCUIApplication {
        let app = XCUIApplication()
        var e = env
        e["XR_HOME"] = "1"
        app.launchEnvironment = e
        app.launchArguments = ["-xr.lang", lang, "-xr.welcomeShown", "YES"]
        app.launch()
        return app
    }

    /// The editor's title in its top bar, once the new file is open.
    private func editorTitle(_ app: XCUIApplication, timeout: TimeInterval = 90) -> String? {
        let t = app.staticTexts["xr-bar-title"]
        guard t.waitForExistence(timeout: timeout) else { return nil }
        return t.label
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    func testQuickActionsOpenTheRightNewFile() {
        let cases: [(id: String, lang: String, title: String)] = [
            ("new-document", "en", "Document"),
            ("new-spreadsheet", "en", "Spreadsheet"),
            ("new-presentation", "en", "Presentation"),
            ("new-spreadsheet", "ar", "جدول بيانات"),
        ]
        for c in cases {
            let app = launch(["XR_SHORTCUT": c.id], lang: c.lang)
            let title = editorTitle(app)
            print("XR quick \(c.id) \(c.lang): title=\(title ?? "none")")
            shot("quick-\(c.id)-\(c.lang)")
            XCTAssertNotNil(title, "quick action \(c.id) (\(c.lang)) opened no editor")
            XCTAssertTrue(title?.hasPrefix(c.title) ?? false,
                          "quick action \(c.id) (\(c.lang)) opened '\(title ?? "")', expected a new '\(c.title)'")
            app.terminate()
        }
    }

    func testScanRowOnSimulatorShowsUnavailable() {
        for lang in ["en", "ar"] {
            let app = launch([:], lang: lang)
            let row = app.buttons["xr-home-scan"]
            XCTAssertTrue(row.waitForExistence(timeout: 20), "Home has no Scan to PDF row (\(lang))")
            if !row.isHittable { app.swipeUp() }
            row.tap()
            let title = lang == "ar" ? "المسح غير متاح" : "Scanning isn't available"
            let alert = app.alerts[title]
            let shown = alert.waitForExistence(timeout: 10)
            print("XR scan row \(lang): unavailable alert=\(shown)")
            shot("scan-unavailable-\(lang)")
            XCTAssertTrue(shown, "no honest 'scanning not available' alert on the simulator (\(lang))")
            alert.buttons.firstMatch.tap()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5), "the app did not stay running after Scan")
            XCTAssertTrue(app.buttons["xr-home-scan"].waitForExistence(timeout: 5), "Home is gone after the alert")
            app.terminate()
        }
    }

    func testScanQuickActionOnSimulatorShowsUnavailable() {
        let app = launch(["XR_SHORTCUT": "scan"])
        let alert = app.alerts["Scanning isn't available"]
        let shown = alert.waitForExistence(timeout: 20)
        print("XR quick scan: unavailable alert=\(shown)")
        shot("quick-scan-unavailable")
        XCTAssertTrue(shown, "the Scan quick action showed no honest alert on the simulator")
        alert.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["xr-home-scan"].waitForExistence(timeout: 5), "Home is gone after the alert")
        app.terminate()
    }

    /// Two drawn pages through the real save-and-open path: "Scan <date>.pdf" (check_saved.py counts its pages).
    func testScanSavesPdfAndOpensIt() {
        for lang in ["en", "ar"] {
            let app = launch(["XR_SCAN_SAMPLE": "1"], lang: lang)
            let row = app.buttons["xr-home-scan"]
            XCTAssertTrue(row.waitForExistence(timeout: 20))
            if !row.isHittable { app.swipeUp() }
            row.tap()
            let title = editorTitle(app)
            print("XR scan sample \(lang): title=\(title ?? "none")")
            shot("scan-sample-\(lang)")
            let prefix = lang == "ar" ? "مسح 20" : "Scan 20"
            XCTAssertTrue(title?.hasPrefix(prefix) ?? false, "the scan did not open as '\(prefix)...' (\(title ?? "none"))")
            app.terminate()
        }
    }

    /// The real Home Screen: touch and hold the app icon, the four quick actions are listed, New Spreadsheet opens one.
    /// This is the only test of the system's own delivery (Info.plist UIApplicationShortcutItems, the cold launch's
    /// options.shortcutItem); the others inject XR_SHORTCUT. A newly installed app lands past the first Home Screen
    /// page, so the pages are swiped through (as a person would) until the icon is there - the App Library last.
    /// Quick actions missing from the icon's menu are a FAIL. Skipped (with an INFO line, listed by check_saved.py)
    /// only when the icon cannot be found at all or no icon menu opens.
    func testHomeScreenIconQuickActions() throws {
        let app = launch([:])                                   // installs + runs once, then leave to the Home Screen
        _ = app.buttons["xr-home-scan"].waitForExistence(timeout: 20)
        app.terminate()
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let icon = springboard.icons["Xrero Office"]
        _ = icon.waitForExistence(timeout: 5)
        var pages = 0
        while !(icon.exists && icon.isHittable) && pages < 8 {
            springboard.swipeLeft()
            sleep(1)
            pages += 1
        }
        print("XR springboard: icon after \(pages) page swipe(s): exists=\(icon.exists) hittable=\(icon.exists && icon.isHittable)")
        guard icon.exists && icon.isHittable else {
            shot("springboard-no-icon")
            print("XR springboard icon: INFO skipped - the app icon was not found on the Home Screen pages or the App Library (\(pages) swipes)")
            throw XCTSkip("app icon not found on the Home Screen")
        }
        shot("springboard-icon")
        icon.press(forDuration: 1.5)
        let titles = ["New Document", "New Spreadsheet", "New Presentation", "Scan to PDF"]
        let first = springboard.buttons[titles[0]]
        guard first.waitForExistence(timeout: 8) else {
            shot("springboard-no-quick-actions")
            // the system's own items show that the icon menu itself opened: then the app's quick actions are missing
            let system = ["Remove App", "Delete App", "Edit Home Screen", "Share App"].filter { springboard.buttons[$0].exists }
            if !system.isEmpty {
                print("XR springboard: FAIL the icon menu opened (\(system.joined(separator: ", "))) without the app's quick actions")
                XCTFail("quick actions missing from the icon menu (system items: \(system.joined(separator: ", ")))")
                return
            }
            print("XR springboard menu: INFO skipped - no icon menu opened after touch and hold")
            throw XCTSkip("no icon menu shown")
        }
        shot("springboard-quick-actions")
        let found = titles.map { springboard.buttons[$0].exists }
        print("XR springboard: quick actions \(zip(titles, found).map { "\($0.0)=\($0.1)" }.joined(separator: " "))")
        XCTAssertEqual(found, [true, true, true, true], "the app icon does not list all four quick actions")
        springboard.buttons["New Spreadsheet"].tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15), "New Spreadsheet did not start the app")
        let title = editorTitle(app)
        print("XR springboard: New Spreadsheet opened title=\(title ?? "none")")
        shot("springboard-new-spreadsheet")
        // the new file is named in the app's language (the icon launch carries no -xr.lang: an earlier test may have
        // left the app in Arabic); either way it must be a new spreadsheet
        let spreadsheet = (title?.hasPrefix("Spreadsheet") ?? false) || (title?.hasPrefix("\u{062C}\u{062F}\u{0648}\u{0644} \u{0628}\u{064A}\u{0627}\u{0646}\u{0627}\u{062A}") ?? false)  // جدول بيانات
        XCTAssertTrue(spreadsheet, "New Spreadsheet opened '\(title ?? "none")'")
        app.terminate()
    }
}
