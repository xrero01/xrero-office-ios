import XCTest

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

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// New Word document -> type English + Arabic -> save.
    func testWordTypeEnglishArabicAndSave() {
        let app = launch(["XR_KIND": "word"])
        let ready = waitState(app, prefix: "ready", timeout: 120)
        shot(app, "01-word-ready")
        XCTAssertEqual(ready, "ready", "editor did not become ready")

        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 10))
        web.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        sleep(2)
        app.typeText("Typed on iPhone - English OK. ")
        app.typeText("\n")
        app.typeText("\u{0643}\u{062A}\u{0627}\u{0628}\u{0629} \u{0639}\u{0631}\u{0628}\u{064A}\u{0629}")   // كتابة عربية
        sleep(2)
        shot(app, "02-word-typed")

        app.buttons["xr-save"].tap()
        let saved = waitState(app, prefix: "saved", timeout: 60)
        shot(app, "03-word-saved")
        XCTAssertTrue(saved.hasPrefix("saved"), "save did not complete: \(saved)")
    }

    /// Opens the Arabic sample passed by the workflow (XR_DOC_*) and saves it unchanged.
    func testOpenArabicSampleAndSave() throws {
        guard let b64 = ProcessInfo.processInfo.environment["XR_SAMPLE_B64"],
              let name = ProcessInfo.processInfo.environment["XR_SAMPLE_NAME"] else {
            throw XCTSkip("no sample passed")
        }
        let app = launch(["XR_DOC_B64": b64, "XR_DOC_NAME": name])
        let ready = waitState(app, prefix: "ready", timeout: 120)
        sleep(3)
        shot(app, "10-sample-" + name)
        XCTAssertEqual(ready, "ready", "sample did not open")
        app.buttons["xr-save"].tap()
        let saved = waitState(app, prefix: "saved", timeout: 60)
        XCTAssertTrue(saved.hasPrefix("saved"), "sample save failed: \(saved)")
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
