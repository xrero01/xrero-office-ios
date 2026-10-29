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

    /// Neutral editor chrome gate (design item M6), iPhone and iPad: the editor opens in the modern light theme with
    /// line tabs, the Xrero kind accent on the tab underline, the iOS bar colour on the tab row, the system font and
    /// no tab arrows on touch; a swipe scrolls the tab row when it overflows (phones); switching the app to dark mode
    /// swaps the editor to the dark set live (no reload: the editor stays ready) and back. Recorded, not fatal, so one
    /// editor's failure never hides the later results. Runs after the typing / save steps of each test.
    private var chromeRun = 0
    /// Runs the Autotest "chrome" probe and waits for THIS run's answer ("chrome<n>:ok ..." / "chrome<n>:fail ...").
    private func chromeProbe(_ app: XCUIApplication, _ want: String) -> String {
        chromeRun += 1
        XCUIDevice.shared.system.open(URL(string: "xrero-autotest://chrome?want=\(want)&n=\(chromeRun)")!)
        return waitState(app, prefix: "chrome\(chromeRun):", timeout: 20)
    }
    private func checkChrome(_ app: XCUIApplication, _ name: String) {
        let keep = continueAfterFailure
        continueAfterFailure = true
        defer { continueAfterFailure = keep }
        let light = chromeProbe(app, "light")
        print("XR chrome \(name) light: \(light)")
        XCTAssertTrue(light.contains(":ok"), "editor chrome (\(name), light): \(light)")
        // tabs=<left>,<right>,<centre y>,<scrollLeft>,<overflow> in web view points
        func tabs(_ s: String) -> [Double] {
            guard let m = s.range(of: "tabs=") else { return [] }
            return s[m.upperBound...].prefix { $0 != ")" && $0 != " " }.split(separator: ",").compactMap { Double($0) }
        }
        let n = tabs(light)
        if n.count == 5 && n[4] > 8 {                     // the tab row overflows (phones): it must scroll by finger
            let o = app.webViews.firstMatch.coordinate(withNormalizedOffset: .zero)
            let rtl = name.hasSuffix("-ar")                // right-to-left: the hidden tabs are on the left
            let from = o.withOffset(CGVector(dx: rtl ? n[0] + 40 : n[1] - 40, dy: n[2]))
            let to = o.withOffset(CGVector(dx: rtl ? n[1] - 40 : n[0] + 40, dy: n[2]))
            from.press(forDuration: 0.1, thenDragTo: to)
            sleep(1)
            let after = chromeProbe(app, "light")
            print("XR chrome \(name) tab swipe: \(after)")
            shot(app, "07-\(name)-tabs-swiped")
            let a = tabs(after)
            XCTAssertTrue(a.count == 5 && a[3] > 0, "the tab row did not scroll under a swipe (\(name)): \(after)")
        }
        shot(app, "06-\(name)-chrome-light")
        XCUIDevice.shared.system.open(URL(string: "xrero-autotest://appearance?dark=1")!)
        sleep(3)
        let dark = chromeProbe(app, "dark")
        print("XR chrome \(name) dark: \(dark)")
        shot(app, "06-\(name)-chrome-dark")
        XCTAssertTrue(dark.contains(":ok"), "editor chrome (\(name), dark): \(dark)")
        XCUIDevice.shared.system.open(URL(string: "xrero-autotest://appearance?dark=0")!)
        sleep(3)
        let back = chromeProbe(app, "light")
        print("XR chrome \(name) back to light: \(back)")
        XCTAssertTrue(back.contains(":ok"), "editor chrome (\(name), back to light): \(back)")
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
        checkChrome(app, "word")
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
        checkChrome(app, "pdf")
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
            checkChrome(app, tag)
            app.terminate()
        }
    }
}
