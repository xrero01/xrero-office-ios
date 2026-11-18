import XCTest
import UIKit

/// The required Xrero account (owner 18 Nov 2026; parity with Windows and Mac 20.2), iPhone and iPad, English and
/// Arabic, on the real Home (XR_HOME=1 in the Autotest build) and the real editor path (DocumentOpener -> EditorHost).
///
/// No account is ever created and nothing is deleted on xrero.com. XR_NO_SESSION=1: no stored account - the wall, as
/// on a first launch or after an update for a user who chose "Not now" in 20.1-21.0. XR_TEST_SESSION=1 (or the Darwin
/// notification / xrero-autotest://session hook while the wall is up): a LOCAL stored session the app never sends
/// anywhere (XreroAccount, test builds only) - the Mac UI test's XR_NO_SIGNUP path. The only request to xrero.com is a
/// made-up sign-in, which the server refuses with its own "Invalid email or password." answer.
final class AccountWallUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private var pad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    private func launch(_ env: [String: String], lang: String = "en") -> XCUIApplication {
        let app = XCUIApplication()
        var e = env
        e["XR_HOME"] = "1"
        app.launchEnvironment = e
        // a file handed over opens for editing (no reading view), so its editor's title is up at once
        app.launchArguments = ["-xr.lang", lang, "-xr.readingView", "NO"]
        app.launch()
        return app
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = "acct-" + name
        a.lifetime = .keepAlways
        add(a)
    }

    private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func waitGone(_ e: XCUIElement, _ timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if !e.exists { return true }
            usleep(300_000)
        }
        return !e.exists
    }

    /// The wall is up and offers no way past it: no skip / "continue without an account", no Done or Close, no Home
    /// card's "Not now", and (`home`) no Home behind it.
    private func assertWall(_ app: XCUIApplication, _ tag: String, home: Bool, timeout: TimeInterval = 20) {
        XCTAssertTrue(el(app, "xr-acct-wall").waitForExistence(timeout: timeout), "no account wall (\(tag))")
        for id in ["xr-acct-skip", "xr-acct-done", "xr-acct-close", "xr-home-signin-later", "xr-home-account-card"] {
            XCTAssertFalse(el(app, id).exists, "\(id) on the account wall (\(tag))")
        }
        let way = app.buttons.matching(NSPredicate(format:
            "label CONTAINS[c] 'without an account' OR label CONTAINS 'بدون حساب' OR label IN {'Not now', 'ليس الآن', 'Done', 'تم', 'Close', 'إغلاق', 'Skip'}"))
        XCTAssertEqual(way.count, 0, "a way past the wall (\(tag)): \(way.allElementsBoundByIndex.map(\.label))")
        if home { XCTAssertFalse(el(app, "xr-home-list").exists, "Home is reachable behind the wall (\(tag))") }
        print("XR account wall up (\(tag))")
    }

    /// Types into a field of the wall; iOS's one-time keyboard tip ("Speed up your typing...") on a fresh simulator is
    /// answered with its Continue and the field tapped again (the 21.0 form gate saw the same tip).
    private func typeInto(_ app: XCUIApplication, _ field: XCUIElement, _ text: String) {
        for attempt in 1...3 {
            field.tap()
            _ = app.keyboards.firstMatch.waitForExistence(timeout: 5)
            let tip = app.buttons.matching(NSPredicate(format: "label == 'Continue'")).firstMatch
            if tip.exists && tip.isHittable {
                print("XR account keyboard tip (attempt \(attempt)): Continue tapped, the field tapped again")
                tip.tap()
                sleep(2)
                continue
            }
            break
        }
        field.typeText(text)
    }

    /// "Signing in" for the test: the app's local test session (XreroAccount, Autotest build), through a Darwin
    /// notification - it reaches the app whatever is on screen - or, if that did not land, Home's
    /// xrero-autotest://session hook.
    private func startLocalSession(_ app: XCUIApplication) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName("com.xrero.office.autotest.session" as CFString), nil, nil, true)
        if waitGone(el(app, "xr-acct-wall"), 6) { print("XR account test session: started (notification)"); return }
        print("XR account test session: notification not seen, xrero-autotest://session")
        XCUIDevice.shared.system.open(URL(string: "xrero-autotest://session")!)
    }

    /// A button of an alert: SwiftUI puts each alert action into the tree twice (a Button inside a Button with the same
    /// identifier and label - CI run 44286726554: "Multiple matching elements found"), so the first match is tapped.
    private func alertButton(_ alert: XCUIElement, _ id: String, _ label: String) -> XCUIElement {
        let byId = alert.buttons.matching(identifier: id).firstMatch
        return byId.exists ? byId : alert.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    /// The editor is up: its title shows and its second line no longer says Opening…
    private func waitEditor(_ app: XCUIApplication, timeout: TimeInterval = 120) -> String? {
        let title = app.staticTexts["xr-bar-title"], status = app.staticTexts["xr-bar-status"]
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            let s = (try? status.firstMatch.snapshot())?.label ?? ""
            if title.exists && !s.hasPrefix("Opening") && !s.hasPrefix("جارٍ الفتح") { sleep(2); return title.label }
            usleep(500_000)
        }
        return nil
    }

    /// Back to Home from the editor (an untouched new file is removed again on close, plan S9).
    private func closeEditor(_ app: XCUIApplication) {
        let back = app.buttons["xr-bar-back"]
        if back.waitForExistence(timeout: 10) { back.tap() }
        XCTAssertTrue(el(app, "xr-home-list").waitForExistence(timeout: 30), "no Home after closing the editor")
    }

    // MARK: tests

    /// First launch (no stored account), EN + AR: the wall, in the interface language, with Sign in / Create account,
    /// the privacy policy, About & Licences and the language switch - and nothing that gets past it: no skip, no Done,
    /// and swipe down, Escape, Cmd-. and a tap at the screen's edge all leave it up. Right-to-left in Arabic.
    func testWallAtFirstLaunchHasNoWayPast() {
        for lang in ["en", "ar"] {
            let ar = lang == "ar"
            let app = launch(["XR_NO_SESSION": "1"], lang: lang)
            assertWall(app, "first launch \(lang)", home: true, timeout: 30)
            sleep(1)
            shot(app, "wall-\(lang)")

            let welcome = el(app, "xr-acct-welcome"), intro = el(app, "xr-acct-intro")
            XCTAssertTrue(welcome.exists, "no welcome heading on the wall (\(lang))")
            XCTAssertTrue(intro.exists, "no intro on the wall (\(lang))")
            let text = intro.label
            print("XR account wall \(lang): heading=\(welcome.label) intro=\(text)")
            XCTAssertEqual(welcome.label, ar ? "مرحبًا بك في Xrero Office" : "Welcome to Xrero Office", "heading (\(lang))")
            XCTAssertTrue(ar ? text.hasPrefix("أنشئ حساب Xrero المجاني") : text.hasPrefix("Create your free Xrero account"),
                          "the wall does not ask for the free account (\(lang)): \(text)")
            XCTAssertFalse(text.lowercased().contains("optional") || text.contains("اختياري"), "'optional' on the wall (\(lang))")

            let tabIn = app.buttons["xr-acct-tab-in"], tabNew = app.buttons["xr-acct-tab-new"]
            XCTAssertTrue(tabIn.exists, "no Sign in tab (\(lang))")
            XCTAssertTrue(tabNew.exists, "no Create account tab (\(lang))")
            XCTAssertEqual(tabNew.label, ar ? "إنشاء حساب" : "Create account", "Create tab label (\(lang))")
            XCTAssertTrue(app.textFields["xr-acct-email"].exists, "no email field (\(lang))")
            XCTAssertTrue(app.secureTextFields["xr-acct-password"].exists, "no password field (\(lang))")
            XCTAssertTrue(app.buttons["xr-acct-submit"].exists, "no Continue (\(lang))")
            XCTAssertTrue(el(app, "xr-acct-privacy").exists, "no Privacy Policy link on the wall (\(lang))")
            XCTAssertTrue(el(app, "xr-acct-about").exists, "no About & Licences on the wall (\(lang))")
            let langSwitch = app.buttons["xr-acct-lang"]
            XCTAssertTrue(langSwitch.exists, "no language switch on the wall (\(lang))")
            XCTAssertEqual(langSwitch.label, ar ? "التبديل إلى الإنجليزية" : "Switch to Arabic", "language switch (\(lang))")

            // right-to-left in Arabic: the leading tab (Sign in) is the right-hand one
            let a = tabIn.frame, b = tabNew.frame
            print("XR account wall \(lang): Sign in tab \(a) Create tab \(b)")
            if ar { XCTAssertGreaterThan(a.midX, b.midX, "Arabic wall not right-to-left: Sign in \(a) Create \(b)") }
            else { XCTAssertLessThan(a.midX, b.midX, "English wall mirrored: Sign in \(a) Create \(b)") }
            XCTAssertTrue(tabIn.isSelected && !tabNew.isSelected, "Sign in is not the selected tab at first (\(lang))")

            // the Create tab: a name field joins email + password, and Continue says Create account
            tabNew.tap()
            XCTAssertTrue(app.textFields["xr-acct-name"].waitForExistence(timeout: 5), "Create account shows no name field (\(lang))")
            XCTAssertEqual(app.buttons["xr-acct-submit"].label, ar ? "إنشاء الحساب" : "Create account", "Create: submit label (\(lang))")
            shot(app, "wall-\(lang)-create")
            tabIn.tap()
            XCTAssertTrue(waitGone(app.textFields["xr-acct-name"], 5), "Sign in still shows the name field (\(lang))")

            // nothing closes it
            app.swipeDown(velocity: .fast)
            sleep(1)
            assertWall(app, "swipe down \(lang)", home: true, timeout: 3)
            app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
            sleep(1)
            assertWall(app, "Escape \(lang)", home: true, timeout: 3)
            app.typeKey(".", modifierFlags: .command)
            sleep(1)
            assertWall(app, "Cmd-. \(lang)", home: true, timeout: 3)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.01)).tap()     // the status bar: no control there
            sleep(1)
            assertWall(app, "tap at the edge \(lang)", home: true, timeout: 3)

            // About & Licences opens from the wall and comes back to it
            let about = el(app, "xr-acct-about")
            if !about.isHittable { app.swipeUp() }
            about.tap()
            XCTAssertTrue(app.staticTexts["xr-about-version"].waitForExistence(timeout: 10), "About did not open from the wall (\(lang))")
            shot(app, "wall-\(lang)-about")
            app.navigationBars.buttons.firstMatch.tap()
            assertWall(app, "back from About \(lang)", home: true, timeout: 10)
            app.terminate()
        }
    }

    /// The language switch on the wall flips the wall at once (and the app: the same setting as Home's ⋯ > Language).
    func testWallLanguageSwitch() {
        let app = launch(["XR_NO_SESSION": "1"], lang: "en")
        assertWall(app, "language en", home: true, timeout: 30)
        app.buttons["xr-acct-lang"].tap()
        let welcome = el(app, "xr-acct-welcome")
        let end = Date().addingTimeInterval(5)
        while Date() < end && welcome.label != "مرحبًا بك في Xrero Office" { usleep(300_000) }
        print("XR account wall after the language switch: \(welcome.label)")
        XCTAssertEqual(welcome.label, "مرحبًا بك في Xrero Office", "the wall did not switch to Arabic")
        shot(app, "wall-switched-ar")
        app.buttons["xr-acct-lang"].tap()
        let back = Date().addingTimeInterval(5)
        while Date() < back && welcome.label != "Welcome to Xrero Office" { usleep(300_000) }
        XCTAssertEqual(welcome.label, "Welcome to Xrero Office", "the wall did not switch back to English")
        assertWall(app, "language back", home: true, timeout: 3)
        app.terminate()
    }

    /// Requests that arrive while the wall is up open nothing - a Home Screen quick action (New Presentation) and a file
    /// handed over by another app (Open in / Share, through Home's onOpenURL path) - and each runs once the user has
    /// signed in. The editor is closed again: the untouched new presentation is removed (plan S9), no test file left.
    func testRequestsWaitBehindTheWallUntilSignIn() {
        let runs: [(env: [String: String], tag: String, title: String)] = [
            (["XR_SHORTCUT": "new-presentation"], "quick-action", "Presentation"),
            (["XR_HOME_INCOMING": "xr-wall-in.docx"], "open-in", "xr-wall-in"),
        ]
        for r in runs {
            var env = r.env
            env["XR_NO_SESSION"] = "1"
            let app = launch(env)
            assertWall(app, r.tag, home: true, timeout: 30)
            let title = app.staticTexts["xr-bar-title"]
            XCTAssertFalse(title.waitForExistence(timeout: 8), "\(r.tag): an editor opened without an account")
            shot(app, "held-\(r.tag)")

            startLocalSession(app)
            XCTAssertTrue(waitGone(el(app, "xr-acct-wall"), 15), "\(r.tag): the wall stayed after sign-in")
            let opened = waitEditor(app)
            print("XR account wall \(r.tag): after sign-in the editor title=\(opened ?? "none")")
            XCTAssertNotNil(opened, "\(r.tag): the request that waited behind the wall never opened")
            XCTAssertTrue(opened?.hasPrefix(r.title) ?? false, "\(r.tag): opened '\(opened ?? "")', expected '\(r.title)...'")
            shot(app, "released-\(r.tag)")
            closeEditor(app)
            app.terminate()
        }
    }

    /// A made-up sign-in (never a real account) gets the server's own answer - "Invalid email or password." (401) -
    /// worded for people, with no status code; the wall stays. One request per device: English on the iPhone, Arabic
    /// on the iPad.
    func testMadeUpSignInGetsTheServersAnswer() {
        let lang = pad ? "ar" : "en"
        let app = launch(["XR_NO_SESSION": "1"], lang: lang)
        assertWall(app, "sign-in \(lang)", home: true, timeout: 30)
        let mail = app.textFields["xr-acct-email"]
        XCTAssertTrue(mail.waitForExistence(timeout: 10), "no email field")
        typeInto(app, mail, "ios-check@example.com")
        typeInto(app, app.secureTextFields["xr-acct-password"], "not-a-real-password")
        shot(app, "signin-typed-\(lang)")
        app.buttons["xr-acct-submit"].tap()
        let answer = el(app, "xr-acct-error")
        XCTAssertTrue(answer.waitForExistence(timeout: 40), "no answer from xrero.com to the made-up sign-in")
        // a Label: its icon (VoiceOver "Error") and its text carry the identifier both (CI run 44286726554 read the
        // icon alone) - every part of it is read
        let text = app.descendants(matching: .any).matching(identifier: "xr-acct-error").allElementsBoundByIndex
            .map(\.label).joined(separator: " | ")
        print("XR account server answer (\(lang)): \(text)")
        shot(app, "signin-answer-\(lang)")
        XCTAssertFalse(text.contains("HTTP") || text.range(of: #"\b[45]\d\d\b"#, options: .regularExpression) != nil,
                       "a raw status code reached the wall: \(text)")
        let expected = lang == "ar" ? "البريد الإلكتروني أو كلمة المرور غير صحيحة" : "That email and password don't match"
        XCTAssertTrue(text.contains(expected), "not the server's 'Invalid email or password.' answer (\(lang)): \(text)")
        assertWall(app, "after a refused sign-in \(lang)", home: true, timeout: 3)
        app.terminate()
    }

    /// A stored (local) session: Home and an editor open, no wall. In the editor, ⋯ > Account shows the account with
    /// Sign out and Delete account; Delete asks for the password and is cancelled here. Sign out: the sheet closes
    /// itself and the wall covers the editor (swipe down / Escape keep it); signed in again, the same document is back.
    /// Then Home ⋯ > Account > Delete account > Delete permanently on the LOCAL session (signed out on the device only:
    /// the app sends nothing to xrero.com for it): the wall again, saying the account was deleted. English on the
    /// iPhone, Arabic on the iPad.
    func testLocalSessionOpensHomeAndEditor_SignOutAndDeleteBringBackTheWall() {
        let lang = pad ? "ar" : "en"
        let ar = lang == "ar"
        let app = launch(["XR_TEST_SESSION": "1"], lang: lang)

        // 1) Home, no wall
        XCTAssertTrue(el(app, "xr-home-list").waitForExistence(timeout: 30), "no Home with a stored session (\(lang))")
        XCTAssertFalse(el(app, "xr-acct-wall").exists, "the wall over a signed-in Home (\(lang))")
        shot(app, "session-home-\(lang)")

        // 2) an editor: a new presentation (removed again when it is closed untouched, plan S9)
        app.buttons["xr-home-slide"].tap()
        guard let name = waitEditor(app) else { XCTFail("no editor with a stored session (\(lang))"); return }
        print("XR account session editor: \(name)")
        shot(app, "session-editor-\(lang)")

        // 3) ⋯ > Account: the account, Sign out, Delete account (asks for the password; cancelled)
        let more = app.buttons["xr-bar-more"]
        XCTAssertTrue(more.waitForExistence(timeout: 10), "no ⋯ in the editor")
        more.tap()
        let item = app.buttons["xr-nav-account"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "no Account in the editor's ⋯")
        XCTAssertEqual(item.label, ar ? "الحساب" : "Account", "the ⋯ item does not say Account when signed in")
        item.tap()
        XCTAssertTrue(el(app, "xr-acct-sheet").waitForExistence(timeout: 10), "⋯ > Account did not open (\(lang))")
        XCTAssertEqual(el(app, "xr-acct-name-shown").label, "iOS Store Check", "the signed-in name is not shown")
        let signout = app.buttons["xr-acct-signout"], delete = app.buttons["xr-acct-delete"]
        XCTAssertTrue(signout.exists, "no Sign out (\(lang))")
        XCTAssertTrue(delete.exists, "no Delete account in the app (5.1.1(v)) (\(lang))")
        shot(app, "session-account-\(lang)")
        delete.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "Delete account asked nothing (\(lang))")
        XCTAssertTrue(alert.secureTextFields.firstMatch.exists, "no password field in the Delete account alert (\(lang))")
        shot(app, "session-delete-asks-\(lang)")
        alertButton(alert, "xr-acct-delete-cancel", ar ? "إلغاء" : "Cancel").tap()
        XCTAssertTrue(waitGone(alert, 5), "the Delete account alert did not close on Cancel")
        XCTAssertTrue(signout.waitForExistence(timeout: 3), "a cancelled Delete signed out (\(lang))")

        // 4) Sign out: the sheet closes itself and the wall covers the editor
        signout.tap()
        XCTAssertTrue(waitGone(el(app, "xr-acct-sheet"), 10), "the account sheet stayed after Sign out")
        assertWall(app, "sign-out over the editor \(lang)", home: false)
        XCTAssertFalse(app.staticTexts["xr-bar-title"].exists && app.staticTexts["xr-bar-title"].isHittable,
                       "the editor is still usable under the wall")
        shot(app, "signout-wall-over-editor-\(lang)")
        app.swipeDown(velocity: .fast)
        sleep(1)
        assertWall(app, "swipe down over the editor \(lang)", home: false, timeout: 3)
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        sleep(1)
        assertWall(app, "Escape over the editor \(lang)", home: false, timeout: 3)

        // 5) signed in again: the same document, as it was
        startLocalSession(app)
        XCTAssertTrue(waitGone(el(app, "xr-acct-wall"), 15), "the wall stayed over the editor after sign-in")
        let title = app.staticTexts["xr-bar-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10), "the editor did not come back after sign-in")
        XCTAssertEqual(title.label, name, "another document after sign-in")
        shot(app, "session-editor-back-\(lang)")

        // 6) Home > ⋯ > Account > Delete account > Delete permanently (local session: nothing sent) -> the wall
        closeEditor(app)
        app.buttons["xr-home-more"].firstMatch.tap()
        let homeAccount = app.buttons["xr-home-account"].firstMatch
        XCTAssertTrue(homeAccount.waitForExistence(timeout: 5), "no Account in Home's ⋯")
        homeAccount.tap()
        let delete2 = app.buttons["xr-acct-delete"].firstMatch
        XCTAssertTrue(delete2.waitForExistence(timeout: 10), "no Delete account from Home (\(lang))")
        delete2.tap()
        let alert2 = app.alerts.firstMatch
        XCTAssertTrue(alert2.waitForExistence(timeout: 5), "Delete account asked nothing from Home (\(lang))")
        alertButton(alert2, "xr-acct-delete-confirm", ar ? "حذف نهائي" : "Delete permanently").tap()
        XCTAssertTrue(waitGone(el(app, "xr-acct-sheet"), 10), "the account sheet stayed after Delete account")
        assertWall(app, "after Delete account \(lang)", home: true)
        let notice = el(app, "xr-acct-notice")
        XCTAssertTrue(notice.waitForExistence(timeout: 10), "the wall does not say the account was deleted (\(lang))")
        print("XR account wall after delete (\(lang)): \(notice.label)")
        XCTAssertTrue(notice.label.contains(ar ? "تم حذف حسابك" : "Your account was deleted"), "notice: \(notice.label)")
        shot(app, "deleted-wall-\(lang)")
        app.terminate()
    }
}
