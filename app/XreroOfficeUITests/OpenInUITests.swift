import XCTest

/// Plan S11: a file handed over by another app, on the REAL document path (XR_REAL=1: DocumentOpener.openExternal,
/// UIDocument, the app's own editor screen), English and Arabic interface and file names.
///  - copy (Mail / WhatsApp / share sheet): the system's copy in the Inbox is moved into the app's folder under its
///    clean name (never over an existing file of that name), the editor says "Editing a copy saved in Xrero Office"
///    with Show in Files on the first edit, the save lands in that copy, Recent points at it, and reopening it from
///    Recent edits the same copy with no second notice.
///  - in place (Files): the original is edited, no notice, nothing appears in the app's folder.
/// scripts/check_saved.py open_in() then reads where the saved bytes landed.
final class OpenInUITests: XCTestCase {
    struct Run { let lang, mode, file, expect: String; let clash: Bool; let words: [String] }

    func testOpenInCopyAndInPlace() {
        continueAfterFailure = true                        // every run still reports when one fails
        let runs = [
            Run(lang: "en", mode: "copy", file: "Quarterly report.docx", expect: "Quarterly report 2", clash: true,
                words: ["Kappa", " Rho"]),
            Run(lang: "ar", mode: "copy", file: "\u{062A}\u{0642}\u{0631}\u{064A}\u{0631} \u{0627}\u{0644}\u{0631}\u{0628}\u{0639}.docx",   // تقرير الربع
                expect: "\u{062A}\u{0642}\u{0631}\u{064A}\u{0631} \u{0627}\u{0644}\u{0631}\u{0628}\u{0639}", clash: false,
                words: ["Lambda", " Tau"]),
            Run(lang: "en", mode: "inplace", file: "Field notes.docx", expect: "Field notes", clash: false, words: ["Mu"]),
            Run(lang: "ar", mode: "inplace", file: "\u{0645}\u{0644}\u{0627}\u{062D}\u{0638}\u{0627}\u{062A} \u{0627}\u{0644}\u{0645}\u{0648}\u{0642}\u{0639}.docx",   // ملاحظات الموقع
                expect: "\u{0645}\u{0644}\u{0627}\u{062D}\u{0638}\u{0627}\u{062A} \u{0627}\u{0644}\u{0645}\u{0648}\u{0642}\u{0639}", clash: false,
                words: ["Nu"]),
        ]
        for run in runs { one(run) }
    }

    private func one(_ run: Run) {
        let ar = run.lang == "ar"
        let tag = "\(run.mode)-\(run.lang)"
        let app = XCUIApplication()
        app.launchArguments = ["-xr.lang", run.lang]
        var env = ["XR_REAL": "1", "XR_INCOMING": run.file, "XR_INCOMING_MODE": run.mode]
        if run.clash { env["XR_INCOMING_CLASH"] = "1" }
        app.launchEnvironment = env
        app.launch()
        defer { app.terminate() }
        let title = app.staticTexts["xr-bar-title"], status = app.staticTexts["xr-bar-status"]
        func statusNow() -> String { (try? status.firstMatch.snapshot())?.label ?? "(none)" }
        func titleNow() -> String { (try? title.firstMatch.snapshot())?.label ?? "(none)" }
        let notice = app.descendants(matching: .any).matching(identifier: "xr-copy-notice-text").firstMatch

        func waitEditor(_ what: String) -> Bool {
            let end = Date().addingTimeInterval(120)
            while Date() < end {
                let s = statusNow()
                if title.exists && !s.hasPrefix("Opening") && !s.hasPrefix("جارٍ الفتح") { sleep(3); return true }
                Thread.sleep(forTimeInterval: 0.5)
            }
            shot(app, "70-openin-\(tag)-\(what)-not-ready")
            return false
        }
        func typeInPage(_ text: String) {
            let web = app.webViews.firstMatch
            let point = web.coordinate(withNormalizedOffset: CGVector(dx: ar ? 0.65 : 0.35, dy: 0.45))
            point.tap()
            if !app.keyboards.firstMatch.waitForExistence(timeout: 4) { point.tap(); _ = app.keyboards.firstMatch.waitForExistence(timeout: 4) }
            sleep(1)
            for ch in text { app.typeText(String(ch)); usleep(150_000) }
            sleep(1)
        }
        func saveNow(_ what: String) -> Bool {
            app.buttons["xr-bar-more"].tap()
            let save = app.buttons["xr-bar-save"]
            guard save.waitForExistence(timeout: 5) else { XCTFail("no Save in ⋯ (\(tag) \(what))"); return false }
            save.tap()
            let want = ar ? "محفوظ" : "Saved"
            let end = Date().addingTimeInterval(40)
            while Date() < end { if statusNow() == want { return true }; Thread.sleep(forTimeInterval: 0.3) }
            return false
        }

        guard waitEditor("opened") else {
            XCTFail("the editor did not open the incoming file (\(tag)): \((try? app.staticTexts["xr-state"].snapshot())?.label ?? "?")")
            return
        }
        print("XR open-in \(tag): title = \(titleNow())")
        XCTAssertEqual(titleNow(), run.expect, "title of the incoming file (\(tag))")
        XCTAssertFalse(notice.exists, "the copy notice showed before any edit (\(tag))")
        shot(app, "71-openin-\(tag)-opened")

        // first edit: a copy says so (and where it is) at once; an original says nothing
        typeInPage(run.words[0])
        if run.mode == "copy" {
            let shown = notice.waitForExistence(timeout: 20)
            XCTAssertTrue(shown, "no copy notice on the first edit (\(tag))")
            // read at once, from snapshots: the notice leaves by itself after a few seconds
            let button = app.buttons["xr-copy-show"].exists
            let text = (try? notice.snapshot())?.label ?? "-"
            let place = (try? app.descendants(matching: .any).matching(identifier: "xr-copy-notice-place").firstMatch.snapshot())?.label ?? "-"
            print("XR open-in \(tag): notice = \(text) | \(place) | show-in-files=\(button)")
            if shown {
                XCTAssertTrue(text.contains(ar ? "نسخة" : "copy"), "the notice does not say it is a copy (\(tag)): \(text)")
                XCTAssertTrue(text.contains("Xrero Office"), "the notice does not say where the copy is (\(tag)): \(text)")
                XCTAssertTrue(button, "no Show in Files on the notice (\(tag))")
            }
            shot(app, "72-openin-\(tag)-notice")
        } else {
            sleep(4)
            print("XR open-in \(tag): notice shown = \(notice.exists)")
            XCTAssertFalse(notice.exists, "a file opened in place showed the copy notice (\(tag))")
            shot(app, "72-openin-\(tag)-no-notice")
        }
        XCTAssertTrue(saveNow("first"), "save did not say Saved (\(tag)): \(statusNow())")

        // back to the list: Recent points at the file that was edited (the copy in the app's folder, or the original)
        app.buttons["xr-bar-back"].tap()
        let reopen = app.buttons["xr-real-reopen"]
        XCTAssertTrue(reopen.waitForExistence(timeout: 30), "the editor did not close (\(tag))")
        sleep(2)
        let recent = app.staticTexts["xr-real-recent"]
        print("XR open-in \(tag): recent = \(recent.label)")
        XCTAssertEqual(recent.label, run.expect + ".docx", "Recent does not show the edited file (\(tag))")
        guard run.words.count > 1 else { return }

        // the copy reopened from Recent: same file, edited again, no second notice (one time)
        reopen.tap()
        guard waitEditor("reopened") else { XCTFail("the copy did not reopen from Recent (\(tag))"); return }
        XCTAssertEqual(titleNow(), run.expect, "title after reopening (\(tag))")
        typeInPage(run.words[1])
        sleep(3)
        print("XR open-in \(tag): notice after reopen = \(notice.exists)")
        XCTAssertFalse(notice.exists, "the copy notice showed again after reopening from Recent (\(tag))")
        XCTAssertTrue(saveNow("reopened"), "save after reopening did not say Saved (\(tag)): \(statusNow())")
        shot(app, "73-openin-\(tag)-reopened-saved")
        app.buttons["xr-bar-back"].tap()
        XCTAssertTrue(reopen.waitForExistence(timeout: 30), "the editor did not close after reopening (\(tag))")
        sleep(2)
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
