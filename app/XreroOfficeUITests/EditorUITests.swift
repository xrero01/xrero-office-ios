import XCTest
import UIKit

/// Real-keyboard editor tests on the simulator (app built in the "Autotest" configuration).
/// The workflow then pulls Documents/<file> out of the simulator and checks the saved file's contents.
final class EditorUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private func launch(_ env: [String: String]) -> XCUIApplication {
        let app = XCUIApplication()
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

    /// Human pace: one character at a time (a burst from XCUITest is far faster than any person types).
    private func typeSlowly(_ app: XCUIApplication, _ text: String) {
        for ch in text { app.typeText(String(ch)); usleep(150_000) }
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// Save the way a user does: the editor's own Save button; then Cmd+S; then the test hook.
    private func save(_ app: XCUIApplication) -> String {
        let labels = app.webViews.buttons.allElementsBoundByIndex.prefix(25).map { $0.label }
        print("XR web buttons:", labels)
        let button = app.webViews.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'Save' OR label BEGINSWITH 'حفظ'")).firstMatch
        if button.exists && button.isHittable {
            button.tap()
            let s = waitState(app, prefix: "saved", timeout: 30)
            if s.hasPrefix("saved") { print("XR save path: Save button"); return s }
        }
        app.typeKey("s", modifierFlags: .command)
        let s2 = waitState(app, prefix: "saved", timeout: 20)
        if s2.hasPrefix("saved") { print("XR save path: Cmd+S"); return s2 }
        XCUIDevice.shared.system.open(URL(string: "xrero-autotest://save")!)   // routed to the running app, no tapping
        let s3 = waitState(app, prefix: "saved", timeout: 30)
        if s3.hasPrefix("saved") { print("XR save path: test URL") }
        return s3
    }

    /// New Word document -> type English + Arabic -> save.
    func testWordTypeEnglishArabicAndSave() {
        let app = launch(["XR_KIND": "word"])
        let ready = waitState(app, prefix: "ready", timeout: 120)
        shot(app, "01-word-ready")
        XCTAssertEqual(ready, "ready", "editor did not become ready")

        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 10))
        // the first line of the new page (on an iPad the page's empty middle is far below the only paragraph)
        web.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: UIDevice.current.userInterfaceIdiom == .pad ? 0.19 : 0.3)).tap()
        sleep(2)
        typeSlowly(app, "Typed on iPhone - English OK.")
        app.typeText("\n")
        typeSlowly(app, "\u{0643}\u{062A}\u{0627}\u{0628}\u{0629} \u{0639}\u{0631}\u{0628}\u{064A}\u{0629}")   // كتابة عربية
        sleep(2)
        shot(app, "02-word-typed")

        let saved = save(app)
        shot(app, "03-word-saved")
        XCTAssertTrue(saved.hasPrefix("saved"), "save did not complete: \(saved)")
    }

    /// Arabic-first blanks (plan M10): with the app in Arabic, a new document / spreadsheet / presentation comes from
    /// Xrero's right-to-left templates. The document gets Arabic typed into it; all three are saved through the engine
    /// (x2t) as xr-test-ar.*, and check_saved.py asserts the saved files are still right-to-left with the text kept.
    /// "-xr.lang ar" goes to the launch arguments (argument domain): AppLanguage reads it for this launch only and
    /// nothing is persisted, so the English typing test that follows still gets the English blank.
    func testArabicBlanksStartRightToLeft() {
        for kind in ["word", "cell", "slide"] {
            let app = XCUIApplication()
            app.launchArguments = ["-xr.lang", "ar"]
            app.launchEnvironment = ["XR_KIND": kind,
                                     "XR_DOC_NAME": "xr-test-ar." + ["word": "docx", "cell": "xlsx", "slide": "pptx"][kind]!]
            app.launch()
            let ready = waitState(app, prefix: "ready", timeout: 120)
            sleep(2)
            shot(app, "40-ar-" + kind + "-ready")
            XCTAssertEqual(ready, "ready", "Arabic blank \(kind) did not open")
            if kind == "word" {
                // the only paragraph is right-to-left: it starts at the right edge, so tap the right half of line 1
                app.webViews.firstMatch.coordinate(withNormalizedOffset: CGVector(
                    dx: 0.65, dy: UIDevice.current.userInterfaceIdiom == .pad ? 0.19 : 0.3)).tap()
                sleep(2)
                typeSlowly(app, "\u{0645}\u{0631}\u{062D}\u{0628}\u{0627}")      // مرحبا
                sleep(2)
                shot(app, "41-ar-word-typed")
            }
            let saved = save(app)
            shot(app, "42-ar-" + kind + "-saved")
            XCTAssertTrue(saved.hasPrefix("saved"), "Arabic blank \(kind) save failed: \(saved)")
            app.terminate()
        }
    }

    /// Opens the Arabic sample passed by the workflow, adds a word, saves it.
    func testOpenArabicSampleAndSave() throws {
        guard let b64 = ProcessInfo.processInfo.environment["XR_SAMPLE_B64"],
              let name = ProcessInfo.processInfo.environment["XR_SAMPLE_NAME"] else {
            throw XCTSkip("no sample passed")
        }
        let app = launch(["XR_DOC_B64": b64, "XR_DOC_NAME": name])
        let ready = waitState(app, prefix: "ready", timeout: 120)
        sleep(3)
        shot(app, "10-sample-opened")
        XCTAssertEqual(ready, "ready", "sample did not open")
        app.webViews.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()   // inside the letter's text
        sleep(2)
        typeSlowly(app, " \u{062A}\u{0645}")     // " تم"
        sleep(1)
        shot(app, "10b-sample-typed")
        sleep(1)
        let saved = save(app)
        shot(app, "11-sample-saved")
        XCTAssertTrue(saved.hasPrefix("saved"), "sample save failed: \(saved)")
    }

    /// App Store screenshots: each sample from XR_STORE_SET ("name|lang|base64;...") opened in that UI language
    /// (portrait: XCUITest's landscape screenshots come out rotated/cropped on the iPad simulator).
    func testStoreScreenshots() throws {
        guard let set = ProcessInfo.processInfo.environment["XR_STORE_SET"], !set.isEmpty else { throw XCTSkip("no store set") }
        XCUIDevice.shared.orientation = .portrait
        for item in set.split(separator: ";") {
            let p = item.split(separator: "|", maxSplits: 2).map(String.init)
            guard p.count == 3 else { continue }
            let app = launch(["XR_DOC_NAME": p[0], "XR_LANG": p[1], "XR_DOC_B64": p[2]])
            let ready = waitState(app, prefix: "ready", timeout: 120)
            sleep(5)
            shot(app, "store-\(p[1])-\(p[0])")
            XCTAssertEqual(ready, "ready", "\(p[0]) did not open")
            app.terminate()
        }
    }

    /// PDF: opens in the PDF editor, gets edited (rotate page 1, add a page, add a free-text box), saves as PDF
    /// (x2t applies the editor's changes to the original); the workflow checks the saved file.
    func testPdfOpenEditSave() throws {
        guard let b64 = ProcessInfo.processInfo.environment["XR_PDF_B64"] else { throw XCTSkip("no pdf passed") }
        let app = launch(["XR_DOC_B64": b64, "XR_DOC_NAME": "ar_letter.pdf"])
        let ready = waitState(app, prefix: "ready", timeout: 120)
        sleep(3)
        shot(app, "30-pdf-opened")
        XCTAssertEqual(ready, "ready", "pdf did not open")
        XCUIDevice.shared.system.open(URL(string: "xrero-autotest://pdfedit")!)
        sleep(5)
        shot(app, "31-pdf-edited")
        let saved = save(app)
        shot(app, "32-pdf-saved")
        XCTAssertTrue(saved.hasPrefix("saved"), "pdf save failed: \(saved)")
    }

    /// New spreadsheet and presentation open in their editors.
    func testSpreadsheetAndPresentationOpen() {
        for kind in ["cell", "slide"] {
            let app = launch(["XR_KIND": kind])
            let ready = waitState(app, prefix: "ready", timeout: 120)
            sleep(2)
            shot(app, "20-" + kind + "-ready")
            XCTAssertEqual(ready, "ready", "\(kind) editor did not become ready")
            app.terminate()
        }
    }
}
