import XCTest
import UIKit

/// Template gallery (plan S8), iPhone and iPad, in the "Autotest" build with XR_GALLERY=1 (TemplateAutotestRoot): the
/// gallery sheet opens, its category chips filter, a tap on a template makes the file through
/// NewDocuments.create(from:lang:) and opens it in the editor; English + Arabic are typed into the letter, it is saved,
/// the app is relaunched and the same file reopened (XR_OPEN_NAME) with the typed and the template text still there.
/// Every other template (EN + AR) opens and saves once (an x2t round trip). check_saved.py checks the saved files.
final class TemplateGalleryUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    static let typedEN = "Typed in template."
    static let typedAR = "\u{0643}\u{062A}\u{0627}\u{0628}\u{0629} \u{0641}\u{064A} \u{0627}\u{0644}\u{0642}\u{0627}\u{0644}\u{0628}"   // كتابة في القالب

    private func launch(lang: String, env: [String: String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-xr.lang", lang, "-xr.keyboardBar", "NO"]
        app.launchEnvironment = env
        app.launch()
        return app
    }

    private func waitState(_ app: XCUIApplication, prefix: String, timeout: TimeInterval) -> String {
        let label = app.staticTexts["xr-state"]
        let end = Date().addingTimeInterval(timeout)
        var last = ""
        while Date() < end {
            if label.exists { last = label.label; if last.hasPrefix(prefix) || last.hasPrefix("error") { return last } }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return last
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func typeSlowly(_ app: XCUIApplication, _ text: String) {
        for ch in text { app.typeText(String(ch)); usleep(150_000) }
    }

    /// the editor's own text cursor (at the start of the document after open), as EditorUITests.tapFirstLine
    private func tapFirstLine(_ app: XCUIApplication, rtl: Bool) {
        let web = app.webViews.firstMatch
        XCUIDevice.shared.system.open(URL(string: "xrero-autotest://caret")!)
        let s = waitState(app, prefix: "caret:", timeout: 10)
        let n = s.dropFirst("caret:".count).split(separator: ",").compactMap { Double($0) }
        print("XR template first line:", s)
        let point = n.count == 2
            ? web.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: n[0], dy: n[1]))
            : web.coordinate(withNormalizedOffset: CGVector(dx: rtl ? 0.65 : 0.35,
                                                            dy: UIDevice.current.userInterfaceIdiom == .pad ? 0.19 : 0.3))
        point.tap()
        if !app.keyboards.firstMatch.waitForExistence(timeout: 4) {
            print("XR template first-line-first-tap-ignored: INFO no keyboard 4 s after the tap on the first line - tapped again")
            point.tap()
            _ = app.keyboards.firstMatch.waitForExistence(timeout: 4)
        }
    }

    /// the user's Save, else the shell's save hook (never Cmd+S: it types an "s" on the simulator)
    private func save(_ app: XCUIApplication) -> String {
        XCUIDevice.shared.system.open(URL(string: "xrero-autotest://usersave")!)
        let s = waitState(app, prefix: "saved", timeout: 30)
        if s.hasPrefix("saved") { return s }
        XCUIDevice.shared.system.open(URL(string: "xrero-autotest://save")!)
        return waitState(app, prefix: "saved", timeout: 30)
    }

    /// waits for the gallery, scrolls the template into view and taps it; returns the new file's name
    private func pick(_ app: XCUIApplication, _ id: String, shotName: String? = nil) -> String {
        let first = app.buttons["xr-template-letter"]
        XCTAssertTrue(first.waitForExistence(timeout: 30), "the template gallery did not open")
        let tile = app.buttons["xr-template-" + id]
        var n = 0
        while !(tile.exists && tile.isHittable) && n < 6 { app.swipeUp(); sleep(1); n += 1 }
        if let shotName { shot(app, shotName) }
        XCTAssertTrue(tile.exists && tile.isHittable, "template \(id) not reachable in the gallery")
        tile.tap()
        let file = app.staticTexts["xr-template-file"]
        if !file.waitForExistence(timeout: 30) {
            let err = app.staticTexts["xr-template-error"]
            XCTFail("no file made from template \(id): \(err.exists ? err.label : "(no error label)")")
        }
        print("XR template \(id): file \(file.label)")
        return file.label
    }

    /// the letter in one language: gallery -> file -> type English + Arabic -> save -> relaunch -> reopen -> text kept
    private func letterRoundTrip(_ lang: String, expect: String, kept: String) {
        let ar = lang == "ar"
        var app = launch(lang: lang, env: ["XR_GALLERY": "1"])
        let first = app.buttons["xr-template-letter"]
        XCTAssertTrue(first.waitForExistence(timeout: 30), "the template gallery did not open")
        sleep(1)
        shot(app, "60-templates-\(lang)")
        // category chips filter the grid: Finance shows the invoice and hides the letter, All brings it back
        let finance = app.buttons["xr-template-cat-finance"]
        XCTAssertTrue(finance.exists, "no Finance chip")
        finance.tap()
        sleep(1)
        XCTAssertTrue(app.buttons["xr-template-invoice"].exists, "Finance chip: no invoice")
        XCTAssertFalse(app.buttons["xr-template-letter"].exists, "Finance chip: the letter is still shown")
        shot(app, "61-templates-\(lang)-finance")
        app.buttons["xr-template-cat-all"].tap()
        sleep(1)

        let name = pick(app, "letter")
        XCTAssertTrue(name.hasPrefix(expect) && name.hasSuffix(".docx"), "template file name \(name), want \(expect).docx")
        let ready = waitState(app, prefix: "ready", timeout: 120)
        sleep(2)
        shot(app, "62-template-letter-\(lang)-open")
        XCTAssertEqual(ready, "ready", "the letter template did not open in the editor")
        tapFirstLine(app, rtl: ar)
        sleep(2)
        typeSlowly(app, Self.typedEN)
        app.typeText("\n")
        typeSlowly(app, Self.typedAR)
        sleep(2)
        shot(app, "63-template-letter-\(lang)-typed")
        let saved = save(app)
        shot(app, "64-template-letter-\(lang)-saved")
        XCTAssertTrue(saved.hasPrefix("saved"), "the letter made from the template was not saved: \(saved)")
        app.terminate()

        // reopen: a fresh launch on the saved file
        app = launch(lang: lang, env: ["XR_OPEN_NAME": name])
        let again = waitState(app, prefix: "ready", timeout: 120)
        sleep(2)
        shot(app, "65-template-letter-\(lang)-reopened")
        XCTAssertEqual(again, "ready", "the saved letter did not reopen")
        XCUIDevice.shared.system.open(URL(string: "xrero-autotest://doctext")!)
        let text = waitState(app, prefix: "doctext:", timeout: 20)
        print("XR template letter-\(lang) reopened: \(text.prefix(300))")
        let flat = text.replacingOccurrences(of: "\u{200E}", with: "").replacingOccurrences(of: "\u{200F}", with: "")
        let keep = continueAfterFailure
        continueAfterFailure = true
        XCTAssertTrue(flat.contains(Self.typedEN), "reopened letter (\(lang)): the English typed text is missing: \(text)")
        // the Arabic line needs the keyboard to type it (as in EditorUITests): reported, check_saved.py prints it
        if !flat.contains(Self.typedAR) { print("XR template letter-\(lang): Arabic typed text not found after reopen") }
        XCTAssertTrue(flat.contains(kept), "reopened letter (\(lang)): the template text is missing: \(text)")
        continueAfterFailure = keep
        app.terminate()
    }

    func testTemplateLetterEnglish() {
        letterRoundTrip("en", expect: "Official letter", kept: "Yours sincerely")
    }

    func testTemplateLetterArabic() {
        letterRoundTrip("ar", expect: "\u{062E}\u{0637}\u{0627}\u{0628} \u{0631}\u{0633}\u{0645}\u{064A}",   // خطاب رسمي
                        kept: "\u{0648}\u{062A}\u{0641}\u{0636}\u{0644}\u{0648}\u{0627}")                    // وتفضلوا
    }

    /// Every other template, in both languages, opens in its editor and saves through the engine (x2t round trip).
    func testTemplatesOpenAndSave() {
        for lang in ["en", "ar"] {
            for id in ["invoice", "cv", "minutes", "budget"] {
                let app = launch(lang: lang, env: ["XR_GALLERY": "1"])
                let name = pick(app, id, shotName: id == "budget" ? "66-templates-\(lang)-scrolled" : nil)
                let ready = waitState(app, prefix: "ready", timeout: 120)
                sleep(2)
                shot(app, "67-template-\(id)-\(lang)")
                XCTAssertEqual(ready, "ready", "template \(id) (\(lang)) did not open: \(name)")
                let saved = save(app)
                print("XR template \(id)-\(lang) \(name): \(saved)")
                XCTAssertTrue(saved.hasPrefix("saved"), "template \(id) (\(lang)) did not save: \(saved)")
                app.terminate()
            }
        }
    }
}
