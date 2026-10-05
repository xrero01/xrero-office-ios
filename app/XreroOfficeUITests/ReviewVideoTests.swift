import XCTest

/// App Review screen recording (review-video.yml records the simulator while this runs). Drives the REAL app (Debug/Release
/// configuration: the system document browser + editor, no test overlay) the way a user does: Home screen -> tap the icon
/// -> Create Document -> type English + Arabic with Bold -> Save -> close -> open a spreadsheet and a presentation from
/// Files -> switch the interface to Arabic -> Settings > Xrero Office > Licences. Steps are best-effort (the recording
/// matters more than any single step); every step leaves a screenshot and the element tree when something is missing.
final class ReviewVideoTests: XCTestCase {

    private let app = XCUIApplication()

    override func setUp() { continueAfterFailure = true }

    private func shot(_ name: String, _ target: XCUIApplication? = nil) {
        let a = XCTAttachment(screenshot: (target ?? app).screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func dump(_ name: String, _ target: XCUIApplication? = nil) {
        let a = XCTAttachment(string: (target ?? app).debugDescription)
        a.name = "tree-" + name
        a.lifetime = .keepAlways
        add(a)
        shot("missing-" + name, target)
    }

    private func pause(_ s: Double) { Thread.sleep(forTimeInterval: s) }

    private func typeSlowly(_ text: String) {
        dismissKeyboardTip()
        for ch in text { app.typeText(String(ch)); usleep(120_000) }
    }

    /// iOS shows a one-time keyboard tip ("Speed up your typing by sliding your finger...") with a Continue button.
    private func dismissKeyboardTip() {
        let tip = app.buttons.matching(NSPredicate(format: "label == 'Continue'")).firstMatch
        if tip.exists && tip.isHittable { tip.tap(); pause(1) }
    }

    /// First element (any type) whose label matches, waiting up to `timeout`.
    private func find(_ q: XCUIElementQuery, _ format: String, timeout: TimeInterval = 15) -> XCUIElement? {
        let e = q.matching(NSPredicate(format: format)).firstMatch
        return e.waitForExistence(timeout: timeout) ? e : nil
    }

    private func webButton(_ format: String, timeout: TimeInterval = 10) -> XCUIElement? {
        find(app.webViews.buttons, format, timeout: timeout)
    }

    /// The editor is ready when its Save button is in the web view.
    @discardableResult
    private func waitEditor(_ name: String) -> Bool {
        let ok = webButton("label BEGINSWITH[c] 'Save' OR label BEGINSWITH 'حفظ'", timeout: 120) != nil
        pause(3)
        shot("editor-" + name)
        if !ok { dump("editor-" + name) }
        return ok
    }

    private func saveDocument() {
        if let b = webButton("label BEGINSWITH[c] 'Save' OR label BEGINSWITH 'حفظ'"), b.isHittable { b.tap() }
        else { app.typeKey("s", modifierFlags: .command) }
        pause(4)
    }

    /// Back to the document browser with the editor's navigation (system back button of the document scene).
    private func closeDocument() {
        let nav = app.navigationBars.buttons.element(boundBy: 0)
        if nav.waitForExistence(timeout: 5) && nav.isHittable { nav.tap() } else { dump("close") }
        pause(3)
    }

    /// A system alert (e.g. "Unable to Import Document") is recorded, then closed so the rest of the flow still runs.
    @discardableResult
    private func dismissAlert(_ name: String) -> Bool {
        let alert = app.alerts.firstMatch
        guard alert.waitForExistence(timeout: 2) else { return false }
        print("XR alert \(name): \(alert.label) | \(alert.staticTexts.allElementsBoundByIndex.map { $0.label })")
        dump("alert-" + name)
        alert.buttons.firstMatch.tap()
        return true
    }

    /// Browse > On My iPhone > Xrero Office > <name>
    private func openFromFiles(_ name: String) -> Bool {
        if let b = find(app.buttons, "label == 'Browse'", timeout: 5) { b.tap(); pause(1.5) }
        for loc in ["On My iPhone", "On My iPad"] {
            if let l = find(app.cells, "label BEGINSWITH '\(loc)'", timeout: 2) ?? find(app.staticTexts, "label == '\(loc)'", timeout: 1) {
                l.tap(); pause(1.5); break
            }
        }
        if let f = find(app.cells, "label BEGINSWITH 'Xrero Office'", timeout: 4) ?? find(app.staticTexts, "label == 'Xrero Office'", timeout: 1) {
            f.tap(); pause(1.5)
        }
        let base = (name as NSString).deletingPathExtension
        guard let file = find(app.cells, "label BEGINSWITH '\(base)'", timeout: 6)
                ?? find(app.staticTexts, "label BEGINSWITH '\(base)'", timeout: 2) else { dump("file-" + base); return false }
        file.tap()
        pause(3)
        return !dismissAlert("open-" + base)
    }

    func testReviewFlow() throws {
        XCUIDevice.shared.orientation = .portrait

        // 1. Home screen, then launch Xrero Office from its icon
        XCUIDevice.shared.press(.home)
        pause(2.5)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let icon = springboard.icons["Xrero Office"]
        var launched = false
        for _ in 0..<4 {
            if icon.exists && icon.isHittable { icon.tap(); launched = true; break }
            springboard.swipeLeft(); pause(1.5)
        }
        if launched { pause(1); app.activate() } else { dump("icon", springboard); app.launch() }
        pause(3)
        shot("01-launched")

        // 2. New document from the document browser
        if let create = find(app.buttons, "label CONTAINS[c] 'Create Document' OR label CONTAINS[c] 'New Document' OR label == 'Create'", timeout: 20) {
            create.tap()
        } else { dump("create") }
        // the editor, or a system alert (e.g. "Unable to Import Document"), whichever comes first
        let saveQ = app.webViews.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'Save' OR label BEGINSWITH 'حفظ'")).firstMatch
        let end = Date().addingTimeInterval(90)
        while Date() < end && !saveQ.exists && !app.alerts.firstMatch.exists { pause(1) }
        if dismissAlert("after-create") {
            print("XR create: alert -> opening the created document from Files instead")
            _ = openFromFiles("Untitled.docx")
        }
        guard waitEditor("word"), app.webViews.firstMatch.exists else {
            XCTFail("no editor after Create Document"); return
        }

        // 3. Type English (one word in Bold) and Arabic, then Save
        app.webViews.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
        pause(2.5)
        dismissKeyboardTip()
        typeSlowly("Xrero Office works ")
        let bold = webButton("label BEGINSWITH[c] 'Bold' OR label BEGINSWITH 'غامق'", timeout: 3)
        bold?.tap(); pause(0.5)
        typeSlowly("offline")
        bold?.tap(); pause(0.5)
        typeSlowly(" on iPhone.")
        app.typeText("\n")
        typeSlowly("\u{0645}\u{0631}\u{062D}\u{0628}\u{0627}\u{064B} \u{0628}\u{0643}\u{0645} \u{0641}\u{064A} \u{0625}\u{0643}\u{0633}\u{064A}\u{0631}\u{0648} \u{0623}\u{0648}\u{0641}\u{064A}\u{0633}")   // مرحباً بكم في إكسيرو أوفيس
        pause(2)
        shot("02-typed")
        saveDocument()
        shot("03-saved")
        closeDocument()
        shot("04-browser")

        // 4. A spreadsheet from Files: edit a cell, save
        if openFromFiles("sales_en.xlsx") && waitEditor("sheet") {
            app.webViews.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.45)).doubleTap()
            pause(1)
            typeSlowly("1250")
            app.typeText("\n")
            pause(2)
            shot("05-sheet-edited")
            saveDocument()
            closeDocument()
        }

        // 5. A presentation from Files: go through the slides
        if openFromFiles("deck_en.pptx") && waitEditor("deck") {
            let web = app.webViews.firstMatch
            for _ in 0..<3 {
                web.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)).press(forDuration: 0.05,
                    thenDragTo: web.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
                pause(1.5)
            }
            shot("06-deck")
            // 6. Interface language EN -> AR (the editor reopens in Arabic)
            if let ar = find(app.webViews.staticTexts, "label == 'AR'", timeout: 3) ?? webButton("label == 'AR'", timeout: 1) {
                ar.tap(); pause(2); waitEditor("deck-ar")
            } else { dump("lang") }
            closeDocument()
        }

        // 7. Settings > Apps > Xrero Office > Licences
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        pause(2)
        var apps: XCUIElement? = nil
        for _ in 0..<4 {
            apps = find(settings.buttons, "identifier == 'com.apple.settings.apps' OR label == 'Apps'", timeout: 2)
                ?? find(settings.cells, "label == 'Apps'", timeout: 1)
            if let a = apps, a.isHittable { break }
            settings.swipeUp(); pause(0.8)
        }
        if let a = apps { a.tap(); pause(2) } else { dump("settings-apps", settings) }
        var row: XCUIElement? = nil
        for _ in 0..<8 {
            row = find(settings.buttons, "label CONTAINS 'Xrero Office'", timeout: 1)
                ?? find(settings.cells, "label CONTAINS 'Xrero Office'", timeout: 1)
                ?? find(settings.staticTexts, "label == 'Xrero Office'", timeout: 1)
            if let r = row, r.isHittable { break }
            settings.swipeUp(); pause(0.8)
        }
        if let r = row { r.tap(); pause(2) } else { dump("settings-app", settings) }
        if let lic = find(settings.buttons, "label CONTAINS 'Licences'", timeout: 4)
            ?? find(settings.cells, "label CONTAINS 'Licences'", timeout: 1)
            ?? find(settings.staticTexts, "label == 'Licences'", timeout: 1) {
            lic.tap(); pause(2)
            settings.swipeUp(); pause(1.5)
            shot("07-licences", settings)
        } else { dump("licences", settings) }
        pause(1)
    }
}
