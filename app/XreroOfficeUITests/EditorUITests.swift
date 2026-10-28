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

    /// Swipes until `e` is on screen (lists are lazy: rows below the fold are not in the tree yet).
    private func reveal(_ app: XCUIApplication, _ e: XCUIElement, up: Bool = true) -> Bool {
        for _ in 0..<6 {
            if e.exists && e.isHittable { return true }
            if up { app.swipeUp() } else { app.swipeDown() }
            usleep(600_000)
        }
        return e.exists && e.isHittable
    }

    /// About & Licences (M13) opened over the editor: version, the AGPL source link, the ONLYOFFICE attribution, the
    /// third-party notices and licence texts of Settings.bundle, the Microsoft trademark notice; closing it
    /// leaves the editor as it was. Then the same screen in Arabic (mirrored).
    func testAboutAndLicences() {
        for lang in ["en", "ar"] {
            let app = XCUIApplication()
            app.launchEnvironment = ["XR_KIND": "cell"]       // not xr-test.docx: that file belongs to the typing test
            app.launchArguments = ["-xr.lang", lang]          // the interface language (UserDefaults argument domain)
            app.launch()
            let ready = waitState(app, prefix: "ready", timeout: 120)
            XCTAssertEqual(ready, "ready", "editor did not become ready (\(lang))")
            XCUIDevice.shared.system.open(URL(string: "xrero-autotest://about")!)

            let version = app.staticTexts["xr-about-version"]
            XCTAssertTrue(version.waitForExistence(timeout: 20), "About did not open (\(lang))")
            sleep(1)
            shot(app, "40-about-\(lang)")
            print("XR about \(lang): version=\(version.label)")
            XCTAssertNotNil(version.label.range(of: #"\d+\.\d+ \(\d+\)"#, options: .regularExpression), "no version/build: \(version.label)")
            let source = app.descendants(matching: .any)["xr-about-source"]
            XCTAssertTrue(source.exists, "no source code link (\(lang))")
            print("XR about \(lang): source=\(source.label)")      // the link + the commit of this build
            XCTAssertTrue(app.staticTexts["xr-about-agpl"].label.contains("AGPL-3.0"), "no AGPL notice (\(lang))")
            let engine = app.staticTexts["xr-about-onlyoffice"]
            XCTAssertTrue(reveal(app, engine), "no ONLYOFFICE attribution (\(lang))")
            XCTAssertTrue(engine.label.contains("ONLYOFFICE") && engine.label.contains("Ascensio System SIA"), engine.label)
            let marks = app.staticTexts["xr-about-trademarks"]
            XCTAssertTrue(reveal(app, marks), "no trademark notice (\(lang))")
            XCTAssertTrue(marks.label.contains("Microsoft"), marks.label)
            shot(app, "41-about-\(lang)-licences")

            if lang == "en" {
                // the notices page: Settings.bundle's Licences entries (app, editors, converter, every font)
                let notices = app.descendants(matching: .any)["xr-about-notices"]
                XCTAssertTrue(reveal(app, notices, up: false), "no notices row")
                notices.tap()
                let onlyoffice = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'ONLYOFFICE Docs editors'")).firstMatch
                XCTAssertTrue(onlyoffice.waitForExistence(timeout: 10), "notices not loaded from Settings.bundle")
                let count = app.descendants(matching: .any).matching(identifier: "xr-notice").count
                print("XR about notices visible:", count)
                XCTAssertGreaterThanOrEqual(count, 3)
                shot(app, "42-about-notices")
                app.swipeUp(); usleep(800_000)
                XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Font: '")).firstMatch.exists,
                              "no font notices")
                shot(app, "43-about-notices-fonts")
                app.navigationBars.buttons.element(boundBy: 0).tap()
                sleep(1)

                // the full AGPL text
                let agpl = app.descendants(matching: .any)["xr-about-licence-AGPL"]
                XCTAssertTrue(reveal(app, agpl), "no AGPL licence row")
                agpl.tap()
                let title = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'AFFERO GENERAL PUBLIC LICENSE'")).firstMatch
                XCTAssertTrue(title.waitForExistence(timeout: 10), "AGPL text not shown")
                shot(app, "44-about-agpl-text")
                app.navigationBars.buttons.element(boundBy: 0).tap()
                sleep(1)
            }

            app.buttons["xr-about-done"].tap()
            for _ in 0..<20 where version.exists { usleep(500_000) }
            XCTAssertFalse(version.exists, "About did not close (\(lang))")
            XCTAssertEqual(app.staticTexts["xr-state"].label, "ready", "editor state changed under About (\(lang))")
            shot(app, "45-about-\(lang)-closed")
            app.terminate()
        }
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
