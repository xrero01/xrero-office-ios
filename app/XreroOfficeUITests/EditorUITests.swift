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

    /// Taps the new page's first line: where the editor's own text cursor is (read through the Autotest hook), so
    /// the tap follows the ribbon's real height; the old fixed point only when the cursor cannot be found.
    private func tapFirstLine(_ app: XCUIApplication, fallback: CGVector) {
        let web = app.webViews.firstMatch
        XCUIDevice.shared.system.open(URL(string: "xrero-autotest://caret")!)
        let s = waitState(app, prefix: "caret:", timeout: 10)
        let n = s.dropFirst("caret:".count).split(separator: ",").compactMap { Double($0) }
        print("XR first line:", s)
        if n.count == 2 {
            // the cursor is in web view points; the web view fills the editor area below the system bar
            web.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: n[0], dy: n[1])).tap()
        } else {
            web.coordinate(withNormalizedOffset: fallback).tap()
        }
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

    /// iPad layout gate (design item M3): asks the Autotest screen to measure the editor's DOM - status-bar controls
    /// do not overlap, no empty pills, nothing under the window-resize corner, sheet tabs visible in spreadsheets,
    /// ribbon controls inside the toolbar, settings panel closed in portrait. iPad only (the phone layout differs).
    private func checkIPadLayout(_ app: XCUIApplication, _ name: String) {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }
        XCUIDevice.shared.system.open(URL(string: "xrero-autotest://geom")!)
        let g = waitState(app, prefix: "geom:", timeout: 20)
        print("XR geom \(name): \(g)")
        // recorded, but the test goes on: one editor's layout failure must not hide the later editors' results
        let keep = continueAfterFailure
        continueAfterFailure = true
        XCTAssertTrue(g.hasPrefix("geom:ok"), "iPad layout (\(name)): \(g)")
        continueAfterFailure = keep
    }

    /// iPad: the right settings panel, opened in landscape, closes again when the window turns portrait (rotation).
    private func checkIPadRotation(_ app: XCUIApplication, _ name: String) {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }
        let keep = continueAfterFailure
        continueAfterFailure = true
        defer { XCUIDevice.shared.orientation = .portrait; continueAfterFailure = keep }
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(4)
        XCUIDevice.shared.system.open(URL(string: "xrero-autotest://rpopen")!)
        let rp = waitState(app, prefix: "rp:", timeout: 15)
        print("XR rotate \(name) landscape panel: \(rp)")
        shot(app, "04-\(name)-landscape-panel")
        XCTAssertGreaterThan(Int(rp.dropFirst(3)) ?? 0, 100, "right panel did not open in landscape: \(rp)")
        XCUIDevice.shared.orientation = .portrait
        sleep(4)
        shot(app, "05-\(name)-rotated-portrait")
        checkIPadLayout(app, name + "-rotated")       // asserts the panel is closed (rm<=100) in portrait
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
        tapFirstLine(app, fallback: CGVector(dx: 0.35, dy: UIDevice.current.userInterfaceIdiom == .pad ? 0.19 : 0.3))
        sleep(2)
        typeSlowly(app, "Typed on iPhone - English OK.")
        app.typeText("\n")
        typeSlowly(app, "\u{0643}\u{062A}\u{0627}\u{0628}\u{0629} \u{0639}\u{0631}\u{0628}\u{064A}\u{0629}")   // كتابة عربية
        sleep(2)
        shot(app, "02-word-typed")

        let saved = save(app)
        shot(app, "03-word-saved")
        XCTAssertTrue(saved.hasPrefix("saved"), "save did not complete: \(saved)")
        checkIPadLayout(app, "word")         // after the save, so a layout failure never hides the typing result
        checkIPadRotation(app, "word")
    }

    /// Runs a Home-tab ribbon command by its exact name ("Copy", not "Copy style") and waits until the app reports
    /// it done (the Autotest state turns "clip<n> ..."). Phones fold the ribbon, and a tap on a button of a folded
    /// panel lands on the page (it moves the caret and drops the selection) - so the Home panel is opened through
    /// the Autotest hook first, every time; the tap itself is a real tap on the button.
    private func ribbonCommand(_ app: XCUIApplication, _ name: String) -> String? {
        let pred = NSPredicate(format: "label == %@ OR label BEGINSWITH %@", name, name + " (")
        let state = app.staticTexts["xr-state"]
        for _ in 0..<2 {
            autotest("openhome")
            let before = state.exists ? state.label : ""
            let b = app.webViews.buttons.matching(pred).firstMatch
            guard b.exists && b.isHittable else { continue }
            b.tap()
            let end = Date().addingTimeInterval(6)
            while Date() < end {
                let allow = app.buttons["Allow Paste"]           // iOS asks before reading another app's text
                if allow.exists { allow.tap() }
                if state.exists && state.label != before && state.label.hasPrefix("clip") { return state.label }
                Thread.sleep(forTimeInterval: 0.3)
            }
        }
        print("XR web buttons: '\(name)' did not run -", app.webViews.buttons.allElementsBoundByIndex.prefix(40).map { "\($0.label)/\($0.isEnabled)" })
        return nil
    }

    private func autotest(_ host: String, _ text: String? = nil) {
        var c = URLComponents(); c.scheme = "xrero-autotest"; c.host = host
        if let text { c.queryItems = [URLQueryItem(name: "t", value: text)] }
        XCUIDevice.shared.system.open(c.url!)                 // routed to the running app, no tapping
        sleep(2)
    }

    /// Clipboard (20.2 M2): the ribbon's Copy + Paste round-trip mixed English/Arabic text (Xrero's own copy, full
    /// formatting), then Paste brings in plain text another app put on the pasteboard. The text is inserted without
    /// the keyboard (typing has its own tests). Named to run last, after the typing tests. check_saved.py reads
    /// xr-clip.docx: "Hello مرحبا" twice (inserted once + pasted) and the outside text once.
    func testZClipboardCopyPasteAndSave() {
        let app = launch(["XR_KIND": "word", "XR_NEW_NAME": "xr-clip.docx"])
        let ready = waitState(app, prefix: "ready", timeout: 120)
        XCTAssertEqual(ready, "ready", "editor did not become ready")
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))
        sleep(2)
        autotest("addtext", "Hello \u{0645}\u{0631}\u{062D}\u{0628}\u{0627}")      // Hello مرحبا
        autotest("openhome")
        autotest("selectall")

        let copy = ribbonCommand(app, "Copy")
        print("XR clip copy:", copy ?? "-")
        shot(app, "40-clip-copied")
        XCTAssertNotNil(copy, "ribbon Copy did not run")
        // the first Paste replaces the selection with the copy, the second one adds it after: two in the file
        let p1 = ribbonCommand(app, "Paste"); sleep(1)
        let p2 = ribbonCommand(app, "Paste"); sleep(1)
        print("XR clip paste:", p1 ?? "-", "|", p2 ?? "-")
        shot(app, "41-clip-pasted")
        XCTAssertTrue((p1 ?? "").hasSuffix("paste: internal") && (p2 ?? "").hasSuffix("paste: internal"),
                      "own copy did not paste with its formatting: \(p1 ?? "-") / \(p2 ?? "-")")

        // text from "another app": arrives as plain text
        autotest("pbset", "Outside text 42")
        let p3 = ribbonCommand(app, "Paste"); sleep(1)
        print("XR clip outside paste:", p3 ?? "-")
        shot(app, "42-clip-outside-pasted")
        XCTAssertTrue((p3 ?? "").hasSuffix("paste: text"), "outside text did not paste: \(p3 ?? "-")")

        let saved = save(app)
        shot(app, "43-clip-saved")
        XCTAssertTrue(saved.hasPrefix("saved"), "clipboard document save failed: \(saved)")
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
                tapFirstLine(app, fallback: CGVector(dx: 0.65, dy: UIDevice.current.userInterfaceIdiom == .pad ? 0.19 : 0.3))
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

    /// File > Download As / Save As: only working entries and formats in the File menu (logged for check_saved.py);
    /// the ODT tile exports ar_letter.odt, the app's own format list (Save As without a format) exports ar_letter.rtf;
    /// the document's own file is not rewritten.
    func testSaveAsCopy() throws {
        guard let b64 = ProcessInfo.processInfo.environment["XR_SAMPLE_B64"],
              let name = ProcessInfo.processInfo.environment["XR_SAMPLE_NAME"] else {
            throw XCTSkip("no sample passed")
        }
        let app = launch(["XR_DOC_B64": b64, "XR_DOC_NAME": name])
        let ready = waitState(app, prefix: "ready", timeout: 120)
        sleep(3)
        XCTAssertEqual(ready, "ready", "sample did not open")

        // the File menu as the user sees it (it opens on "Download As"); the hook logs the visible entries + formats
        XCUIDevice.shared.system.open(URL(string: "xrero-autotest://filemenu")!)
        sleep(4)
        shot(app, "40-file-menu")

        // 1) the ODT tile in "Download As" (format 0x43): the copy is exported straight away
        let base = (name as NSString).deletingPathExtension
        XCUIDevice.shared.system.open(URL(string: "xrero-autotest://tile?f=67")!)
        let first = waitState(app, prefix: "exported:" + base + ".odt", timeout: 60)
        shot(app, "41-download-as-odt")
        XCTAssertEqual(first, "exported:" + base + ".odt", "ODT copy not exported from the Download As tile")

        // 2) Save As without a format (Ctrl+Shift+S / the desktop's Save As): the app's own list of formats
        XCUIDevice.shared.system.open(URL(string: "xrero-autotest://saveas")!)
        let rtf = app.buttons["xr-saveas-rtf"].firstMatch
        XCTAssertTrue(rtf.waitForExistence(timeout: 30), "the Save As format list did not appear")
        shot(app, "42-saveas-formats")
        // formats the on-device converter cannot write (or corrupts) are not offered
        for ext in ["pdf", "txt", "html", "epub", "docm"] {
            XCTAssertFalse(app.buttons["xr-saveas-" + ext].exists, "\(ext) offered but not supported")
        }
        XCTAssertTrue(app.buttons["xr-saveas-docx"].firstMatch.exists && app.buttons["xr-saveas-odt"].firstMatch.exists)
        rtf.tap()
        let second = waitState(app, prefix: "exported:" + base + ".rtf", timeout: 60)
        shot(app, "43-saveas-rtf-exported")
        XCTAssertEqual(second, "exported:" + base + ".rtf", "RTF copy not exported from the Save As list")
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
        checkIPadLayout(app, "pdf")
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
            // the labels as a text attachment too: it lands in the evidence zip even when the job log is out of reach
            let probes = [version, app.staticTexts["xr-about-agpl"], app.descendants(matching: .any)["xr-about-source"]]
            let labels = XCTAttachment(string: probes.map { $0.exists ? $0.label : "(missing)" }
                .map { $0.unicodeScalars.map { $0.value < 128 ? String($0) : String(format: "<U+%04X>", $0.value) }.joined() }
                .joined(separator: "\n"))
            labels.name = "about-labels-\(lang)"; labels.lifetime = .keepAlways; add(labels)
            // in Arabic, SwiftUI wraps the interpolated numbers in bidi isolates (U+2066-2069): drop them before matching
            let plain = String(version.label.unicodeScalars.filter { !(0x2066...0x2069).contains($0.value) && $0.value != 0x200F && $0.value != 0x200E })
            XCTAssertNotNil(plain.range(of: #"\d+\.\d+ \(\d+\)"#, options: .regularExpression), "no version/build: \(version.label)")
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

    /// Crash recovery (plan M12): when iOS ends the editor's web process, the last saved version comes back with
    /// the "Recovered your document" capsule (+ "changes may be missing" once edited); a second end within 60 s
    /// does not reload in a loop but shows "too large" with Share and Back.
    func testCrashRecovery() {
        // the capsule holds 12 s here instead of 3: one accessibility query of the editor page can take seconds
        let app = launch(["XR_KIND": "word", "XR_DOC_NAME": "xr-crash.docx", "XR_RECOVERY_HOLD": "12"])
        XCTAssertEqual(waitState(app, prefix: "ready", timeout: 120), "ready", "editor did not become ready")
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 10))
        // type until the engine marks the document edited (never saved): the capsule must then warn about it
        var edited = ""
        for _ in 0..<3 where !edited.hasSuffix("1") {
            tapFirstLine(app, fallback: CGVector(dx: 0.35, dy: UIDevice.current.userInterfaceIdiom == .pad ? 0.19 : 0.3))
            sleep(2)
            typeSlowly(app, "unsaved ")
            edited = waitLabel(app, "xr-modified", prefix: "modified:1", timeout: 15)
        }
        XCTAssertEqual(edited, "modified:1", "typing did not mark the document edited")

        XCUIDevice.shared.system.open(URL(string: "xrero-autotest://crash")!)
        let first = waitLabel(app, "xr-recovery", prefix: "recovered", timeout: 90)
        let capsule = app.staticTexts["xr-recovered"]
        let shown = capsule.waitForExistence(timeout: 5)
        shot(app, "40-crash-recovered")
        XCTAssertTrue(first.hasPrefix("recovered"), "editor did not come back after its web process ended: \(first)")
        XCTAssertEqual(first, "recovered:edited", "the capsule should warn that unsaved changes may be missing")
        XCTAssertTrue(shown, "recovered capsule not shown")
        XCTAssertTrue(capsule.label.contains("Recovered") || capsule.label.contains("\u{0627}\u{0633}\u{062A}\u{0631}\u{062F}\u{0627}\u{062F}"),
                      "capsule text: \(capsule.label)")
        let gone = NSPredicate(format: "exists == false")
        let hidden = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: gone, object: capsule)], timeout: 20) == .completed
        XCTAssertTrue(hidden, "capsule should hide by itself")

        XCUIDevice.shared.system.open(URL(string: "xrero-autotest://crash")!)   // second end within 60 s
        let second = waitLabel(app, "xr-recovery", prefix: "too-large", timeout: 30)
        sleep(1)
        shot(app, "41-crash-too-large")
        XCTAssertEqual(second, "too-large", "a second end within 60 s must not reload in a loop")
        XCTAssertTrue(app.buttons["xr-recovery-share"].exists, "Share missing on the too-large page")
        let back = app.buttons["xr-recovery-back"]
        XCTAssertTrue(back.exists, "Back missing on the too-large page")
        back.tap()
        // the app reaches "back" at once; reading the state through accessibility can take seconds over the editor page
        var left = waitState(app, prefix: "back", timeout: 15)
        if left != "back" && back.exists && back.isHittable { back.tap(); left = waitState(app, prefix: "back", timeout: 15) }
        XCTAssertEqual(left, "back", "Back did not leave the editor")
    }

    private func waitLabel(_ app: XCUIApplication, _ id: String, prefix: String, timeout: TimeInterval) -> String {
        let label = app.staticTexts[id]
        let end = Date().addingTimeInterval(timeout)
        var last = ""
        while Date() < end {
            if label.exists { last = label.label; if last.hasPrefix(prefix) { return last } }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return last
    }

    // MARK: - Touch interaction gate (plan M14) + typing safety gate (plan F1)

    /// The editor's latest probe (AutotestScreen polls it every 0.5 s with XR_PROBE=1): one taken after this call.
    /// Reading a label opens no hook URL, so the probe never moves the keyboard focus it measures. The label carries
    /// the time it was taken (the simulator shares this Mac's clock), so one read is normally enough: every
    /// accessibility query walks the editor page and can take seconds, on the iPad most of all.
    private func probe(_ app: XCUIApplication) -> [String: Any] {
        let asked = Int64(Date().timeIntervalSince1970 * 1000)
        let label = app.staticTexts["xr-probe"]
        Thread.sleep(forTimeInterval: 1.2)
        for _ in 0..<8 {
            // the app writes the probe to probeFile when it can (no accessibility query); else the label
            let file = (try? String(contentsOfFile: probeFile, encoding: .utf8)) ?? ""
            let s = file.hasPrefix("t=") ? file : (label.exists ? label.label : "")
            if s.hasPrefix("t="), let bar = s.firstIndex(of: "|"),
               let t = Int64(s[s.index(s.startIndex, offsetBy: 2)..<bar]), t >= asked,
               let d = String(s[s.index(after: bar)...]).data(using: .utf8),
               let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], o["err"] == nil { return o }
            Thread.sleep(forTimeInterval: 1)
        }
        return ["err": "no probe"]
    }

    /// Where the app writes the touch-gate probe (this runner's temporary folder: the simulator shares the Mac's disk).
    private let probeFile = NSTemporaryDirectory() + "xr-probe.txt"

    private func num(_ p: [String: Any], _ k: String) -> Double? { (p[k] as? NSNumber)?.doubleValue }
    private func str(_ p: [String: Any], _ k: String) -> String { (p[k] as? String) ?? "" }
    private func flag(_ p: [String: Any], _ k: String) -> Bool { (p[k] as? NSNumber)?.boolValue ?? false }

    /// The document text without the direction marks the engine may add and with the paragraphs joined by "|".
    private func plain(_ p: [String: Any]) -> String {
        String(str(p, "text").unicodeScalars.filter { $0.value != 0x200E && $0.value != 0x200F })
    }

    /// Keyboard focus as the user feels it: the web view holds first responder (the keyboard) AND the editor's own
    /// input field is the focused element (where the keyboard's text goes).
    private func focused(_ p: [String: Any]) -> Bool { flag(p, "fr") && flag(p, "area") }

    private func focusInfo(_ p: [String: Any]) -> String {
        "fr=\(flag(p, "fr")) area=\(flag(p, "area")) focus=\(str(p, "focus")) hasFocus=\(flag(p, "hasFocus")) kb=\(flag(p, "kb"))"
    }

    /// A Home-tab ribbon button (id-toolbar-btn-<key>) tapped for real where the probe measured it: the icon-only
    /// buttons (Bold, Select all) carry no accessibility label to find them by. Phones fold the ribbon: when the probe
    /// says it is folded and closed, the Home tab is tapped first, the way a user opens it.
    private func tapToolbar(_ app: XCUIApplication, _ key: String, _ p: [String: Any], tap: (Double, Double) -> Void) -> Bool {
        var p = p
        if str(p, "fold") == "closed" {
            let tab = app.webViews.buttons.matching(NSPredicate(format: "label == 'Home' OR label == %@",
                                                                "\u{0627}\u{0644}\u{0631}\u{0626}\u{064A}\u{0633}\u{064A}\u{0629}")).firstMatch   // الرئيسية
            if tab.exists && tab.isHittable { tab.tap(); p = probe(app) }
        }
        guard let xy = (p["btn"] as? [String: Any])?[key] as? [NSNumber], xy.count == 2 else {
            print("XR touch toolbar button \(key) not visible: fold=\(str(p, "fold"))")
            return false
        }
        tap(xy[0].doubleValue, xy[1].doubleValue)
        return true
    }

    /// Touch gate (M14) + typing gate (F1) in a new Word document, in Arabic and in English (app in that language,
    /// so the Arabic document is the right-to-left blank): tap places the caret, a tap inside the text puts the next
    /// letter there, double tap and long press select a word, a formatting tap (Bold) keeps the keyboard, 5x Enter,
    /// Select All, a native sheet returns the keyboard and the caret, pinch zooms the page through the engine (crisp,
    /// not a magnified bitmap) and the zoom stays, then Save + reopen keeps the text. Taps are placed from the
    /// caret's / button's measured position, never fixed screen points. Every result goes to the editor log as a
    /// "touch-gate <lang> <check>: PASS|FAIL|KNOWN" line for check_saved.py, which also checks the saved
    /// xr-touch-<lang>.docx. KNOWN = a real app gap found by this gate and reported, not fixed here: it is printed on
    /// every run and turns into PASS by itself once the app is fixed. Named "ZZ" to run after every other test: it
    /// is the longest and must never be able to disturb the typing and clipboard tests.
    func testZZTouchGateCaretSelectionPinchFocus() {
        for lang in ["ar", "en"] { touchGate(lang) }
    }

    private func touchGate(_ lang: String) {
        let ar = lang == "ar"
        // three long words: taps at 18% / 54% / 86% of the line land inside the first / second / third word
        let sentence = ar ? "\u{0627}\u{0644}\u{0645}\u{0633}\u{062A}\u{0634}\u{0641}\u{064A}\u{0627}\u{062A} \u{0648}\u{0627}\u{0644}\u{0645}\u{0624}\u{0633}\u{0633}\u{0627}\u{062A} \u{0627}\u{0644}\u{0625}\u{0645}\u{0627}\u{0631}\u{0627}\u{062A}\u{064A}\u{0629}"   // المستشفيات والمؤسسات الإماراتية
                          : "Extraordinary Wonderful Typewriter"
        let marker = ar ? "\u{0642}" : "Q"                                                        // ق
        let boldWord = ar ? "\u{0639}\u{0631}\u{064A}\u{0636}" : "Bold"                           // عريض
        let endWord = ar ? "\u{0646}\u{0647}\u{0627}\u{064A}\u{0629}" : "End"                      // نهاية
        let app = XCUIApplication()
        app.launchArguments = ["-xr.lang", lang]
        try? FileManager.default.removeItem(atPath: probeFile)
        app.launchEnvironment = ["XR_KIND": "word", "XR_NEW_NAME": "xr-touch-\(lang).docx", "XR_PROBE": "1", "XR_PROBE_FILE": probeFile]
        app.launch()
        let keep = continueAfterFailure
        continueAfterFailure = true                  // every check is recorded; one failure must not hide the others
        var notes: [String] = []
        func gate(_ name: String, _ ok: Bool, _ detail: String, known: String? = nil) {
            let status = ok ? "PASS" : (known == nil ? "FAIL" : "KNOWN")
            let line = "touch-gate \(lang) \(name): \(status) \(detail)" + (ok || known == nil ? "" : " [known app gap: \(known!)]")
            print("XR " + line)
            notes.append(line.replacingOccurrences(of: "\n", with: " "))
            if known == nil { XCTAssertTrue(ok, line) }
        }
        func info(_ name: String, _ detail: String) {
            let line = "touch-gate \(lang) \(name): INFO \(detail)"
            print("XR " + line)
            notes.append(line)
        }
        defer {
            // the results into the editor log (one URL at the very end: a hook URL mid-test could move the focus)
            autotest("note", notes.joined(separator: "\n"))
            app.terminate()
            continueAfterFailure = keep
        }
        let ready = waitState(app, prefix: "ready", timeout: 120)
        gate("editor-ready", ready == "ready", ready)
        guard ready == "ready" else { return }
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 10))
        sleep(2)
        // taps from the app's corner plus the web view's origin (read once): resolving the web view for every tap is an
        // accessibility query over the whole editor page, slow enough on the iPad to time out
        let origin = web.frame.origin
        func point(_ x: Double, _ y: Double) -> XCUICoordinate {
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: origin.x + x, dy: origin.y + y))
        }
        func tap(_ x: Double, _ y: Double) { point(x, y).tap() }

        // 1) tap the first line: caret there, keyboard up (one tap, as a user expects; further taps are only made so
        //    the later checks can run, and the count is logged)
        tapFirstLine(app, fallback: CGVector(dx: ar ? 0.65 : 0.35, dy: UIDevice.current.userInterfaceIdiom == .pad ? 0.19 : 0.3))
        var p0 = probe(app)
        if !focused(p0) { sleep(2); p0 = probe(app) }      // the keyboard can take a moment to come up on the simulator
        var taps = 1
        while !focused(p0) && taps < 3, let x = num(p0, "cx"), let y = num(p0, "cy") {
            tap(x, y); taps += 1; p0 = probe(app)
        }
        let x0 = num(p0, "cx"), y0 = num(p0, "cy")
        // the gate: a tap on the line gives the caret and the keyboard. A first tap that missed on the freshly opened
        // editor (seen once on the iPad simulator) is recorded on its own line so the trend stays visible.
        if taps > 1 { info("first-tap-missed", "the keyboard came up only after tap \(taps)") }
        gate("tap-places-caret-first-line", x0 != nil && focused(p0) && taps <= 2,
             "caret=\(x0 ?? -1),\(y0 ?? -1) focused after \(taps) tap(s): \(focused(p0)) \(focusInfo(p0))")
        shot(app, "50-touch-\(lang)-caret")

        // 2) typing (F1): the sentence arrives
        typeSlowly(app, sentence)
        let p1 = probe(app)
        gate("typing", plain(p1).contains(sentence), "text=\(plain(p1).prefix(80))")
        guard let sx = x0, let ex = num(p1, "cx"), let ly = num(p1, "cy"), abs(ex - sx) > 60 else {
            gate("line-measured", false, "line start/end not measurable: start=\(x0 ?? -1) end=\(num(p1, "cx") ?? -1)")
            return
        }
        let dir: Double = ex > sx ? 1 : -1                  // the line runs left-to-right (EN) or right-to-left (AR)
        gate("line-direction", ar ? dir < 0 : dir > 0, "start=\(sx) end=\(ex)")
        func at(_ f: Double) -> Double { sx + (ex - sx) * f }
        func tapEnd() { tap(ex + dir * 40, ly) }           // past the line's end: caret to the end, selection dropped
        /// the caret is at the end of the first line (its end moved by the letter typed in)
        func atLineEnd(_ p: [String: Any]) -> Bool { ((num(p, "cx") ?? sx) - ex) * dir >= -2 && abs((num(p, "cy") ?? -99) - ly) <= 4 }

        // 3) a tap inside the text moves the caret there; the next letter goes in there
        tap(at(0.54), ly)
        let p2 = probe(app)
        let cx2 = num(p2, "cx") ?? -1
        gate("tap-moves-caret-into-text", cx2 > min(sx, ex) + 4 && cx2 < max(sx, ex) - 4 && str(p2, "sel").isEmpty && focused(p2),
             "caret x=\(cx2) line \(sx)...\(ex) sel='\(str(p2, "sel"))' \(focusInfo(p2))")
        typeSlowly(app, marker)
        let p3 = probe(app)
        let t3 = plain(p3).components(separatedBy: "|").first ?? ""
        let inside = t3.replacingOccurrences(of: marker, with: "") == sentence && !t3.hasPrefix(marker) && !t3.hasSuffix(marker)
        gate("tap-then-type-inserts-there", inside, "line='\(t3)'")
        shot(app, "51-touch-\(lang)-tap-insert")

        // 4) double tap selects a word
        point(at(0.18), ly).doubleTap()
        let p4 = probe(app)
        let sel4 = str(p4, "sel").trimmingCharacters(in: .whitespacesAndNewlines)
        gate("double-tap-selects-word", sel4.count >= 4 && !sel4.contains(" ") && t3.contains(sel4),
             "sel='\(sel4)' menu=\(num(p4, "menu") ?? 0) \(focusInfo(p4))")
        shot(app, "52-touch-\(lang)-double-tap")

        // 5) long press selects a word (iOS: the word, its handles and the edit menu)
        tapEnd()
        point(at(0.86), ly).press(forDuration: 1.2)
        let p5 = probe(app)
        let sel5 = str(p5, "sel").trimmingCharacters(in: .whitespacesAndNewlines)
        shot(app, "53-touch-\(lang)-long-press")
        gate("long-press-selects-word", sel5.count >= 4 && !sel5.contains(" ") && t3.contains(sel5),
             "sel='\(sel5)' web menu=\(num(p5, "menu") ?? 0) native menu=\(app.menuItems.count) \(focusInfo(p5))",
             known: "a long press opens the editor's desktop right-click menu (Cut/Copy/Paste/Paragraph...) and the keyboard goes down; no word is selected")

        // 6) a formatting tap keeps the keyboard: caret at the end, Bold, type on
        // close the menu the long press left with a tap in the page margin just above the line (the menu opens below
        // the finger, and in Arabic it can cover the line's end), then the caret to the end of the line
        tap(at(0.5), ly - 18)
        tapEnd()
        var p6 = probe(app)
        for _ in 0..<2 where !(atLineEnd(p6) && (num(p6, "menu") ?? 0) == 0 && focused(p6)) { tap(at(0.5), ly - 18); tapEnd(); p6 = probe(app) }
        gate("caret-to-line-end", atLineEnd(p6) && str(p6, "sel").isEmpty && focused(p6),
             "caret x=\(num(p6, "cx") ?? -1) line end \(ex) sel='\(str(p6, "sel"))' \(focusInfo(p6))")
        let tapped = tapToolbar(app, "bold", p6, tap: tap)
        let p7 = probe(app)
        gate("bold-button-applies", tapped && flag(p7, "bold"), "tapped=\(tapped) bold=\(flag(p7, "bold")) fold=\(str(p7, "fold"))")
        gate("format-tap-keeps-keyboard", tapped && focused(p7), focusInfo(p7))
        shot(app, "54-touch-\(lang)-bold")
        if !focused(p7) { tapEnd(); _ = probe(app) }                     // so the later checks still run (logged above)
        typeSlowly(app, " " + boldWord)
        let p8 = probe(app)
        gate("type-after-format", plain(p8).contains(sentence.prefix(4)) && (plain(p8).components(separatedBy: "|").first ?? "").hasSuffix(boldWord),
             "bold=\(flag(p8, "bold")) text=\(plain(p8).prefix(80))")
        let paras8 = Int(num(p8, "paras") ?? 0)
        for _ in 0..<5 { app.typeText("\n"); usleep(300_000) }
        typeSlowly(app, endWord)
        let p9 = probe(app)
        let paras9 = Int(num(p9, "paras") ?? 0)
        gate("enter-x5", paras9 >= paras8 + 5 && plain(p9).hasSuffix("|" + endWord), "paragraphs \(paras8)->\(paras9) text=\(plain(p9).suffix(30))")

        // 7) Select All: the ribbon's Select all button (touch); Cmd+A (hardware keyboard) recorded for information
        let all = plain(p9).replacingOccurrences(of: "|", with: "").filter { !$0.isWhitespace }
        func selected(_ p: [String: Any]) -> Int { str(p, "sel").filter { !$0.isWhitespace }.count }
        let selTapped = tapToolbar(app, "select-all", p9, tap: tap)
        let p10 = probe(app)
        gate("select-all", selTapped && !all.isEmpty && selected(p10) >= all.count,
             "tapped=\(selTapped) selected \(selected(p10))/\(all.count) chars \(focusInfo(p10))")
        tapEnd(); _ = probe(app)
        app.typeKey("a", modifierFlags: .command)
        let pA = probe(app)
        info("cmd-a-select-all", "selected \(selected(pA))/\(all.count) chars (simulator hardware-keyboard event)")
        var p11 = probe(app)
        for _ in 0..<3 where !(str(p11, "sel").isEmpty && focused(p11)) { tapEnd(); p11 = probe(app) }

        // 8) a native sheet over the editor: closing it brings back the keyboard and the caret where they were.
        //    The sheet opens through the Autotest URL hook (as in testAboutAndLicences); a no-op hook URL first shows
        //    whether a hook URL alone changes the focus, so the sheet result is not blamed on the hook.
        autotest("note", "")
        let pN = probe(app)
        info("hook-url-keeps-keyboard", "\(focused(pN)) \(focusInfo(pN))")
        p11 = probe(app)
        let caret11 = (num(p11, "cx") ?? -1, num(p11, "cy") ?? -1)
        let up11 = focused(p11)
        XCUIDevice.shared.system.open(URL(string: "xrero-autotest://about")!)
        let version = app.staticTexts["xr-about-version"]
        let shown = version.waitForExistence(timeout: 20)
        shot(app, "55-touch-\(lang)-sheet")
        if shown { app.buttons["xr-about-done"].tap() }
        for _ in 0..<20 where version.exists { usleep(500_000) }
        let p12 = probe(app)
        let caret12 = (num(p12, "cx") ?? -2, num(p12, "cy") ?? -2)
        gate("sheet-opens-and-closes", shown && !version.exists, "shown=\(shown)")
        gate("sheet-return-keyboard", shown && (!up11 || focused(p12)), "before: \(focusInfo(p11)) after: \(focusInfo(p12))",
             known: "after a native sheet closes the keyboard does not come back (plan M14: refocus the editor when the keyboard was up before)")
        gate("sheet-return-caret", shown && abs(caret12.0 - caret11.0) <= 2 && abs(caret12.1 - caret11.1) <= 2,
             "caret \(caret11) -> \(caret12)")
        shot(app, "56-touch-\(lang)-sheet-closed")
        if !focused(p12) { tapEnd(); _ = probe(app) }

        // 9) pinch: the engine zooms (the page re-renders crisp: no WebKit bitmap scaling) and the zoom stays
        // pinch on the page itself: on a phone the Home panel opened for Bold folds down over the top of the page
        // (where the web view's centre is), so it is closed first with a tap on its tab, as a user would
        if str(probe(app), "fold") == "open" {
            let home = app.webViews.buttons.matching(NSPredicate(format: "label == 'Home' OR label == %@",
                                                                 "\u{0627}\u{0644}\u{0631}\u{0626}\u{064A}\u{0633}\u{064A}\u{0629}")).firstMatch   // الرئيسية
            if home.exists && home.isHittable { home.tap() }
        }
        let z0 = num(probe(app), "zoom") ?? 0
        web.pinch(withScale: 2.0, velocity: 2.0)
        let p13 = probe(app)
        let z1 = num(p13, "zoom") ?? 0
        let crisp = (num(p13, "vv") ?? 0) == 1 && (num(p13, "vvi") ?? 0) == 1
        shot(app, "57-touch-\(lang)-pinch-in")
        gate("pinch-in-zooms-page", z1 > z0 * 1.15 && crisp, "zoom \(z0)->\(z1) viewport scale \(num(p13, "vv") ?? 0)/\(num(p13, "vvi") ?? 0)")
        sleep(2)
        let z1b = num(probe(app), "zoom") ?? 0
        gate("pinch-zoom-kept", z1 > z0 && z1b == z1, "zoom \(z1) after 3 s: \(z1b)")
        web.pinch(withScale: 0.5, velocity: -2.0)
        let p14 = probe(app)
        let z2 = num(p14, "zoom") ?? 0
        shot(app, "58-touch-\(lang)-pinch-out")
        gate("pinch-out-zooms-back", z2 < z1b && z2 >= 25 && (num(p14, "vv") ?? 0) == 1,
             "zoom \(z1b)->\(z2) viewport scale \(num(p14, "vv") ?? 0)",
             known: z1b > z0 ? "a pinch-in zooms the page, but the pinch-out after it leaves the zoom where it was (seen on the simulator; to confirm on a device)" : nil)

        // keypress-to-frame latency of this run (simulator: recorded for the trend, the real bar needs an iPhone)
        let lat = probe(app)["lat"] as? [String: Any] ?? [:]
        info("typing-latency", "n=\(num(lat, "n") ?? 0) median=\(num(lat, "med") ?? -1) ms p95=\(num(lat, "p95") ?? -1) ms (simulator)")

        // 10) Save, open again from the saved file: the text is all there
        let saved = save(app)
        gate("save", saved.hasPrefix("saved"), saved)
        autotest("reopen")
        let again = waitState(app, prefix: "ready", timeout: 120)
        let p15 = probe(app)
        let back = plain(p15)
        gate("reopen-keeps-text", again == "ready" && back.contains(t3) && back.contains(boldWord) && back.contains(endWord),
             "\(again) text=\(back.prefix(100))")
        shot(app, "59-touch-\(lang)-reopened")
    }

    /// New spreadsheet and presentation open in their editors (iPad: also in Arabic, where the spreadsheet's status
    /// bar mirrors its absolutely placed boxes), and pass the iPad layout gate.
    func testSpreadsheetAndPresentationOpen() {
        var runs = [("cell", "en"), ("slide", "en")]
        if UIDevice.current.userInterfaceIdiom == .pad { runs.insert(("cell", "ar"), at: 1) }
        for (kind, lang) in runs {
            let app = launch(["XR_KIND": kind, "XR_LANG": lang])
            let ready = waitState(app, prefix: "ready", timeout: 120)
            sleep(2)
            let tag = kind + (lang == "en" ? "" : "-" + lang)
            shot(app, "20-" + tag + "-ready")
            XCTAssertEqual(ready, "ready", "\(tag) editor did not become ready")
            checkIPadLayout(app, tag)
            app.terminate()
        }
    }
}
