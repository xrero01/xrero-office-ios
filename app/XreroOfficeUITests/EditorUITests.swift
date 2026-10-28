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

    /// A ribbon button of the Home tab by its exact name ("Copy", not "Copy style"). On a phone the ribbon is folded:
    /// the Home tab drops its panel first (and folds it again after a command).
    private func tapRibbon(_ app: XCUIApplication, _ name: String) -> Bool {
        let pred = NSPredicate(format: "label == %@ OR label BEGINSWITH %@", name, name + " (")
        for attempt in 0..<3 {
            let b = app.webViews.buttons.matching(pred).firstMatch
            if b.exists && b.isHittable { b.tap(); return true }
            if attempt == 2 { break }
            let home = app.webViews.descendants(matching: .any).matching(NSPredicate(format: "label == 'Home'")).firstMatch
            if home.exists { home.tap() }
            sleep(1)
        }
        print("XR ribbon: no hittable '\(name)' - web buttons:", app.webViews.buttons.allElementsBoundByIndex.prefix(40).map { $0.label })
        return false
    }

    /// iOS asks before an app reads text another app put on the pasteboard; answer it if it shows.
    private func allowPasteIfAsked(_ app: XCUIApplication) {
        let allow = app.buttons["Allow Paste"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }
    }

    /// Clipboard (20.2 M2): the ribbon's Copy + Paste round-trip mixed English/Arabic text (Xrero's own copy,
    /// full formatting), then Paste brings in plain text another app put on the pasteboard. check_saved.py reads
    /// xr-clip.docx: "Hello مرحبا" twice (typed once + pasted) and the outside text once.
    func testClipboardCopyPasteAndSave() {
        let app = launch(["XR_KIND": "word", "XR_NEW_NAME": "xr-clip.docx"])
        let ready = waitState(app, prefix: "ready", timeout: 120)
        XCTAssertEqual(ready, "ready", "editor did not become ready")
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 10))
        web.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: UIDevice.current.userInterfaceIdiom == .pad ? 0.19 : 0.3)).tap()
        sleep(2)
        typeSlowly(app, "Hello \u{0645}\u{0631}\u{062D}\u{0628}\u{0627}")      // Hello مرحبا
        sleep(1)

        XCUIDevice.shared.system.open(URL(string: "xrero-autotest://selectall")!)
        sleep(2)
        XCTAssertTrue(tapRibbon(app, "Copy"), "ribbon Copy button not found")
        sleep(2)
        shot(app, "40-clip-copied")
        // the first Paste replaces the selection with the copy, the second one adds it after: two in the file
        XCTAssertTrue(tapRibbon(app, "Paste"), "ribbon Paste button not found")
        allowPasteIfAsked(app)
        sleep(2)
        XCTAssertTrue(tapRibbon(app, "Paste"), "ribbon Paste button not found (2nd)")
        allowPasteIfAsked(app)
        sleep(2)
        shot(app, "41-clip-pasted")

        // text from "another app": arrives as plain text
        let outside = "Outside text 42"
        XCUIDevice.shared.system.open(URL(string: "xrero-autotest://pbset?t=" + outside.replacingOccurrences(of: " ", with: "%20"))!)
        sleep(2)
        XCTAssertTrue(tapRibbon(app, "Paste"), "ribbon Paste button not found (outside text)")
        allowPasteIfAsked(app)
        sleep(2)
        shot(app, "42-clip-outside-pasted")

        let saved = save(app)
        shot(app, "43-clip-saved")
        XCTAssertTrue(saved.hasPrefix("saved"), "clipboard document save failed: \(saved)")
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
