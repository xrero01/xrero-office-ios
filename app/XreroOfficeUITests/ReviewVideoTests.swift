import XCTest

/// App Review screen recording (review-video.yml records the simulator while this runs). Drives the REAL app (Debug/Release
/// configuration: the system document browser + editor, no test overlay) the way a user does: Home screen -> tap the icon
/// -> home screen (the optional account card: Sign in opens the account, Not now hides it) > New document -> type English +
/// Arabic with Bold -> Save -> close -> Home's Recent (search, context menu, swipe) -> open a spreadsheet and a presentation
/// from Files -> switch the interface to Arabic in the editor's globe menu (Home follows) -> Settings > Xrero Office >
/// Licences -> relaunch (no account card, still Arabic). Steps are best-effort (the recording
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
        let back = app.buttons.matching(NSPredicate(format: "label == 'Documents' OR label == 'المستندات'")).firstMatch
        let nav = back.exists ? back : app.navigationBars.buttons.element(boundBy: 0)
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

    /// Home > Browse files > Browse > On My iPhone > Xrero Office > <name>
    private func openFromFiles(_ name: String) -> Bool {
        if let h = find(app.buttons, "identifier == 'xr-home-browse'", timeout: 10) { h.tap(); pause(3) } else { dump("home-browse") }
        // the browser slides in over the home screen: wait for its own tab bar, then Browse (tap again if still on Recents)
        if let b = find(app.buttons, "label == 'Browse'", timeout: 15) {
            b.tap(); pause(2)
            if app.staticTexts["No Recents"].exists || !b.isSelected { b.tap(); pause(2) }
        } else { dump("browser") }
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
        // first launch: no sign-in wall. Home comes straight up with the optional account as an inline card, whose
        // Sign in opens the account sheet and whose Not now hides it for good.
        let acctEmail = app.textFields.matching(identifier: "xr-acct-email").firstMatch
        XCTAssertFalse(acctEmail.waitForExistence(timeout: 3), "an account sheet was presented by itself on first launch")
        let card = app.descendants(matching: .any).matching(identifier: "xr-home-account-card").firstMatch
        if card.waitForExistence(timeout: 15) {
            shot("01a-account-card")
            if let signIn = find(app.buttons, "identifier == 'xr-home-signin'", timeout: 3) {
                signIn.tap()
                XCTAssertTrue(acctEmail.waitForExistence(timeout: 10), "Sign in on the Home card did not open the account sheet")
                shot("01a-account-sheet")
                let done = app.buttons.matching(NSPredicate(format: "label == 'Done' OR label == 'تم'")).firstMatch
                if done.exists { done.tap() } else { app.swipeDown() }
                pause(1.5)
            } else { XCTFail("no Sign in button on the account card"); dump("card-signin") }
            if let later = find(app.buttons, "identifier == 'xr-home-signin-later'", timeout: 5) {
                later.tap(); pause(1.5)
            } else { XCTFail("no Not now button on the account card"); dump("card-later") }
            XCTAssertFalse(card.exists, "the account card is still shown after Not now")
        } else { XCTFail("no account card on Home at first launch"); dump("account-card") }

        // 2. The home screen (plan M8): one row of create tiles, Browse files / Open a PDF, and the empty Recent state
        shot("01b-home")
        for id in ["xr-home-word", "xr-home-cell", "xr-home-slide", "xr-home-browse", "xr-home-pdf"] {
            XCTAssertTrue(app.buttons.matching(identifier: id).firstMatch.waitForExistence(timeout: 10), "Home has no \(id)")
        }
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "xr-home-empty").firstMatch.exists,
                      "no empty Recent state on a first launch")
        XCTAssertTrue(app.buttons.matching(identifier: "xr-home-more").firstMatch.exists, "no More menu on Home")
        if let tile = find(app.buttons, "identifier == 'xr-home-word'", timeout: 20) { tile.tap() } else { dump("home") }
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
        let navButtons = app.navigationBars.buttons.allElementsBoundByIndex.map { "\($0.identifier)|\($0.label)" }
        print("XR editor nav buttons:", navButtons)
        XCTAssertEqual(app.navigationBars.buttons.matching(NSPredicate(format: "label == 'Documents' OR label == 'Back'")).count, 1,
                       "exactly one back button in the editor: \(navButtons)")

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

        // 3b. The top bar's account button -> the account screen; a wrong password shows the server's answer
        if let signIn = find(app.buttons, "identifier == 'xr-nav-account'", timeout: 5) {
            signIn.tap(); pause(2)
            let mail = app.textFields.matching(identifier: "xr-acct-email").firstMatch
            if mail.waitForExistence(timeout: 10) {
                mail.tap(); typeSlowly("review-check@example.com")
                let pw = app.secureTextFields.matching(identifier: "xr-acct-password").firstMatch
                pw.tap(); typeSlowly("not-a-real-password")
                shot("03b-account")
                app.buttons.matching(identifier: "xr-acct-submit").firstMatch.tap()
                // the server's answer, worded for people (no status codes, plan M9b)
                let answer = app.descendants(matching: .any).matching(identifier: "xr-acct-error").firstMatch
                XCTAssertTrue(answer.waitForExistence(timeout: 30), "no answer from the account server")
                print("XR account answer:", answer.label)
                XCTAssertFalse(answer.label.contains("HTTP"), "a raw status code reached the account sheet: \(answer.label)")
                shot("03c-account-answer")
                let done = app.buttons.matching(NSPredicate(format: "label == 'Done' OR label == 'تم'")).firstMatch
                if done.exists { done.tap() } else { app.swipeDown() }
                pause(1.5)
            } else { dump("account-sheet") }
        } else { dump("signin-button") }

        closeDocument()
        shot("04-home")
        checkRecent()

        var arabic = false                                          // step 6 switched the interface to Arabic
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
            // 6. Interface language EN -> AR in the editor's globe menu: a confirmation (the page reopens), then the
            // bar is Arabic at once and the page reopens in Arabic; Home follows (one language source, plan M9b)
            if let globe = find(app.buttons, "identifier == 'xr-nav-lang'", timeout: 5) {
                globe.tap(); pause(1)
                if let ar = find(app.buttons, "label == 'العربية'", timeout: 5) { ar.tap(); pause(1) } else { dump("lang-menu") }
                shot("06a-lang-confirm")
                if let ok = find(app.buttons, "identifier == 'xr-lang-confirm' OR label == 'حفظ والتبديل'", timeout: 5) {
                    ok.tap(); pause(2); waitEditor("deck-ar"); arabic = true
                } else { XCTFail("no confirmation before the editor reopens in Arabic"); dump("lang-confirm") }
                XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == 'المستندات'")).firstMatch.waitForExistence(timeout: 10),
                              "the editor's bar did not switch to Arabic")
            } else { dump("lang") }
            closeDocument()
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label ==[c] 'الأخيرة'")).firstMatch.waitForExistence(timeout: 10),
                          "Home did not follow the editor into Arabic")
            shot("06b-home-ar")
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

        // 8. Back to Xrero Office after a fresh start: the account card answered with Not now stays away
        app.terminate()
        app.launch()
        pause(3)
        XCTAssertTrue(app.buttons.matching(identifier: "xr-home-word").firstMatch.waitForExistence(timeout: 20), "no Home after relaunch")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "xr-home-account-card").firstMatch.exists,
                       "the account card came back after Not now")
        XCTAssertFalse(acctEmail.exists, "an account sheet was presented by itself after relaunch")
        // the Arabic choice made in the editor persists across a relaunch
        if arabic { XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label ==[c] 'الأخيرة'")).firstMatch.waitForExistence(timeout: 5),
                      "the interface language did not persist across a relaunch") }
        shot("08-relaunched-home")
    }

    /// Home after the first document (plan M8): the file is in Recent; search finds it (and hides the create row);
    /// its context menu offers Open / Share / Show in Files / Remove; a swipe offers Remove and Share. Nothing is removed.
    private func checkRecent() {
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'xr-recent-Document'")).firstMatch
        guard row.waitForExistence(timeout: 10) else { XCTFail("the new document is not in Recent"); dump("recent"); return }
        pause(2)                                                    // the first-page thumbnail
        shot("04a-recent")

        let search = app.searchFields.firstMatch
        if search.waitForExistence(timeout: 5) {
            search.tap(); pause(0.5)
            typeSlowly("Docu")
            pause(1)
            XCTAssertTrue(row.exists, "search did not find the recent document")
            XCTAssertFalse(app.buttons.matching(identifier: "xr-home-word").firstMatch.exists, "search kept the create row")
            shot("04b-search")
            let cancel = app.buttons.matching(NSPredicate(format: "label == 'Cancel'")).firstMatch
            if cancel.exists { cancel.tap() } else { search.buttons.firstMatch.tap() }
            pause(1)
        } else { XCTFail("no search field over Recent"); dump("search") }

        row.press(forDuration: 1.3)
        pause(1)
        let show = app.buttons.matching(NSPredicate(format: "label == 'Show in Files'")).firstMatch
        XCTAssertTrue(show.waitForExistence(timeout: 5), "no context menu on a recent file")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == 'Remove from Recent'")).firstMatch.exists,
                      "no Remove from Recent in the context menu")
        shot("04c-context-menu")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)).tap()     // closes the menu, taps nothing
        pause(1)

        if row.waitForExistence(timeout: 5) {
            row.swipeLeft()
            pause(1)
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == 'Remove'")).firstMatch.waitForExistence(timeout: 3),
                          "no swipe actions on a recent file")
            shot("04d-swipe")
            row.swipeRight()
            pause(1)
        }
        XCTAssertTrue(row.exists, "the recent file went away while only looking at its actions")
    }
}
