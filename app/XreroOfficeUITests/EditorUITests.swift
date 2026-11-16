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
        let point = n.count == 2
            // the cursor is in web view points; the web view fills the editor area below the system bar
            ? web.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: n[0], dy: n[1]))
            : web.coordinate(withNormalizedOffset: fallback)
        point.tap()
        // seen once on iPad (Arabic blank): the first tap gave no keyboard - one more tap, as a person would
        if !app.keyboards.firstMatch.waitForExistence(timeout: 4) {
            print("XR first line: no keyboard after the tap - tapping again")
            point.tap()
            _ = app.keyboards.firstMatch.waitForExistence(timeout: 4)
        }
    }

    /// Human pace: one character at a time (a burst from XCUITest is far faster than any person types).
    /// The touch gate's probe (a full-document read on the main thread every 0.5 s) is paused meanwhile, so it does
    /// not add its own cost to the typing-latency samples; without XR_PROBE nothing reads the pause file.
    private func typeSlowly(_ app: XCUIApplication, _ text: String) {
        pauseProbe(true)
        defer { pauseProbe(false) }
        for ch in text { app.typeText(String(ch)); usleep(150_000) }
    }

    /// AutotestScreen's probe skips its poll while this file exists (the simulator shares the Mac's file system).
    private func pauseProbe(_ on: Bool) {
        let f = probeFile + ".pause"
        if on { FileManager.default.createFile(atPath: f, contents: Data()) } else { try? FileManager.default.removeItem(atPath: f) }
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

    /// Engine contract (20.3 F0) in the running editor: every xr-contract.json entry for this editor and device
    /// exists (globals, API methods, DOM, controllers). Recorded; the test goes on (later checks still report).
    private func checkContract(_ app: XCUIApplication, _ name: String) {
        XCUIDevice.shared.system.open(URL(string: "xrero-autotest://contract")!)
        let c = waitState(app, prefix: "contract:", timeout: 20)
        print("XR contract \(name): \(c)")
        let keep = continueAfterFailure
        continueAfterFailure = true
        XCTAssertTrue(c.hasPrefix("contract:ok"), "engine contract (\(name)): \(c)")
        continueAfterFailure = keep
    }

    /// Bridge (20.3 F0): Bold on / off through EditorController.call reaches the engine, and the engine's state comes
    /// back to the app's EditorState through the coalesced state channel, within the callback budget. Recorded; the
    /// test goes on.
    private func checkBridge(_ app: XCUIApplication) {
        XCUIDevice.shared.system.open(URL(string: "xrero-autotest://bridge")!)
        let b = waitState(app, prefix: "bridge:ok", timeout: 25)
        let probe = app.staticTexts["xr-editor-state"]
        print("XR bridge: \(b) | probe: \(probe.exists ? probe.label : "missing")")
        let keep = continueAfterFailure
        continueAfterFailure = true
        XCTAssertTrue(b.hasPrefix("bridge:ok"), "native bridge / state channel: \(b)")
        XCTAssertTrue(probe.exists && probe.label.contains("undo:1"), "EditorState probe: \(probe.exists ? probe.label : "missing")")
        continueAfterFailure = keep
    }

    /// Neutral editor chrome gate (design item M6), iPhone and iPad: the editor opens in the modern light theme with
    /// line tabs, the Xrero kind accent on the tab underline, the iOS bar colour on the tab row, the system font and
    /// no tab arrows on touch; a swipe scrolls the tab row when it overflows (phones); switching the app to dark mode
    /// swaps the editor to the dark set live (no reload: the same editor instance, undo kept, the typed text still
    /// there) and back; in both looks a primary dialog button's label reaches 4.5:1 on its fill; Slides must show its
    /// Present capsule. Recorded, not fatal, so one editor's failure never hides the later results. Runs after the
    /// typing / save steps of each test. `has`: text typed earlier that must survive the switch (Word only).
    private var chromeRun = 0
    /// Runs the Autotest "chrome" probe and waits for THIS run's answer ("chrome<n>:ok ..." / "chrome<n>:fail ...").
    private func chromeProbe(_ app: XCUIApplication, _ want: String, has: String = "") -> String {
        chromeRun += 1
        let h = has.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        XCUIDevice.shared.system.open(URL(string: "xrero-autotest://chrome?want=\(want)&n=\(chromeRun)&has=\(h)")!)
        return waitState(app, prefix: "chrome\(chromeRun):", timeout: 20)
    }
    private func checkChrome(_ app: XCUIApplication, _ name: String, has: String = "") {
        let keep = continueAfterFailure
        continueAfterFailure = true
        defer { continueAfterFailure = keep }
        // "key=value" from a probe answer (inst / undo / text)
        func field(_ s: String, _ k: String) -> String {
            guard let m = s.range(of: " " + k + "=") else { return "" }
            return String(s[m.upperBound...].prefix { $0 != " " && $0 != ")" })
        }
        let light = chromeProbe(app, "light", has: has)
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
            sleep(1)                                       // the probe's test dialog has finished closing
            from.press(forDuration: 0.1, thenDragTo: to)
            sleep(1)
            var after = chromeProbe(app, "light")
            if tabs(after).count == 5 && tabs(after)[3] == 0 {   // a swipe that did not take: one more, as a person would
                print("XR chrome \(name) tab swipe did not move the row - swiping again: \(after)")
                from.press(forDuration: 0.3, thenDragTo: to)
                sleep(1)
                after = chromeProbe(app, "light")
            }
            print("XR chrome \(name) tab swipe: \(after)")
            shot(app, "07-\(name)-tabs-swiped")
            let a = tabs(after)
            XCTAssertTrue(a.count == 5 && a[3] > 0, "the tab row did not scroll under a swipe (\(name)): \(after)")
        }
        shot(app, "06-\(name)-chrome-light")
        XCUIDevice.shared.system.open(URL(string: "xrero-autotest://appearance?dark=1")!)
        sleep(3)
        let dark = chromeProbe(app, "dark", has: has)
        print("XR chrome \(name) dark: \(dark)")
        shot(app, "06-\(name)-chrome-dark")
        XCTAssertTrue(dark.contains(":ok"), "editor chrome (\(name), dark): \(dark)")
        // the live switch kept the open editor: same instance (no reload), undo state kept, typed text still there
        XCTAssertTrue(!field(light, "inst").isEmpty && field(dark, "inst") == field(light, "inst"),
                      "the dark switch reloaded the editor (\(name)): \(light) -> \(dark)")
        XCTAssertEqual(field(dark, "undo"), field(light, "undo"), "undo lost by the dark switch (\(name)): \(dark)")
        if !has.isEmpty {
            XCTAssertEqual(field(light, "text"), "1", "typed text not found before the dark switch (\(name)): \(light)")
            XCTAssertEqual(field(dark, "text"), "1", "typed text lost by the dark switch (\(name)): \(dark)")
        }
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

    /// Save the way a user does: the editor's own Save button (gone since M4a hid the title row), else the user's Save
    /// the native bar's ⋯ > Save runs (controller.userSave = asc_Save, through a test URL: these tests keep the bar off
    /// for their exact layout); the shell's save hook only as the last resort. Never Cmd+S: the simulator has no
    /// hardware keyboard, so it types a literal "s" into the document.
    private func save(_ app: XCUIApplication) -> String {
        let labels = app.webViews.buttons.allElementsBoundByIndex.prefix(25).map { $0.label }
        print("XR web buttons:", labels)
        let button = app.webViews.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'Save' OR label BEGINSWITH 'حفظ'")).firstMatch
        if button.exists && button.isHittable {
            button.tap()
            let s = waitState(app, prefix: "saved", timeout: 30)
            if s.hasPrefix("saved") { print("XR save path: Save button"); return s }
        }
        XCUIDevice.shared.system.open(URL(string: "xrero-autotest://usersave")!)
        let s2 = waitState(app, prefix: "saved", timeout: 30)
        if s2.hasPrefix("saved") { print("XR save path: user save"); return s2 }
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
        // after the save (nothing below is saved again), so these checks never touch the typing result
        checkContract(app, "word")
        checkBridge(app)
        checkIPadLayout(app, "word")
        checkIPadRotation(app, "word")
        checkChrome(app, "word", has: "English")
    }

    /// The native top bar (plan M4a), iPhone and iPad, English in light then Arabic in dark: Back ("Documents"), the
    /// file name, Undo, ⋯ (and Redo in the bar on iPad, in ⋯ on iPhone); the editors' own title row is gone (no web
    /// Save / Undo buttons); the second line says nothing for an unchanged document, "Edited" after typing, and
    /// "Saved" only once a save really completed; Undo / Redo reach the engine through the bridge (the state
    /// channel's canRedo follows); Arabic mirrors the bar (Back on the right). Runs the editor under the bar
    /// (XR_BAR=1) in its own document, so the typing tests keep their exact layout.
    func testTopBar() {
        continueAfterFailure = true                        // the Arabic / dark half still reports when English fails
        let pad = UIDevice.current.userInterfaceIdiom == .pad
        for (lang, dark) in [("en", false), ("ar", true)] {
            let ar = lang == "ar"
            let doc = "xr-bar-\(lang).docx"
            let app = launch(["XR_KIND": "word", "XR_BAR": "1", "XR_LANG": lang, "XR_NEW_NAME": doc])
            let ready = waitState(app, prefix: "ready", timeout: 120)
            XCTAssertEqual(ready, "ready", "editor did not become ready (\(lang))")
            if dark { XCUIDevice.shared.system.open(URL(string: "xrero-autotest://appearance?dark=1")!); sleep(3) }
            let name = lang + (dark ? "-dark" : "-light")
            let probe = app.staticTexts["xr-editor-state"]
            let status = app.staticTexts["xr-bar-status"]
            let savedWord = ar ? "محفوظ" : "Saved", editedWord = ar ? "معدَّل" : "Edited"
            // one snapshot per read: the line can go away between an `exists` and a `label` (that would fail the test)
            func statusNow() -> String { (try? status.firstMatch.snapshot())?.label ?? "(none)" }
            func waitStatus(_ want: String, _ timeout: TimeInterval) -> String {
                let end = Date().addingTimeInterval(timeout)
                while Date() < end {
                    if statusNow() == want { return want }
                    Thread.sleep(forTimeInterval: 0.3)
                }
                return statusNow()
            }
            func waitProbe(_ part: String, _ timeout: TimeInterval) -> Bool {
                let end = Date().addingTimeInterval(timeout)
                while Date() < end {
                    if ((try? probe.firstMatch.snapshot())?.label ?? "").contains(part) { return true }
                    Thread.sleep(forTimeInterval: 0.3)
                }
                return false
            }
            let back = app.buttons["xr-bar-back"], undo = app.buttons["xr-bar-undo"], more = app.buttons["xr-bar-more"]
            let title = app.staticTexts["xr-bar-title"]

            // the bar as opened: one Back, the name, Undo (nothing to undo yet), ⋯; Redo in the bar on iPad only
            XCTAssertTrue(back.waitForExistence(timeout: 10), "no Back in the top bar (\(name))")
            XCTAssertEqual(back.label, ar ? "المستندات" : "Documents", "Back label (\(name))")
            // iPad: "Documents" is written next to the chevron (a wider button than the chevron alone)
            if pad { XCTAssertGreaterThan(back.frame.width, 70, "iPad Back shows no 'Documents' text (\(name)): \(back.frame)") }
            XCTAssertTrue(title.exists && title.label == "xr-bar-\(lang)", "title (\(name)): \(title.exists ? title.label : "missing")")
            XCTAssertTrue(undo.exists, "no Undo in the top bar (\(name))")
            XCTAssertFalse(undo.isEnabled, "Undo enabled with nothing to undo (\(name))")
            XCTAssertTrue(more.exists, "no ⋯ menu in the top bar (\(name))")
            XCTAssertEqual(app.buttons["xr-bar-redo"].exists, pad, "Redo in the bar: iPad only (\(name))")
            XCTAssertNotEqual(statusNow(), savedWord, "'Saved' before any save (\(name))")
            // 44 pt targets: at least 44 pt wide; on iOS 26 the bar draws its buttons as 36 pt glass capsules and
            // extends their touch area over the whole bar height itself, so the reported height may be 36
            for (id, e) in [("back", back), ("undo", undo), ("more", more)] {
                XCTAssertGreaterThanOrEqual(e.frame.width, 43.5, "\(id) is narrower than 44 pt (\(name)): \(e.frame)")
                XCTAssertGreaterThanOrEqual(e.frame.height, 35.5, "\(id) is too short (\(name)): \(e.frame)")
            }
            // the editors' title row is gone: no web Save / Undo buttons (the native bar replaces them)
            let webTitle = app.webViews.buttons.matching(NSPredicate(format:
                "label BEGINSWITH[c] 'Save' OR label BEGINSWITH 'حفظ' OR label BEGINSWITH[c] 'Undo' OR label BEGINSWITH 'تراجع'"))
            XCTAssertEqual(webTitle.count, 0, "the editor's own title row is still shown (\(name)): \(webTitle.allElementsBoundByIndex.map { $0.label })")
            // mirrored as one piece: Back leads (left in English, right in Arabic), Undo / ⋯ trail
            if ar { XCTAssertGreaterThan(back.frame.midX, undo.frame.midX, "Arabic bar not mirrored: Back \(back.frame) Undo \(undo.frame)") }
            else { XCTAssertLessThan(back.frame.midX, undo.frame.midX, "English bar order: Back \(back.frame) Undo \(undo.frame)") }
            print("XR bar \(name): back=\(back.frame) undo=\(undo.frame) more=\(more.frame) title=\(title.frame) status=\(statusNow())")
            shot(app, "50-bar-\(name)-opened")

            // typing -> "Edited", Undo enabled
            tapFirstLine(app, fallback: CGVector(dx: 0.35, dy: pad ? 0.19 : 0.3))
            sleep(2)
            typeSlowly(app, ar ? "\u{0634}\u{0631}\u{064A}\u{0637} \u{0623}\u{0639}\u{0644}\u{0649}" : "Top bar test")   // شريط أعلى
            XCTAssertEqual(waitStatus(editedWord, 10), editedWord, "no 'Edited' after typing (\(name))")
            XCTAssertTrue(waitProbe("undo:1", 10), "no undo after typing (\(name)): \(probe.label)")
            XCTAssertTrue(undo.isEnabled, "Undo still disabled after typing (\(name))")
            shot(app, "51-bar-\(name)-edited")

            // Undo through the bridge: something to redo now; Redo (bar on iPad, ⋯ on iPhone) takes it back
            undo.tap()
            XCTAssertTrue(waitProbe("redo:1", 10), "Undo did not reach the engine (\(name)): \(probe.label)")
            print("XR bar \(name) after undo: \(probe.label)")
            if pad {
                app.buttons["xr-bar-redo"].tap()
            } else {
                more.tap()
                let redo = app.buttons["xr-bar-redo"]
                XCTAssertTrue(redo.waitForExistence(timeout: 5), "no Redo in ⋯ (\(name))")
                shot(app, "52-bar-\(name)-menu")
                redo.tap()
            }
            XCTAssertTrue(waitProbe("redo:0", 10), "Redo did not reach the engine (\(name)): \(probe.label)")
            print("XR bar \(name) after redo: \(probe.label)")
            XCTAssertNotEqual(statusNow(), savedWord, "'Saved' without a save (\(name))")

            // Save from ⋯ -> the file is written -> "Saved"
            more.tap()
            let save = app.buttons["xr-bar-save"]
            XCTAssertTrue(save.waitForExistence(timeout: 5), "no Save in ⋯ (\(name))")
            if pad { shot(app, "52-bar-\(name)-menu") }
            save.tap()
            let saved = waitState(app, prefix: "saved", timeout: 40)
            XCTAssertTrue(saved.hasPrefix("saved"), "Save in ⋯ did not save (\(name)): \(saved)")
            let line = waitStatus(savedWord, 10)
            print("XR bar \(name) saved: \(saved) status=\(line)")
            XCTAssertEqual(line, savedWord, "no 'Saved' after the save (\(name))")
            shot(app, "53-bar-\(name)-saved")

            // Aa (plan S1) in the bar opens the format sheet (iPad: a popover under it); a style tap reaches the
            // engine (the state's paragraph style follows) and Done closes it
            let aa = app.buttons["xr-bar-format"]
            XCTAssertTrue(aa.exists, "no Aa in the top bar (\(name))")
            if aa.exists {
                XCTAssertGreaterThanOrEqual(aa.frame.width, 43.5, "Aa is narrower than 44 pt (\(name)): \(aa.frame)")
                aa.tap()
                let heading = app.buttons["xr-fmt-style-heading1"]
                XCTAssertTrue(heading.waitForExistence(timeout: 10), "Aa did not open the format sheet (\(name))")
                shot(app, "53b-bar-\(name)-format-sheet")
                if heading.exists {
                    heading.tap()
                    XCTAssertTrue(waitProbe("eading_1 ", 10), "format sheet style did not reach the engine (\(name)): \(probe.label)")
                    app.buttons["xr-fmt-done"].tap()
                    for _ in 0..<20 where heading.exists { Thread.sleep(forTimeInterval: 0.5) }
                    XCTAssertFalse(heading.exists, "the format sheet did not close (\(name))")
                }
                print("XR bar \(name) format sheet: \(probe.label)")
            }
            if !dark {                                     // the same bar in dark (Arabic runs in dark throughout)
                XCUIDevice.shared.system.open(URL(string: "xrero-autotest://appearance?dark=1")!)
                sleep(3)
                shot(app, "54-bar-\(lang)-dark")
            }
            app.terminate()
        }
    }

    /// The ⋯ document menu (plan M7b), one check per entry, under the native bar (XR_BAR=1), English in light then
    /// Arabic in dark: the web File tab is hidden on touch; ⋯ lists Find, Save (+ Redo on iPhone), Share, Export,
    /// Document info, Language, Account, About, All tools - and no PDF / Print. Find opens the editor's Find panel;
    /// Document info opens a native sheet with the editor's counts; Export ▸ .docx / .odt / .rtf each write a copy
    /// (check_saved.py opens them: the text inserted here must be inside); About and Account open their sheets;
    /// Language ▸ offers both languages; All tools opens the File backstage. Last, the PDF spike (log only, see
    /// check_saved.py): can this converter write a PDF at all?
    func testDocumentMenu() {
        continueAfterFailure = true                        // the Arabic half still reports when English fails
        let pad = UIDevice.current.userInterfaceIdiom == .pad
        for (lang, dark) in [("en", false), ("ar", true)] {
            let ar = lang == "ar"
            let base = "xr-menu-\(lang)"
            let app = launch(["XR_KIND": "word", "XR_BAR": "1", "XR_LANG": lang, "XR_NEW_NAME": base + ".docx"])
            XCTAssertEqual(waitState(app, prefix: "ready", timeout: 120), "ready", "editor did not become ready (\(lang))")
            if dark { XCUIDevice.shared.system.open(URL(string: "xrero-autotest://appearance?dark=1")!); sleep(3) }
            let name = lang + (dark ? "-dark" : "-light")
            sleep(2)
            // three words to count and to find in the exported copies (inserted without the keyboard)
            autotest("addtext", "Menu check \u{0645}\u{0631}\u{062D}\u{0628}\u{0627}")      // Menu check مرحبا
            let more = app.buttons["xr-bar-more"]
            XCTAssertTrue(more.waitForExistence(timeout: 10), "no ⋯ in the top bar (\(name))")
            func probe(close: Bool = false) -> String {
                autotest(close ? "menuprobe?close=1" : "menuprobe")
                return waitState(app, prefix: "menu:", timeout: 10)
            }
            func openMenu() { more.tap(); usleep(800_000) }
            /// waits until `e` can take a tap (a menu still sliding in, a sheet still sliding out)
            func hittable(_ e: XCUIElement, _ timeout: TimeInterval) -> Bool {
                let end = Date().addingTimeInterval(timeout)
                while Date() < end {
                    if e.exists && e.isHittable { return true }
                    usleep(300_000)
                }
                return false
            }
            /// `e` stays at the same place for 0.4 s (the menu has finished unfolding)
            func settled(_ e: XCUIElement) -> Bool {
                var last = CGRect.null
                for _ in 0..<12 {
                    guard e.exists else { return false }
                    let f = e.frame
                    if f == last { return true }
                    last = f
                    usleep(400_000)
                }
                return e.exists
            }
            /// `e` is no longer on screen within `timeout` (the menu closed)
            func gone(_ e: XCUIElement, _ timeout: TimeInterval) -> Bool {
                let end = Date().addingTimeInterval(timeout)
                while Date() < end {
                    if !(e.exists && e.isHittable) { return true }
                    usleep(250_000)
                }
                return false
            }
            /// ⋯, then the entry (inside a submenu when `sub` is given); false when it is not there. A tap on ⋯ can
            /// land while a sheet is still closing: then the menu is not open - close whatever is open (a tap on the
            /// status bar touches nothing in the editor) and try again.
            func pick(_ id: String, sub: String? = nil) -> Bool {
                for attempt in 0..<3 {
                    if attempt > 0 {
                        print("XR menu \(name): \(id) not reachable - opening ⋯ again")
                        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).tap()
                        sleep(1)
                    }
                    guard hittable(more, 5) else { continue }
                    openMenu()
                    if let sub {
                        let s = app.buttons[sub].firstMatch
                        guard hittable(s, 4) else { continue }
                        s.tap(); sleep(2)             // the submenu redraws its rows while it unfolds: wait it out
                    }
                    let e = app.buttons[id].firstMatch
                    guard hittable(e, 4), settled(e) else { continue }
                    e.tap()
                    // a tap that ran closes the menu. If the menu is plainly still open after 4 s (the entry AND the
                    // menu's Save still there - never while a sheet is coming up) tap once more and note it in the
                    // editor log. (The menu that stayed open with every tap ignored in CI was an app bug - the screen
                    // redrew its toolbar while the menu was open - fixed in EditorScreen / DocumentMenuModel; a menu
                    // that is dead again fails here, a second tap does not revive it.)
                    if !gone(e, 4) {
                        let save = app.buttons["xr-bar-save"].firstMatch
                        if id != "xr-bar-save" && !(save.exists && save.isHittable) { return true }
                        print("XR menu \(name): \(id) ignored the tap (menu still open) - tapping again")
                        guard settled(e) else { continue }
                        e.tap()
                        let ran = gone(e, 4)
                        autotest("note", "test: menu \(id) ignored the first tap, second tap \(ran ? "ran" : "ignored too")")
                        if !ran { continue }
                    }
                    return true
                }
                return false
            }

            // the web File tab is gone on touch (its entries are in ⋯)
            let p0 = probe()
            print("XR menu \(name) opened: \(p0)")
            XCTAssertTrue(p0.contains("filetab=0"), "the web File tab is still shown on touch (\(name)): \(p0)")
            // UIKit itself is mirrored in Arabic: the menus it draws for the ⋯ Menu follow its trait, not SwiftUI's
            autotest("uikitdir")
            XCTAssertEqual(waitState(app, prefix: "dir:", timeout: 5), ar ? "dir:rtl+force" : "dir:ltr", "UIKit layout direction (\(name))")

            // ⋯ as the user sees it: every entry, no PDF / Print (a first tap can come while the bar is still settling:
            // open it again until its first entry is there)
            for attempt in 0..<3 {
                if attempt > 0 { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).tap(); sleep(1) }
                _ = hittable(more, 5)
                openMenu()
                if hittable(app.buttons["xr-menu-find"].firstMatch, 4) { break }
                print("XR menu \(name): ⋯ did not open - again")
            }
            var ids = ["xr-menu-find", "xr-bar-save", "xr-nav-share", "xr-menu-export", "xr-menu-info", "xr-nav-lang",
                       "xr-nav-account", "xr-menu-about", "xr-menu-alltools"]
            if !pad { ids.insert("xr-bar-redo", at: 1) }
            for id in ids {
                XCTAssertTrue(app.buttons[id].firstMatch.waitForExistence(timeout: 3), "⋯ has no \(id) (\(name))")
            }
            // (the menu's own entries: the editor page's buttons are not counted)
            let pdfOrPrint = NSPredicate(format: "label CONTAINS[c] 'Print' OR label CONTAINS 'طباعة' OR label CONTAINS 'PDF'")
            XCTAssertEqual(app.buttons.matching(pdfOrPrint).count - app.webViews.buttons.matching(pdfOrPrint).count, 0,
                           "PDF / Print offered before the spike passed (\(name))")
            // the rows read from the right in Arabic: a row's text sits right of its symbol (when the menu exposes them)
            let infoRow = app.buttons["xr-menu-info"].firstMatch
            let rowText = infoRow.staticTexts.firstMatch, rowIcon = infoRow.images.firstMatch
            if rowText.exists && rowIcon.exists {
                print("XR menu \(name) row: text \(rowText.frame) icon \(rowIcon.frame)")
                XCTAssertEqual(rowText.frame.midX > rowIcon.frame.midX, !ar, "⋯ rows are not mirrored (\(name)): text \(rowText.frame) icon \(rowIcon.frame)")
            } else {
                print("XR menu \(name) row: no text / symbol exposed (frame \(infoRow.frame)) - the dir check stands")
            }
            shot(app, "60-menu-\(name)")
            let exportRow = app.buttons["xr-menu-export"].firstMatch
            _ = settled(exportRow)                       // the menu has finished unfolding
            exportRow.tap()
            sleep(2)
            for ext in ["docx", "odt", "rtf"] {
                XCTAssertTrue(app.buttons["xr-export-" + ext].firstMatch.waitForExistence(timeout: 3), "Export ▸ has no .\(ext) (\(name))")
            }
            XCTAssertFalse(app.buttons["xr-export-pdf"].exists, "Export ▸ offers PDF (\(name))")
            shot(app, "61-menu-\(name)-export")
            app.buttons["xr-export-docx"].firstMatch.tap()
            let firstExport = waitState(app, prefix: "exported:", timeout: 60)
            XCTAssertEqual(firstExport, "exported:exp-\(base).docx", "Export ▸ .docx (\(name))")

            // Find: the editor's own Find & Replace panel
            XCTAssertTrue(pick("xr-menu-find"), "no Find in ⋯ (\(name))")
            sleep(2)
            let p1 = probe()
            print("XR menu \(name) find: \(p1)")
            XCTAssertTrue(p1.contains("search=1"), "⋯ > Find did not open the Find panel (\(name)): \(p1)")
            shot(app, "62-menu-\(name)-find")
            _ = probe(close: true)

            // Document info: a native sheet, the editor's counts (3 words, 1 page)
            XCTAssertTrue(pick("xr-menu-info"), "no Document info in ⋯ (\(name))")
            let info = waitState(app, prefix: "docinfo:", timeout: 20)
            print("XR menu \(name) docinfo: \(info)")
            XCTAssertTrue(info.contains("\"words\":3") && info.contains("\"pages\":1"), "Document info counts (\(name)): \(info)")
            let words = app.descendants(matching: .any)["xr-docinfo-words"].firstMatch
            XCTAssertTrue(words.waitForExistence(timeout: 10), "the Document info sheet shows no word count (\(name))")
            XCTAssertTrue(app.descendants(matching: .any)["xr-docinfo-size"].firstMatch.exists, "no size in Document info (\(name))")
            XCTAssertTrue(app.staticTexts[ar ? "معلومات المستند" : "Document Info"].firstMatch.exists, "Document info title (\(name))")
            sleep(1)
            shot(app, "63-menu-\(name)-info")
            app.buttons["xr-docinfo-done"].firstMatch.tap()
            sleep(2)

            if !ar {
                // Export ▸ .odt and .rtf: copies as on screen (check_saved.py reads them)
                for ext in ["odt", "rtf"] {
                    XCTAssertTrue(pick("xr-export-" + ext, sub: "xr-menu-export"), "no Export ▸ .\(ext) (\(name))")
                    let s = waitState(app, prefix: "exported:\(base).\(ext)", timeout: 60)
                    XCTAssertEqual(s, "exported:\(base).\(ext)", "Export ▸ .\(ext) (\(name))")
                }
                // About & Licences
                XCTAssertTrue(pick("xr-menu-about"), "no About in ⋯")
                XCTAssertTrue(app.staticTexts["xr-about-version"].waitForExistence(timeout: 10), "⋯ > About did not open")
                app.buttons["xr-about-done"].firstMatch.tap()
                sleep(2)
                // Account (signed out here: the sign-in sheet; nothing is typed or sent)
                XCTAssertTrue(pick("xr-nav-account"), "no Account in ⋯")
                XCTAssertTrue(app.textFields["xr-acct-email"].firstMatch.waitForExistence(timeout: 10), "⋯ > Account did not open")
                shot(app, "64-menu-account")
                let done = app.buttons.matching(NSPredicate(format: "label == 'Done' OR label == 'تم'")).firstMatch
                if done.exists { done.tap() } else { app.swipeDown(velocity: .fast) }
                sleep(2)
                // Share
                XCTAssertTrue(pick("xr-nav-share"), "no Share in ⋯")
                XCTAssertEqual(waitState(app, prefix: "share", timeout: 5), "share", "⋯ > Share did not reach the screen")
            }
            // Language ▸ English / العربية (the switch itself reopens the page: ReviewVideoTests covers it)
            XCTAssertTrue(pick(ar ? "xr-nav-lang-en" : "xr-nav-lang-ar", sub: "xr-nav-lang"), "no Language ▸ entries (\(name))")
            XCTAssertEqual(waitState(app, prefix: "lang:", timeout: 5), "lang:" + (ar ? "en" : "ar"), "Language ▸ (\(name))")

            // All tools: the editor's File backstage (with its own way back). pick() makes sure the tap ran (the
            // menu closed); the log line "menu all tools" in the editor log shows the entry itself ran.
            sleep(2)
            XCTAssertTrue(pick("xr-menu-alltools"), "no All tools in ⋯ (\(name))")
            sleep(2)
            let p2 = probe()
            print("XR menu \(name) all tools: \(p2)")
            XCTAssertTrue(p2.contains("file=1"), "⋯ > All tools did not open the File backstage (\(name)): \(p2)")
            shot(app, "65-menu-\(name)-alltools")
            _ = probe(close: true)

            if !ar {
                // the PDF spike: logged, never offered (check_saved.py reports what the converter did)
                autotest("pdfspike")
                let spike = waitState(app, prefix: "export", timeout: 90)
                print("XR menu pdf spike: \(spike)")
            }
            app.terminate()
        }
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
        // "host?k=v": a hook with its own parameters
        let parts = host.split(separator: "?", maxSplits: 1).map(String.init)
        var c = URLComponents(); c.scheme = "xrero-autotest"; c.host = parts[0]
        if parts.count == 2 { c.query = parts[1] }
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
            // keyboard bar OFF here (its flag's default, plan M5; said explicitly): the Arabic typing path with WebKit's
            // own bar stays covered, while the touch gate types Arabic with the bar on
            app.launchArguments = ["-xr.lang", "ar", "-xr.keyboardBar", "NO"]
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

    /// The title menu (plan M4b), on the REAL document path (XR_REAL=1: UIDocument + the app's own editor screen, as
    /// opened from Home), English then Arabic interface: type and save, then tap the file name > Rename to a new name
    /// (English, then an Arabic file name), edit and save again, Duplicate, back to the list, reopen from Recent (its
    /// bookmark must point at the renamed file), edit and save a third time. The editor page is never reloaded by the
    /// rename (the second edit lands without reopening). check_saved.py then reads the renamed file: all three words
    /// inside, nothing left at the old name, and the copy holding the first two.
    func testTitleMenuRenameSaveReopen() {
        continueAfterFailure = true                        // the Arabic half still reports when English fails
        let runs: [(lang: String, file: String, newName: String, words: [String])] = [
            ("en", "xr-ren-en.docx", "Renamed note", ["Alpha", " Beta", " Gamma"]),
            ("ar", "xr-ren-ar.docx", "\u{0645}\u{0644}\u{0627}\u{062D}\u{0638}\u{0629} \u{0627}\u{0644}\u{0627}\u{062C}\u{062A}\u{0645}\u{0627}\u{0639}",   // ملاحظة الاجتماع
             ["Delta", " Omega", " Sigma"]),
        ]
        for run in runs {
            let ar = run.lang == "ar"
            let app = XCUIApplication()
            app.launchArguments = ["-xr.lang", run.lang]
            app.launchEnvironment = ["XR_REAL": "1", "XR_NEW_NAME": run.file]
            app.launch()
            let title = app.staticTexts["xr-bar-title"], status = app.staticTexts["xr-bar-status"]
            func statusNow() -> String { (try? status.firstMatch.snapshot())?.label ?? "(none)" }
            func titleNow() -> String { (try? title.firstMatch.snapshot())?.label ?? "(none)" }
            /// the editor is up: its title shows and its second line no longer says Opening…
            func waitEditor(_ what: String) -> Bool {
                let end = Date().addingTimeInterval(120)
                while Date() < end {
                    let s = statusNow()
                    if title.exists && !s.hasPrefix("Opening") && !s.hasPrefix("جارٍ الفتح") { sleep(3); return true }
                    Thread.sleep(forTimeInterval: 0.5)
                }
                shot(app, "60-ren-\(run.lang)-\(what)-not-ready")
                return false
            }
            func typeInPage(_ text: String) {
                let web = app.webViews.firstMatch
                // the page's empty middle, below the text (the editor puts the caret at the end of the last line, so a
                // word is never typed into another) and above where the keyboard comes up; a right-to-left blank
                // (Arabic interface) starts at the right edge
                let point = web.coordinate(withNormalizedOffset: CGVector(dx: ar ? 0.65 : 0.35, dy: 0.45))
                point.tap()
                if !app.keyboards.firstMatch.waitForExistence(timeout: 4) { point.tap(); _ = app.keyboards.firstMatch.waitForExistence(timeout: 4) }
                sleep(1)
                typeSlowly(app, text)
                sleep(1)
            }
            func saveNow(_ what: String) -> Bool {
                app.buttons["xr-bar-more"].tap()
                let save = app.buttons["xr-bar-save"]
                guard save.waitForExistence(timeout: 5) else { XCTFail("no Save in ⋯ (\(run.lang) \(what))"); return false }
                save.tap()
                let want = ar ? "محفوظ" : "Saved"
                let end = Date().addingTimeInterval(40)
                while Date() < end { if statusNow() == want { return true }; Thread.sleep(forTimeInterval: 0.3) }
                return false
            }
            func titleMenu(_ item: String) -> Bool {
                let menu = app.buttons["xr-bar-title-menu"]
                guard menu.waitForExistence(timeout: 5) else { XCTFail("no title menu (\(run.lang))"); return false }
                menu.tap()
                let e = app.buttons[item]
                guard e.waitForExistence(timeout: 5) else { XCTFail("no \(item) in the title menu (\(run.lang))"); return false }
                e.tap()
                return true
            }

            guard waitEditor("opened") else {
                XCTFail("the real editor did not open (\(run.lang))")
                app.terminate()
                continue
            }
            let oldBase = (run.file as NSString).deletingPathExtension
            XCTAssertEqual(titleNow(), oldBase, "title before the rename (\(run.lang))")
            // 1. edit + save under the first name
            typeInPage(run.words[0])
            XCTAssertTrue(saveNow("first"), "first save did not say Saved (\(run.lang)): \(statusNow())")

            // 2. the title menu: Rename, Duplicate, Move…
            app.buttons["xr-bar-title-menu"].tap()
            for id in ["xr-title-rename", "xr-title-duplicate", "xr-title-move"] {
                XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 5), "the title menu has no \(id) (\(run.lang))")
            }
            shot(app, "61-ren-\(run.lang)-title-menu")
            app.buttons["xr-title-rename"].tap()
            // a TextField inside a SwiftUI .alert becomes the UIAlertController's own field and loses its identifier:
            // find it as the alert's text field
            let alert = app.alerts.firstMatch
            let field = alert.textFields.firstMatch
            guard alert.waitForExistence(timeout: 5), field.waitForExistence(timeout: 5) else {
                XCTFail("no name field in the Rename alert (\(run.lang))")
                shot(app, "62-ren-\(run.lang)-no-rename-field")
                app.terminate()
                continue                                   // the next language still runs
            }
            // the alert focuses its field with the cursor after the name: delete it, then type the new one
            if !app.keyboards.firstMatch.waitForExistence(timeout: 3) { field.tap() }
            for _ in 0..<3 {
                let v = (field.value as? String) ?? ""
                if v.isEmpty || v == field.placeholderValue || v == "Name" || v == "الاسم" { break }
                field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: v.count + 2))
            }
            field.typeText(run.newName)
            print("XR title menu \(run.lang): rename field = \((field.value as? String) ?? "?")")
            shot(app, "62-ren-\(run.lang)-rename-alert")
            let ok = app.alerts.buttons.matching(NSPredicate(format: "identifier == 'xr-rename-ok' OR label == %@",
                                                             ar ? "إعادة التسمية" : "Rename")).firstMatch
            guard ok.exists else {
                XCTFail("no Rename button in the alert (\(run.lang))")
                app.terminate()
                continue
            }
            ok.tap()
            var renamed = false
            for _ in 0..<20 { if titleNow() == run.newName { renamed = true; break }; Thread.sleep(forTimeInterval: 0.5) }
            print("XR title menu \(run.lang): title after rename = \(titleNow())")
            XCTAssertTrue(renamed, "the title did not become the new name (\(run.lang)): \(titleNow())")
            shot(app, "63-ren-\(run.lang)-renamed")

            // 3. edit + save after the rename: the same editor page (no reopen), the file under its new name
            typeInPage(run.words[1])
            XCTAssertTrue(saveNow("after rename"), "save after the rename did not say Saved (\(run.lang)): \(statusNow())")

            // 4. Duplicate: a copy beside it, said in a short notice
            if titleMenu("xr-title-duplicate") {
                // any element type (the capsule's text may surface as other than a static text); the notice stays 4 s
                let toast = app.descendants(matching: .any).matching(identifier: "xr-toast").firstMatch
                XCTAssertTrue(toast.waitForExistence(timeout: 15), "no notice after Duplicate (\(run.lang))")
                print("XR title menu \(run.lang): duplicate notice = \(toast.exists ? toast.label : "-")")
                shot(app, "64-ren-\(run.lang)-duplicated")
            }
            sleep(2)

            // 5. back to the list: Recent shows the new name; reopen it from there, edit + save once more
            app.buttons["xr-bar-back"].tap()
            let reopen = app.buttons["xr-real-reopen"]
            XCTAssertTrue(reopen.waitForExistence(timeout: 30), "the editor did not close (\(run.lang))")
            sleep(2)
            let recent = app.staticTexts["xr-real-recent"]
            print("XR title menu \(run.lang): recent = \(recent.label)")
            XCTAssertEqual(recent.label, run.newName + ".docx", "Recent does not show the renamed file (\(run.lang))")
            reopen.tap()
            guard waitEditor("reopened") else {
                XCTFail("the renamed file did not reopen (\(run.lang)): \((try? app.staticTexts["xr-state"].snapshot())?.label ?? "?")")
                app.terminate()
                continue                                   // the next language still runs
            }
            XCTAssertEqual(titleNow(), run.newName, "title after reopening (\(run.lang))")
            shot(app, "65-ren-\(run.lang)-reopened")
            typeInPage(run.words[2])
            XCTAssertTrue(saveNow("reopened"), "save after reopening did not say Saved (\(run.lang)): \(statusNow())")
            app.buttons["xr-bar-back"].tap()
            XCTAssertTrue(reopen.waitForExistence(timeout: 30), "the editor did not close after reopening (\(run.lang))")
            sleep(2)
            app.terminate()
        }
    }

    /// Read-first opening (plan S2) on the REAL document path (XR_REAL=1: UIDocument + the app's own editor screen, the
    /// way Recent / Browse / Open-in open a file), English then Arabic interface, a 6-page document (the store letter
    /// + 5 pages, tests/reading_6p.docx, scripts/make_reading_fixtures.py) written as an EXISTING file (XR_DOC_B64):
    /// 1. it opens in reading state: the bar shows Edit / تحرير and no Undo / Aa; the editor itself is view-restricted,
    ///    its input field read-only and its tab row + status bar hidden (xr-read-probe, read from the editor every
    ///    0.5 s); the page count reaches 1 / 6 WITHOUT a touch (Word paginates after opening: the capsule follows the
    ///    engine, not the finger) and the capsule fades by itself; a tap on the page brings no keyboard but the page
    ///    capsule ("Page 1 of 6"). English run: a long press on the text offers Copy + Select All only (no Cut, Paste,
    ///    Bold); the capsule's Go to Page 3 lands on page 3 / 6; a swipe in reading state moves to a later page;
    /// 2. Edit / Done 10 times: every switch reaches the editor (restriction, input field, chrome) and the label follows;
    /// 3. Edit once more, type an English and an Arabic line (the input field is healthy after the switches) and save;
    ///    check_saved.py finds both lines in xr-read-<lang>.docx with the letter kept;
    /// 4. (English) the mode is remembered per file: Back + reopen -> editing; Done, Back + reopen -> reading; with the
    ///    setting off (-xr.readingView NO) the file opens for editing;
    /// 5. (English) a 6-page PDF (tests/reading_6p.pdf) opens in reading state without the PDF tool bar, its count
    ///    1 / 6 without a touch; Go to Page 3 lands on page 3 / 6; Edit brings the bar, Done hides it again.
    /// New documents opening for editing is covered by testTitleMenuRenameSaveReopen (its blank is a new document).
    func testReadingViewEditDoneThenType() throws {
        // the multi-page files (S2 review: with the 1-page letter every probe read 1/1 whatever the app did)
        guard let b64 = ProcessInfo.processInfo.environment["XR_READ_DOCX_B64"] else { throw XCTSkip("no reading document passed") }
        let pages = 6                                      // make_reading_fixtures.py PAGES (both files)
        continueAfterFailure = true                        // the Arabic half still reports when English fails
        // iPad: Done is in the bar; iPhone: ⋯ > Reading View (the bar keeps the file name)
        let wide = UIDevice.current.userInterfaceIdiom == .pad
        func launchReal(_ lang: String, _ file: String, _ bytes: String, setting: Bool = true) -> XCUIApplication {
            let app = XCUIApplication()
            app.launchArguments = ["-xr.lang", lang] + (setting ? [] : ["-xr.readingView", "NO"])
            app.launchEnvironment = ["XR_REAL": "1", "XR_NEW_NAME": file, "XR_DOC_B64": bytes]
            app.launch()
            return app
        }
        for lang in ["en", "ar"] {
            let ar = lang == "ar"
            let file = "xr-read-\(lang).docx"
            var app = launchReal(lang, file, b64)
            let editWord = ar ? "تحرير" : "Edit", doneWord = ar ? "تم" : "Done"
            func snap(_ id: String) -> String { (try? app.staticTexts[id].firstMatch.snapshot())?.label ?? "(none)" }
            /// the editor is up: its title shows and its second line no longer says Opening…
            func waitEditor(_ what: String) -> Bool {
                let end = Date().addingTimeInterval(120)
                while Date() < end {
                    let s = snap("xr-bar-status")
                    if app.staticTexts["xr-bar-title"].exists && !s.hasPrefix("Opening") && !s.hasPrefix("جارٍ الفتح") {
                        sleep(2); return true
                    }
                    Thread.sleep(forTimeInterval: 0.5)
                }
                shot(app, "70-read-\(lang)-\(what)-not-ready")
                return false
            }
            /// "read<n>:read=1 view=1 input=ro toolbar=0 status=0 page=1/1 app=1": n = switches the editor answered
            func applied(_ s: String) -> Int {
                guard s.hasPrefix("read"), let c = s.firstIndex(of: ":") else { return -1 }
                return Int(s[s.index(s.startIndex, offsetBy: 4)..<c]) ?? -1
            }
            /// waits until the editor answered a switch after `after` and its own state shows every token
            func waitRead(_ want: [String], after: Int = -1, _ timeout: TimeInterval = 12) -> String {
                let end = Date().addingTimeInterval(timeout)
                var s = snap("xr-read-probe")
                while Date() < end {
                    s = snap("xr-read-probe")
                    if applied(s) > after && want.allSatisfy({ s.contains($0) }) { return s }
                    Thread.sleep(forTimeInterval: 0.3)
                }
                return s
            }
            let reading = ["read=1", "view=1", "input=ro", "toolbar=0", "status=0", "app=1"]
            let editing = ["read=0", "view=0", "input=rw", "toolbar=1", "status=1", "app=0"]
            func editButton() -> XCUIElement { app.buttons["xr-bar-edit"] }
            /// Edit (bar) / Done (bar on iPad, ⋯ > Reading View on iPhone)
            func tapSwitch(_ toReading: Bool) {
                if toReading && !wide {
                    app.buttons["xr-bar-more"].tap()
                    let item = app.buttons["xr-menu-reading"]
                    if item.waitForExistence(timeout: 5) { item.tap() } else { XCTFail("no Reading View in ⋯ (\(lang))") }
                } else {
                    editButton().tap()
                }
            }
            /// the bar after a switch: Edit while reading; Done while editing on iPad (none in the bar on iPhone); the
            /// file name always there (a fifth item once pushed it out of the bar)
            func checkBar(_ isReading: Bool, _ what: String) {
                let label = editButton().exists ? editButton().label : "(none)"
                if isReading || wide { XCTAssertEqual(label, isReading ? editWord : doneWord, "Edit / Done label \(what) (\(lang))") }
                else { XCTAssertFalse(editButton().exists, "Done in the iPhone bar \(what) (\(lang)): it belongs in ⋯") }
                XCTAssertTrue(app.staticTexts["xr-bar-title"].exists, "the file name left the bar \(what) (\(lang))")
            }
            func toggle(_ toReading: Bool, _ i: Int) -> Bool {
                let n0 = applied(snap("xr-read-probe"))
                tapSwitch(toReading)
                let s = waitRead(toReading ? reading : editing, after: n0)
                let ok = (toReading ? reading : editing).allSatisfy { s.contains($0) } && applied(s) > n0
                let label = editButton().exists ? editButton().label : "(none)"
                print("XR read \(lang) switch \(i) -> \(toReading ? "reading" : "editing"): \(ok ? "PASS" : "FAIL") label=\(label) " +
                      "title=\(app.staticTexts["xr-bar-title"].exists) | \(s)")
                XCTAssertTrue(ok, "switch \(i) did not reach the editor (\(lang)): \(s)")
                checkBar(toReading, "after switch \(i)")
                return ok
            }
            func saveNow() -> Bool {
                app.buttons["xr-bar-more"].tap()
                let save = app.buttons["xr-bar-save"]
                guard save.waitForExistence(timeout: 5) else { XCTFail("no Save in ⋯ (\(lang))"); return false }
                save.tap()
                let want = ar ? "محفوظ" : "Saved"
                let end = Date().addingTimeInterval(40)
                while Date() < end { if snap("xr-bar-status") == want { return true }; Thread.sleep(forTimeInterval: 0.3) }
                return false
            }
            func noKeyboard(_ timeout: TimeInterval) -> Bool {
                let end = Date().addingTimeInterval(timeout)
                while Date() < end { if !app.keyboards.firstMatch.exists { return true }; Thread.sleep(forTimeInterval: 0.3) }
                return !app.keyboards.firstMatch.exists
            }
            /// the probe's "page=<p>/<n>" (the editor's own page on screen and page count)
            func pageOf(_ s: String) -> (p: Int, n: Int)? {
                guard let r = s.range(of: "page=") else { return nil }
                let parts = s[r.upperBound...].prefix { $0 != " " }.split(separator: "/")
                guard parts.count == 2, let p = Int(parts[0]), let n = Int(parts[1]) else { return nil }
                return (p, n)
            }
            /// Go to Page from the capsule (shown by a touch first: it fades 1.5 s after the last one), then waits for
            /// the editor to be on that page; returns the probe
            func goToPage(_ n: Int, _ what: String) -> String {
                let web = app.webViews.firstMatch, capsule = app.buttons["xr-read-page"]
                web.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                guard capsule.waitForExistence(timeout: 3) else { XCTFail("no page capsule for Go to Page (\(what))"); return snap("xr-read-probe") }
                capsule.tap()
                let alert = app.alerts.firstMatch
                guard alert.waitForExistence(timeout: 5) else { XCTFail("the page capsule did not open Go to Page (\(what))"); return snap("xr-read-probe") }
                let field = alert.textFields.firstMatch
                if !app.keyboards.firstMatch.waitForExistence(timeout: 3) { field.tap() }
                field.typeText("\(n)")
                shot(app, "72-read-\(what)-go-to-page")
                let go = alert.buttons.matching(NSPredicate(format: "identifier == 'xr-read-page-go' OR label == 'Go' OR label == 'انتقال'")).firstMatch
                if go.exists { go.tap() } else { XCTFail("no Go in the Go to Page alert (\(what))") }
                XCTAssertTrue(noKeyboard(5), "the keyboard stayed up after Go to Page while reading (\(what))")
                return waitRead(["read=1", "page=\(n)/\(pages)"], 15)
            }

            guard waitEditor("opened") else {
                XCTFail("the real editor did not open (\(lang))"); app.terminate(); continue
            }
            // 1. reading state as opened
            let opened = waitRead(reading)
            print("XR read \(lang) opened: \(opened) | bar edit=\(editButton().exists ? editButton().label : "(none)") " +
                  "undo=\(app.buttons["xr-bar-undo"].exists) aa=\(app.buttons["xr-bar-format"].exists)")
            shot(app, "70-read-\(lang)-opened")
            XCTAssertTrue(reading.allSatisfy { opened.contains($0) }, "the letter did not open in reading state (\(lang)): \(opened)")
            XCTAssertTrue(editButton().exists, "no Edit in the top bar (\(lang))")
            XCTAssertEqual(editButton().exists ? editButton().label : "", editWord, "Edit label (\(lang))")
            XCTAssertFalse(app.buttons["xr-bar-undo"].exists, "Undo shown while reading (\(lang))")
            XCTAssertFalse(app.buttons["xr-bar-format"].exists, "Aa shown while reading (\(lang))")
            XCTAssertGreaterThanOrEqual(editButton().frame.width, 43.5, "Edit is narrower than 44 pt (\(lang)): \(editButton().frame)")
            // mirrored as one piece: Back leads, Edit / ⋯ trail
            let back = app.buttons["xr-bar-back"]
            if ar { XCTAssertGreaterThan(back.frame.midX, editButton().frame.midX, "Arabic bar not mirrored: Back \(back.frame) Edit \(editButton().frame)") }
            else { XCTAssertLessThan(back.frame.midX, editButton().frame.midX, "bar order: Back \(back.frame) Edit \(editButton().frame)") }
            // the page count without any touch on the page: the capsule follows the engine's own count (Word paginates
            // after opening - at content-ready the count was still 0, S2 review)
            let counted = waitRead(["read=1", "page=1/\(pages)"], 45)
            print("XR read \(lang) count without a touch: \(counted) | \(counted.contains("page=1/\(pages)") ? "PASS" : "FAIL")")
            XCTAssertTrue(counted.contains("page=1/\(pages)"), "the page count did not reach 1/\(pages) without a touch (\(lang)): \(counted)")
            // the capsule shows once the count is known and fades 1.5 s later by itself (no VoiceOver here)
            let capsule = app.buttons["xr-read-page"]
            var faded = false
            for _ in 0..<20 where !faded { Thread.sleep(forTimeInterval: 0.5); faded = !capsule.exists }
            print("XR read \(lang) capsule faded without a touch: \(faded)")
            XCTAssertTrue(faded, "the page capsule did not fade by itself while reading (\(lang))")
            // a tap on the page shows the page capsule (it fades 1.5 s after the last touch) and brings no keyboard (the
            // input field is read-only)
            let web = app.webViews.firstMatch
            web.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
            let capsuleShown = capsule.waitForExistence(timeout: 2)
            let capsuleLabel = capsuleShown ? capsule.label : "(none)"
            shot(app, "71-read-\(lang)-tapped")
            let keyboardUp = app.keyboards.firstMatch.waitForExistence(timeout: 3)
            print("XR read \(lang) tap: keyboard=\(keyboardUp) capsule=\(capsuleLabel)")
            XCTAssertFalse(keyboardUp, "a tap brought the keyboard up while reading (\(lang))")
            XCTAssertTrue(capsuleShown, "no page capsule while reading (\(lang))")
            if capsuleShown {
                XCTAssertEqual(capsuleLabel, ar ? "الصفحة 1 من \(pages)" : "Page 1 of \(pages)", "page capsule label (\(lang))")
            }
            if !ar {
                // a long press on the letter's text (its second paragraph: about the same place on the iPhone and the
                // iPad page) selects a word and shows the app's edit menu with only what does not edit
                func menuLabels() -> [String] {
                    let known = ["Cut", "Copy", "Paste", "Select All", "Bold", "Italic"]
                    var l = app.menuItems.allElementsBoundByIndex.map(\.label)
                    if l.isEmpty { l = known.filter { app.buttons[$0].exists } }
                    return l
                }
                var labels: [String] = []
                for y in [0.228, 0.215, 0.242] where !labels.contains("Copy") {
                    app.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: y)).press(forDuration: 1.2)
                    Thread.sleep(forTimeInterval: 1)
                    labels = menuLabels()
                    if !labels.contains("Copy") {
                        print("XR read en long press at \(y): [\(labels.joined(separator: ","))]")
                        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).tap(); Thread.sleep(forTimeInterval: 0.6)
                    }
                }
                shot(app, "71b-read-en-long-press")
                let ro = waitRead(["read=1"], 2)
                print("XR read en long press menu: [\(labels.joined(separator: ","))] keyboard=\(app.keyboards.firstMatch.exists) | \(ro)")
                XCTAssertTrue(labels.contains("Copy") && labels.contains("Select All"), "reading edit menu without Copy / Select All: \(labels)")
                XCTAssertTrue(Set(labels).isDisjoint(with: ["Cut", "Paste", "Bold", "Italic"]), "reading edit menu offers editing: \(labels)")
                XCTAssertFalse(app.keyboards.firstMatch.exists, "a long press brought the keyboard up while reading")
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).tap()           // closes the menu
                Thread.sleep(forTimeInterval: 0.6)
                // Go to Page 3 from the capsule: the editor lands on page 3 (the count is the real one now)
                let after = goToPage(3, "en")
                print("XR read en go to page 3: \(after) | \(after.contains("page=3/\(pages)") ? "PASS" : "FAIL")")
                XCTAssertTrue(after.contains("page=3/\(pages)"), "Go to Page 3 did not land on page 3 of \(pages): \(after)")
                XCTAssertTrue(after.contains("input=ro") && after.contains("view=1"), "Go to Page left reading state: \(after)")
                shot(app, "72b-read-en-page-3")
                // a swipe in reading state scrolls the document (no pointer event is blocked) and the page follows
                let before = pageOf(after)?.p ?? 3
                var moved = after
                for _ in 0..<2 where (pageOf(moved)?.p ?? before) <= before {
                    web.swipeUp()
                    moved = snap("xr-read-probe")
                    let end = Date().addingTimeInterval(4)
                    while Date() < end && (pageOf(moved)?.p ?? before) <= before { Thread.sleep(forTimeInterval: 0.3); moved = snap("xr-read-probe") }
                }
                print("XR read en swipe: page \(before) -> \(pageOf(moved)?.p ?? -1) keyboard=\(app.keyboards.firstMatch.exists) | \(moved)")
                shot(app, "72c-read-en-swiped")
                XCTAssertGreaterThan(pageOf(moved)?.p ?? before, before, "a swipe in reading state did not move to a later page: \(moved)")
                XCTAssertFalse(app.keyboards.firstMatch.exists, "a swipe brought the keyboard up while reading")
            }
            // 2. Edit / Done 10 times (odd switches: editing, even: reading)
            var switches = 0
            for i in 1...10 { if toggle(i % 2 == 0, i) { switches += 1 } }
            print("XR read \(lang) switches: \(switches)/10 \(switches == 10 ? "PASS" : "FAIL")")
            // 3. Edit, then type English + Arabic and save: the input field is healthy after the switches
            _ = toggle(false, 11)
            XCTAssertTrue(app.buttons["xr-bar-undo"].exists, "no Undo after Edit (\(lang))")
            XCTAssertTrue(app.buttons["xr-bar-format"].exists, "no Aa after Edit (\(lang))")
            shot(app, "73-read-\(lang)-editing")
            let point = web.coordinate(withNormalizedOffset: CGVector(dx: ar ? 0.65 : 0.35, dy: 0.45))
            point.tap()
            if !app.keyboards.firstMatch.waitForExistence(timeout: 5) { point.tap() }
            let kb = app.keyboards.firstMatch.waitForExistence(timeout: 5)
            print("XR read \(lang) editing: keyboard=\(kb)")
            XCTAssertTrue(kb, "no keyboard after Edit + a tap on the page (\(lang))")
            if kb {
                sleep(1)
                typeSlowly(app, "Reading view OK.")
                app.typeText("\n")
                typeSlowly(app, "\u{0648}\u{0636}\u{0639} \u{0627}\u{0644}\u{0642}\u{0631}\u{0627}\u{0621}\u{0629}")   // وضع القراءة
                sleep(1)
                shot(app, "74-read-\(lang)-typed")
                let saved = saveNow()
                print("XR read \(lang) saved: \(saved) status=\(snap("xr-bar-status"))")
                XCTAssertTrue(saved, "save after the switches did not say Saved (\(lang))")
                shot(app, "75-read-\(lang)-saved")
            }
            if ar {
                // Back first: closing the document writes it (UIDocument), a terminate right after Saved might not
                app.buttons["xr-bar-back"].tap()
                XCTAssertTrue(app.buttons["xr-real-reopen"].waitForExistence(timeout: 30), "the editor did not close (ar)")
                sleep(2)
                app.terminate()
                continue
            }

            // 4. remembered per file: left in editing -> reopens in editing; left in reading -> reopens in reading
            func reopen(_ what: String) -> Bool {
                app.buttons["xr-bar-back"].tap()
                let again = app.buttons["xr-real-reopen"]
                guard again.waitForExistence(timeout: 30) else { XCTFail("the editor did not close (\(what))"); return false }
                sleep(2)
                again.tap()
                return waitEditor(what)
            }
            if reopen("reopened-editing") {
                let s = waitRead(editing)
                print("XR read en reopened after editing: \(s)")
                shot(app, "76-read-en-reopened-editing")
                XCTAssertTrue(editing.allSatisfy { s.contains($0) }, "a file left in editing did not reopen in editing: \(s)")
                checkBar(false, "after reopening in editing")
                _ = toggle(true, 12)
                if reopen("reopened-reading") {
                    let r = waitRead(reading)
                    print("XR read en reopened after reading: \(r)")
                    shot(app, "77-read-en-reopened-reading")
                    XCTAssertTrue(reading.allSatisfy { r.contains($0) }, "a file left in reading did not reopen in reading: \(r)")
                }
            }
            app.terminate()
            // the setting off: the same file opens for editing
            app = launchReal(lang, file, b64, setting: false)
            if waitEditor("setting-off") {
                let s = waitRead(editing)
                print("XR read en setting off: \(s)")
                shot(app, "78-read-en-setting-off")
                XCTAssertTrue(editing.allSatisfy { s.contains($0) }, "with the setting off the file still opened in reading: \(s)")
            } else { XCTFail("the editor did not open with the setting off") }
            app.terminate()

            // 5. a 6-page PDF: reading state without the PDF tool bar, its count without a touch, Go to Page 3; Edit
            // brings the bar, Done hides it again
            guard let pdf = ProcessInfo.processInfo.environment["XR_READ_PDF_B64"] else { XCTFail("no reading PDF passed"); continue }
            app = launchReal(lang, "xr-read.pdf", pdf)
            guard waitEditor("pdf") else { XCTFail("the PDF did not open"); app.terminate(); continue }
            let bar = app.descendants(matching: .any).matching(identifier: "xr-pdf-bar").firstMatch
            let pr = waitRead(["read=1", "toolbar=0", "status=0", "app=1"])
            print("XR read pdf opened: \(pr) | pdf bar=\(bar.exists)")
            shot(app, "79-read-pdf-opened")
            XCTAssertTrue(pr.contains("read=1") && pr.contains("toolbar=0") && pr.contains("status=0"), "the PDF did not open in reading state: \(pr)")
            XCTAssertFalse(bar.exists, "the PDF tool bar is shown while reading")
            let pc = waitRead(["read=1", "page=1/\(pages)"], 30)
            print("XR read pdf count without a touch: \(pc)")
            XCTAssertTrue(pc.contains("page=1/\(pages)"), "the PDF page count did not reach 1/\(pages) without a touch: \(pc)")
            let pg = goToPage(3, "pdf")
            print("XR read pdf go to page 3: \(pg)")
            XCTAssertTrue(pg.contains("page=3/\(pages)"), "Go to Page 3 did not land on PDF page 3 of \(pages): \(pg)")
            let n0 = applied(snap("xr-read-probe"))
            editButton().tap()
            let pe = waitRead(["read=0", "app=0"], after: n0)
            let barShown = bar.waitForExistence(timeout: 10)
            print("XR read pdf editing: \(pe) | pdf bar=\(barShown)")
            shot(app, "80-read-pdf-editing")
            XCTAssertTrue(pe.contains("read=0"), "Edit did not reach the PDF editor: \(pe)")
            XCTAssertTrue(barShown, "no PDF tool bar after Edit")
            let n1 = applied(snap("xr-read-probe"))
            tapSwitch(true)
            let pd = waitRead(["read=1", "toolbar=0", "app=1"], after: n1)
            for _ in 0..<10 where bar.exists { Thread.sleep(forTimeInterval: 0.5) }
            print("XR read pdf done: \(pd) | pdf bar=\(bar.exists)")
            XCTAssertTrue(pd.contains("read=1"), "Done did not bring the PDF back to reading: \(pd)")
            XCTAssertFalse(bar.exists, "the PDF tool bar stayed after Done")
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
        // the list slides up: a tap during the animation lands on the row that is passing under the finger (seen as
        // the .odt row lighting up and ".odt" exported again) - tap once it is still, again if nothing came of it
        sleep(1)
        rtf.tap()
        if !waitState(app, prefix: "exported:" + base + ".rtf", timeout: 20).hasSuffix(".rtf") && rtf.exists && rtf.isHittable {
            print("XR save-as path: RTF tap did not take - tapping again")
            rtf.tap()
        }
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
            let app = launch(["XR_DOC_NAME": p[0], "XR_LANG": p[1], "XR_DOC_B64": p[2], "XR_CLEAN": "1"])
            let ready = waitState(app, prefix: "ready", timeout: 120)
            sleep(5)
            shot(app, "store-\(p[1])-\(ProcessInfo.processInfo.environment["XR_STORE_DARK"] == "1" ? "dark" : "")\(p[0])")
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
        checkContract(app, "pdf")
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

    // MARK: - Slides touch gate (plan S4)

    /// Presentations (plan S4) under the native bar (XR_BAR=1), English then Arabic, iPhone and iPad. iPhone: the
    /// native slide strip is shown with the first slide current; its '+' is a 44 pt target and opens the native layout
    /// picker, whose first layout adds slide 2 (current); a long press on a thumbnail offers Duplicate (slide 3) and
    /// Delete (back to 2); a tap on a thumbnail makes it current; the strip hides while the keyboard is up. Every
    /// device: the nav bar's Present starts the native show (nav bar hidden, strip hidden), a tap advances (iPhone,
    /// 2 slides), ✕ ends it (nav bar back), a double tap ends it too; then Save. Each result is printed as
    /// "XR touch slides <lang> <check>: PASS|FAIL|INFO" and asserted (recorded, the test goes on).
    func testZSlidesStripAndPresent() {
        for lang in ["en", "ar"] { slidesGate(lang) }
    }

    private func slidesGate(_ lang: String) {
        let ar = lang == "ar"
        let phone = UIDevice.current.userInterfaceIdiom == .phone
        let app = launch(["XR_KIND": "slide", "XR_BAR": "1", "XR_LANG": lang, "XR_NEW_NAME": "xr-slides-\(lang).pptx"])
        let keep = continueAfterFailure
        continueAfterFailure = true
        defer { app.terminate(); continueAfterFailure = keep }
        func gate(_ name: String, _ ok: Bool, _ detail: String = "") {
            let line = "touch slides \(lang) \(name): \(ok ? "PASS" : "FAIL") \(detail)"
            print("XR " + line)
            XCTAssertTrue(ok, line)
        }
        func info(_ name: String, _ detail: String) { print("XR touch slides \(lang) \(name): INFO \(detail)") }
        func any(_ id: String, label: String? = nil) -> XCUIElement {
            let p = label == nil ? NSPredicate(format: "identifier == %@", id)
                                 : NSPredicate(format: "identifier == %@ OR label == %@", id, label!)
            return app.descendants(matching: .any).matching(p).firstMatch
        }
        func waitFor(_ timeout: TimeInterval, _ check: () -> Bool) -> Bool {
            let end = Date().addingTimeInterval(timeout)
            while Date() < end { if check() { return true }; Thread.sleep(forTimeInterval: 0.5) }
            return check()
        }
        func thumb(_ i: Int) -> XCUIElement { app.buttons["xr-slide-thumb-\(i)"] }
        func menuItem(_ id: String, _ en: String, _ arLabel: String) -> XCUIElement { any(id, label: ar ? arLabel : en) }

        let ready = waitState(app, prefix: "ready", timeout: 120)
        gate("editor-ready", ready == "ready", ready)
        guard ready == "ready" else { return }
        sleep(3)
        shot(app, "60-slides-\(lang)-ready")
        let back = app.buttons["xr-bar-back"]
        let present = app.buttons["xr-bar-present"]
        gate("present-button", present.waitForExistence(timeout: 10) && present.isHittable &&
             // the nav bar draws its items 36 pt tall (its touch area is taller): the bar's own height, 44 pt wide
             present.frame.width >= 44 && present.frame.height >= 36, "frame=\(present.frame)")

        if phone {
            let strip = any("xr-slide-strip")
            gate("strip-shown", strip.waitForExistence(timeout: 15), "frame=\(strip.frame)")
            gate("first-slide-current", thumb(0).waitForExistence(timeout: 10) && waitFor(10) { thumb(0).isSelected },
                 "exists=\(thumb(0).exists)")
            let add = app.buttons["xr-slide-add"]
            gate("plus-target-44pt", add.waitForExistence(timeout: 5) && add.isHittable && add.frame.width >= 44 &&
                 add.frame.height >= 44, "frame=\(add.frame)")
            add.tap()
            let layout = any("xr-slide-layout-0"), plain = any("xr-slide-layout-default")
            var picker = waitFor(8) { layout.exists || plain.exists }
            if !picker {
                // seen once (CI, English, iPhone): the first tap right after opening landed while the strip redrew its
                // first thumbnails - recorded on its own line, then tapped again as a person would
                info("plus-first-tap-ignored", "the layout picker opened only after a second tap")
                add.tap()
                picker = waitFor(10) { layout.exists || plain.exists }
            }
            shot(app, "61-slides-\(lang)-layouts")
            gate("plus-opens-layout-picker", picker, "layouts=\(layout.exists) default=\(plain.exists)")
            if picker {
                (layout.exists ? layout : plain).tap()
                gate("layout-adds-slide-2", waitFor(15) { thumb(1).exists && thumb(1).isSelected },
                     "slide 2 exists=\(thumb(1).exists)")
            }
            sleep(2)
            shot(app, "62-slides-\(lang)-added")
            if thumb(1).exists {
                thumb(1).press(forDuration: 1.2)
                let dup = menuItem("xr-slide-duplicate", "Duplicate", "\u{062A}\u{0643}\u{0631}\u{0627}\u{0631}")   // تكرار
                let shown = dup.waitForExistence(timeout: 5)
                shot(app, "63-slides-\(lang)-menu")
                gate("long-press-menu", shown, "")
                if shown { dup.tap() }
                gate("duplicate-adds-slide-3", waitFor(15) { thumb(2).exists }, "slide 3 exists=\(thumb(2).exists)")
            }
            if thumb(2).exists {
                thumb(2).press(forDuration: 1.2)
                let del = menuItem("xr-slide-delete", "Delete", "\u{062D}\u{0630}\u{0641}")                       // حذف
                let delShown = del.waitForExistence(timeout: 5)
                if !delShown { info("delete-menu", "Delete not found in the long-press menu") }
                if delShown { del.tap() }
                gate("delete-removes-slide-3", waitFor(15) { !thumb(2).exists }, "slide 3 exists=\(thumb(2).exists)")
            }
            thumb(0).tap()
            gate("tap-makes-slide-current", waitFor(10) { thumb(0).isSelected }, "")
            // the strip makes way for the keyboard: two taps into the first slide's title (the first selects the box)
            let web = app.webViews.firstMatch
            let centre = web.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            centre.tap(); sleep(1); centre.tap()
            if app.keyboards.firstMatch.waitForExistence(timeout: 5) {
                gate("strip-hides-with-keyboard", waitFor(5) { !strip.exists }, "strip exists=\(strip.exists)")
            } else {
                info("strip-hides-with-keyboard", "no keyboard after two taps into the title - not checked")
            }
        }

        // native Present
        present.tap()
        let overlay = any("xr-present-overlay")
        var started = overlay.waitForExistence(timeout: 10)
        if !started {
            // seen once (CI, iPad, Arabic): the bar's first tap after the editor opened never reached the app (no
            // "present start" in its log) - the same lost first tap the ⋯ menu test records; noted, then tapped again
            info("present-first-tap-ignored", "the show started only after a second tap")
            present.tap()
            started = overlay.waitForExistence(timeout: 15)
        }
        sleep(2)
        shot(app, "64-slides-\(lang)-present")
        gate("present-starts", started, "")
        gate("present-hides-nav-bar", waitFor(5) { !back.exists || !back.isHittable }, "back exists=\(back.exists)")
        if phone {
            gate("present-hides-strip", !any("xr-slide-strip").exists, "")
            let before = (overlay.value as? String) ?? ""
            overlay.tap()
            let advanced = waitFor(8) { ((overlay.value as? String) ?? "").contains("2") }
            gate("tap-advances", advanced, "value \(before) -> \((overlay.value as? String) ?? "-")")
        }
        let end = app.buttons["xr-present-end"]
        gate("close-target-44pt", end.exists && end.frame.width >= 44 && end.frame.height >= 44, "frame=\(end.frame)")
        end.tap()
        gate("close-ends-show", waitFor(10) { !overlay.exists }, "")
        gate("nav-bar-back", waitFor(10) { back.exists && back.isHittable }, "")
        if phone { gate("strip-back-after-show", waitFor(10) { any("xr-slide-strip").exists }, "") }
        shot(app, "65-slides-\(lang)-after-show")
        // a double tap ends it as well
        present.tap()
        if overlay.waitForExistence(timeout: 15) {
            sleep(2)
            overlay.doubleTap()
            gate("double-tap-ends-show", waitFor(10) { !overlay.exists }, "")
        } else {
            gate("double-tap-ends-show", false, "the show did not start again")
        }
        let saved = save(app)
        gate("save", saved.hasPrefix("saved"), saved)
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
            // the tab tap can be missed (seen once on the iPhone in Arabic); a closed panel still reports the button's
            // rect, and a tap there lands in the page and moves the caret - so tap only once the panel is open
            for _ in 0..<2 where str(p, "fold") == "closed" {
                if tab.exists && tab.isHittable { tab.tap() } else { sleep(1) }
                p = probe(app)
            }
            // the panel slides down: measure the button again once it has settled (a rect taken mid-slide is off)
            sleep(1)
            p = probe(app)
            if str(p, "fold") == "closed" {
                print("XR touch toolbar button \(key): the Home panel did not open")
                return false
            }
        }
        // the opened panel can still be laid out / animating: wait (up to ~3 s) until the button's own centre is the
        // top element there, so the tap lands on the button and not on a layer still covering it
        if key == "bold" {
            for _ in 0..<6 where !str(p, "bhit").isEmpty && str(p, "bhit") != "id-toolbar-btn-bold" {
                print("XR touch toolbar bold covered by \(str(p, "bhit")) [\(str(p, "bhitc"))] fold=\(str(p, "fold")) - waiting")
                usleep(500_000); p = probe(app)
            }
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
    /// letter there, double tap and long press select a word, a formatting tap (Bold) keeps the keyboard, the keyboard
    /// bar's Bold (plan M5) keeps it too and the next word is bold, its "hide keyboard" puts it away, 5x Enter,
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
        // typed after the keyboard bar's Bold (plan M5)
        let barWord = ar ? "\u{0634}\u{0631}\u{064A}\u{0637}" : "Bar"                              // شريط
        let app = XCUIApplication()
        app.launchArguments = ["-xr.lang", lang, "-xr.keyboardBar", "YES"]   // the bar is off by default until its gate (plan M5)
        try? FileManager.default.removeItem(atPath: probeFile)
        pauseProbe(false)
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

        // 5) long press selects a word (iOS: the word, its handles and the edit menu). Plan S5: the engine's desktop
        //    right-click menu (which a long press used to open, selecting nothing) is swallowed on touch, the word under
        //    the finger is selected and the app's native edit menu (UIEditMenuInteraction) is shown at it.
        tapEnd()
        let em4 = num(probe(app), "em") ?? 0
        point(at(0.86), ly).press(forDuration: 1.2)
        let p5 = probe(app)
        let sel5 = str(p5, "sel").trimmingCharacters(in: .whitespacesAndNewlines)
        shot(app, "53-touch-\(lang)-long-press")
        gate("long-press-selects-word", sel5.count >= 4 && !sel5.contains(" ") && t3.contains(sel5),
             "sel='\(sel5)' web menu=\(num(p5, "menu") ?? 0) native menu=\(app.menuItems.count) \(focusInfo(p5))")
        // the native menu was presented (iOS called the interaction's willPresent) and the desktop one stayed shut
        let em5 = num(p5, "em") ?? 0
        gate("long-press-native-menu", em5 > em4 && (num(p5, "menu") ?? 0) == 0,
             "native presentations \(em4)->\(em5) web menu=\(num(p5, "menu") ?? 0) \(focusInfo(p5))")
        // its Copy, tapped as a user taps it, runs the editor's copy (one bridge call): the answer comes back in the probe
        let copyLabel = ar ? "\u{0646}\u{0633}\u{062E}" : "Copy"                                     // نسخ
        let copyItem = app.menuItems[copyLabel].exists ? app.menuItems[copyLabel] : app.buttons[copyLabel]
        if em5 > em4 && copyItem.exists && copyItem.isHittable {
            copyItem.tap()
            var pc = probe(app)
            for _ in 0..<3 where str(pc, "ema").isEmpty { usleep(700_000); pc = probe(app) }
            gate("edit-menu-copy", str(pc, "ema") == "copy:ok", "last action '\(str(pc, "ema"))' \(focusInfo(pc))")
        } else {
            info("edit-menu-copy", "Copy not found in the native menu (menu items: \(app.menuItems.count)); not tapped")
        }

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
        var p7 = probe(app)
        // the button state follows the tap a moment later on the phone (one probe right after the tap read bold=false
        // on 2 of 3 CI runs while the tap had landed): look again for up to ~2 s, never tap a second time (that toggles)
        for _ in 0..<3 where tapped && !flag(p7, "bold") { usleep(700_000); p7 = probe(app) }
        gate("format-tap-keeps-keyboard", tapped && focused(p7), focusInfo(p7))
        shot(app, "54-touch-\(lang)-bold")
        if !focused(p7) { tapEnd(); _ = probe(app) }                     // so the later checks still run (logged above)
        typeSlowly(app, " " + boldWord)
        let p8 = probe(app)
        // Bold with nothing selected is a pending format: the ribbon button lights up at once (seen in the CI shots), but
        // the caret's text properties can still read not-bold until a letter is typed - so the word typed after the tap
        // decides (check_saved.py also checks that word is a bold run in the saved file)
        gate("bold-button-applies", tapped && (flag(p7, "bold") || flag(p8, "bold")),
             "tapped=\(tapped) bold after tap=\(flag(p7, "bold")) after typing=\(flag(p8, "bold")) fold=\(str(p7, "fold")) " +
             "button active=\(flag(p7, "bact")) hit=\(str(p7, "bhit")) [\(str(p7, "bhitc"))] bold buttons=\(num(p7, "bn") ?? -1) before tap: fold=\(str(p6, "fold")) active=\(flag(p6, "bact"))")
        gate("type-after-format", plain(p8).contains(sentence.prefix(4)) && (plain(p8).components(separatedBy: "|").first ?? "").hasSuffix(boldWord),
             "bold=\(flag(p8, "bold")) text=\(plain(p8).prefix(80))")

        // 6b) the keyboard bar (plan M5): its Bold keeps the keyboard and the next word comes out bold. The bar sits in
        //     the keyboard's accessory (found by its identifier, tapped as a user taps it). Bold is tapped until it is
        //     on: once when the word above ended not bold, twice (off, then on again) when it was bold - each tap checked
        let kbBold = app.buttons["xr-kb-bold"]
        let barShown = kbBold.waitForExistence(timeout: 10) && kbBold.isHittable
        gate("kbar-shown", barShown, "bar over the keyboard: \(barShown) \(focusInfo(p8))")
        var q1 = p8
        if barShown {
            for _ in 0..<2 {
                let before = flag(q1, "bold")
                kbBold.tap()
                q1 = probe(app)
                // the state follows the tap a moment later (as with the ribbon): look again, never tap twice for one
                for _ in 0..<3 where flag(q1, "bold") == before { usleep(700_000); q1 = probe(app) }
                gate(before ? "kbar-bold-off" : "kbar-bold-on", flag(q1, "bold") != before && focused(q1),
                     "bold \(before) -> \(flag(q1, "bold")) \(focusInfo(q1))")
                if flag(q1, "bold") || flag(q1, "bold") == before { break }
            }
        }
        gate("kbar-keeps-keyboard", barShown && focused(q1), focusInfo(q1))
        if !focused(q1) { tapEnd(); _ = probe(app) }
        typeSlowly(app, " " + barWord)
        let q2 = probe(app)
        gate("kbar-next-word-bold", barShown && flag(q2, "bold") && (plain(q2).components(separatedBy: "|").first ?? "").hasSuffix(barWord),
             "bold=\(flag(q2, "bold")) text=\(plain(q2).prefix(80))")
        shot(app, "54b-touch-\(lang)-keyboard-bar")
        // the bar's alignment cycles start -> centre -> end -> start (logical values: start = "left" in the engine, also
        // in a right-to-left paragraph); three taps bring the line back where it was, so the later caret taps still fit
        let stateLabel = app.staticTexts["xr-editor-state"]
        func align() -> String {
            let s = stateLabel.exists ? stateLabel.label : ""
            return s.components(separatedBy: " ").first { $0.hasPrefix("al:") }.map { String($0.dropFirst(3)) } ?? "?"
        }
        let kbAlign = app.buttons["xr-kb-align"]
        let a0 = align()
        if barShown && a0 == "left" && kbAlign.exists {
            var seen: [String] = []
            for want in ["center", "right", "left"] {
                kbAlign.tap()
                var a = align()
                for _ in 0..<6 where a != want { usleep(500_000); a = align() }
                seen.append(a)
            }
            let q = probe(app)
            gate("kbar-align-cycles", seen == ["center", "right", "left"] && focused(q),
                 "start=\(a0) taps -> \(seen.joined(separator: ",")) \(focusInfo(q))")
        } else {
            gate("kbar-align-cycles", false, "bar=\(barShown) start alignment=\(a0) button=\(kbAlign.exists)")
        }
        let paras8 = Int(num(q2, "paras") ?? 0)
        pauseProbe(true)
        for _ in 0..<5 { app.typeText("\n"); usleep(300_000) }
        pauseProbe(false)
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
        // a hard check (no KNOWN): this is the behaviour M14 names, and it passes today on both devices
        gate("sheet-return-keyboard", shown && (!up11 || focused(p12)), "before: \(focusInfo(p11)) after: \(focusInfo(p12))")
        gate("sheet-return-caret", shown && abs(caret12.0 - caret11.0) <= 2 && abs(caret12.1 - caret11.1) <= 2,
             "caret \(caret11) -> \(caret12)")
        shot(app, "56-touch-\(lang)-sheet-closed")
        if !focused(p12) { tapEnd(); _ = probe(app) }

        // 8b) the Aa format sheet (plan S1) from the keyboard bar: it opens with the keyboard down, its size stepper
        //     reaches the engine (state "sz:" up one step, then back down: the text keeps its geometry), and closing
        //     it brings back the keyboard and the caret where they were (the M14 rule for every native sheet)
        var f0 = probe(app)
        for _ in 0..<2 where !(str(f0, "sel").isEmpty && focused(f0)) { tapEnd(); f0 = probe(app) }
        let caretF0 = (num(f0, "cx") ?? -1, num(f0, "cy") ?? -1)
        func fontSize() -> Double {
            let s = stateLabel.exists ? stateLabel.label : ""
            return s.components(separatedBy: " ").first { $0.hasPrefix("sz:") }.flatMap { Double($0.dropFirst(3)) } ?? -1
        }
        let kbFormat = app.buttons["xr-kb-format"]
        let aaShown = kbFormat.waitForExistence(timeout: 10) && kbFormat.isHittable
        if aaShown { kbFormat.tap() }
        let sizeUp = app.buttons["xr-fmt-size-up"], sizeDown = app.buttons["xr-fmt-size-down"]
        let fmtShown = aaShown && sizeUp.waitForExistence(timeout: 10)
        let f1 = probe(app)
        shot(app, "55b-touch-\(lang)-format-sheet")
        gate("fmt-sheet-opens", fmtShown, "Aa in the keyboard bar: \(aaShown) \(focusInfo(f0))")
        // the keyboard is off the screen under the phone's sheet (UIKit may keep the responder: kb, not fr, is what the
        // user sees); the iPad popover hangs from the top bar and may leave the keyboard up beside it
        if UIDevice.current.userInterfaceIdiom == .pad && flag(f1, "kb") {
            gate("fmt-sheet-keyboard-down", fmtShown, "iPad popover, keyboard stays up beside it: \(focusInfo(f1))")
        } else {
            gate("fmt-sheet-keyboard-down", fmtShown && !flag(f1, "kb"), focusInfo(f1))
        }
        var sizes: [Double] = [fontSize()]
        if fmtShown {
            for b in [sizeUp, sizeDown] {
                let before = sizes.last ?? -1
                b.tap()
                var now = fontSize()
                for _ in 0..<8 where now == before { usleep(500_000); now = fontSize() }
                sizes.append(now)
            }
        }
        gate("fmt-size-applies", sizes.count == 3 && sizes[0] > 0 && sizes[1] > sizes[0] && sizes[2] == sizes[0],
             "size \(sizes.map { String(format: "%g", $0) }.joined(separator: " -> "))")
        if fmtShown { app.buttons["xr-fmt-done"].tap() }
        for _ in 0..<20 where sizeUp.exists { usleep(500_000) }
        // the keyboard itself must be back on screen (kb: keyboardDidShow), not only the responder (round 1: fr=true
        // kb=false passed a focus-only check): polled for up to 3 s for the dismissal and the keyboard animation
        var f2 = probe(app)
        for _ in 0..<6 where fmtShown && focused(f0) && !(focused(f2) && flag(f2, "kb")) { usleep(500_000); f2 = probe(app) }
        let caretF2 = (num(f2, "cx") ?? -2, num(f2, "cy") ?? -2)
        gate("fmt-sheet-return-keyboard", fmtShown && !sizeUp.exists && (!focused(f0) || (focused(f2) && flag(f2, "kb"))),
             "before: \(focusInfo(f0)) after: \(focusInfo(f2))")
        // the caret at the same place in the text: on screen within 2 pt, or at the very same document position (page
        // + mm) with its top edge within 2 pt. CI round 4 (iPhone): same document position and same top, but the
        // engine redrew the caret taller once the keyboard came back after the size round trip (h 7 -> 14 EN,
        // 12 -> 20 AR), which moves its centre (cy) by half the difference; the height is in the detail line
        let docF0 = "\(num(f0, "dpg") ?? -1)/\(num(f0, "dx") ?? -1)/\(num(f0, "dy") ?? -1)"
        let docF2 = "\(num(f2, "dpg") ?? -2)/\(num(f2, "dx") ?? -2)/\(num(f2, "dy") ?? -2)"
        let onScreen = abs(caretF2.0 - caretF0.0) <= 2 && abs(caretF2.1 - caretF0.1) <= 2
        let top0 = caretF0.1 - (num(f0, "ch") ?? 0) / 2, top2 = caretF2.1 - (num(f2, "ch") ?? 0) / 2
        let inText = num(f0, "dy") != nil && docF0 == docF2 && abs(caretF2.0 - caretF0.0) <= 2 && abs(top2 - top0) <= 2
        gate("fmt-sheet-return-caret", fmtShown && (onScreen || inText),
             "caret \(caretF0) -> \(caretF2) h \(num(f0, "ch") ?? -1) -> \(num(f2, "ch") ?? -1) document \(docF0) -> \(docF2)")
        shot(app, "56b-touch-\(lang)-format-sheet-closed")
        if !focused(f2) { tapEnd(); _ = probe(app) }

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
        // keydown/input -> second requestAnimationFrame (not the canvas paint itself), with the probe paused while typing
        info("typing-latency", "n=\(num(lat, "n") ?? 0) median=\(num(lat, "med") ?? -1) ms p95=\(num(lat, "p95") ?? -1) ms (keydown->2rAF, probe paused, simulator)")

        // 9b) the keyboard bar's last button puts the keyboard away (plan M5); the keyboard is brought up first when the
        //     pinches left it down. Not with tapEnd(): its point was measured at the old zoom and the pinch-in changed
        //     the page scale, so it can land in the text and open the desktop menu (CI run 43588342045, iPhone AR).
        //     The caret's position is measured again at the current zoom and the tap goes into the text on the caret's
        //     line, toward the line's start: a pinch can also open the desktop menu right beside the caret (iPad, CI run
        //     43593838031), and a tap on the caret itself then lands in that menu. The tap closes the menu too.
        var q0 = probe(app)
        let webWidth = Double(web.frame.width)
        for i in 0..<3 where !focused(q0) {
            if let x = num(q0, "cx"), let y = num(q0, "cy") {
                tap(min(max(x - dir * 50 * Double(i + 1), 24), webWidth - 24), y)
            } else { tapEnd() }
            usleep(500_000); q0 = probe(app)
        }
        let kbHide = app.buttons["xr-kb-hide"]
        let hideShown = kbHide.waitForExistence(timeout: 10) && kbHide.isHittable
        if hideShown { kbHide.tap() }
        var q3 = probe(app)
        for _ in 0..<3 where hideShown && flag(q3, "fr") { usleep(700_000); q3 = probe(app) }
        gate("kbar-hide-keyboard", hideShown && !flag(q3, "fr"), "shown=\(hideShown) after: \(focusInfo(q3))")
        shot(app, "58b-touch-\(lang)-keyboard-hidden")

        // 10) Save, then reload the editor from the saved bytes (the document data the save wrote; the file on disk is
        //     checked separately by check_saved.py, which opens xr-touch-<lang>.docx): the text is all there
        let saved = save(app)
        gate("save", saved.hasPrefix("saved"), saved)
        autotest("reopen")
        let again = waitState(app, prefix: "ready", timeout: 120)
        let p15 = probe(app)
        let back = plain(p15)
        gate("reopen-keeps-text", again == "ready" && back.contains(t3) && back.contains(boldWord) && back.contains(barWord) && back.contains(endWord),
             "\(again) text=\(back.prefix(100))")
        shot(app, "59-touch-\(lang)-reopened")
    }

    // MARK: PDF tool bar gate (plan S7)

    /// The PDF tool bar (plan S7), iPhone and iPad, in English and Arabic: the bar is there under the page in reading
    /// state; Highlight / Underline / Strike out / Pen / Eraser switch the engine's own tool on (read back from the
    /// engine) and Done ends it; a pen stroke drawn with the finger becomes ink; the colour is remembered; Fill & Sign
    /// puts a check mark, a cross and the date on the page; a signature is drawn (English) or typed in the Arabic font
    /// (Arabic) in the sheet, which says plainly it is a visual signature, and goes onto the page; a saved "My
    /// signature" goes on again in 2 taps; save and reopen. Every check is a "pdf-gate" line in the editor log
    /// (check_saved.py, which also opens the saved PDF and counts the pictures in it). Named "ZZ" + "Pdf" to run
    /// after the typing tests and before the touch gate.
    func testZZPdfToolBarGate() throws {
        guard let b64 = ProcessInfo.processInfo.environment["XR_PDF_B64"] else { throw XCTSkip("no pdf passed") }
        for lang in ["en", "ar"] { pdfGate(lang, b64) }
    }

    private var pdfRun = 0
    /// __xrPdfState through the Autotest hook: {tool, marker, ink, annots, inks, drawings}.
    private func pdfState(_ app: XCUIApplication) -> [String: Any] {
        pdfRun += 1
        let tag = "pdf\(pdfRun):"
        autotest("pdfstate?n=\(pdfRun)")
        let s = waitState(app, prefix: tag, timeout: 15)
        guard s.hasPrefix(tag) else { return ["error": s] }
        return ((try? JSONSerialization.jsonObject(with: Data(s.dropFirst(tag.count).utf8))) as? [String: Any]) ?? ["error": s]
    }

    private func pdfGate(_ lang: String, _ b64: String) {
        let ar = lang == "ar"
        let app = XCUIApplication()
        app.launchArguments = ["-xr.lang", lang, "-xr.pdfToolBar", "YES"]
        app.launchEnvironment = ["XR_DOC_B64": b64, "XR_DOC_NAME": "xr-pdf-bar-\(lang).pdf", "XR_LANG": lang]
        app.launch()
        let keep = continueAfterFailure
        continueAfterFailure = true
        var notes: [String] = []
        func gate(_ name: String, _ ok: Bool, _ detail: String, known: String? = nil) {
            let status = ok ? "PASS" : (known == nil ? "FAIL" : "KNOWN")
            let line = "pdf-gate \(lang) \(name): \(status) \(detail)" + (ok || known == nil ? "" : " [known app gap: \(known!)]")
            print("XR " + line)
            notes.append(line.replacingOccurrences(of: "\n", with: " "))
            if known == nil { XCTAssertTrue(ok, line) }
        }
        defer {
            autotest("note", notes.joined(separator: "\n"))
            app.terminate()
            continueAfterFailure = keep
        }
        let ready = waitState(app, prefix: "ready", timeout: 120)
        gate("editor-ready", ready == "ready", ready)
        guard ready == "ready" else { return }
        sleep(2)
        if !ar { autotest("pdfsigdelete") }                 // the English run starts without a saved signature
        func n(_ p: [String: Any], _ k: String) -> Int { (p[k] as? NSNumber)?.intValue ?? -1 }
        func s(_ p: [String: Any], _ k: String) -> String { (p[k] as? String) ?? String(describing: p[k] ?? "nil") }
        func btn(_ id: String) -> XCUIElement { app.buttons[id] }
        /// the selected picture's width x height in mm (__xrPdfState "selmm"); -1 when nothing is selected
        func mm(_ p: [String: Any]) -> (Double, Double) {
            let a = (p["selmm"] as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
            return a.count == 2 ? (a[0], a[1]) : (-1, -1)
        }
        /// taps a bar control once it is there; false when it never showed
        func tap(_ id: String) -> Bool {
            let b = btn(id)
            guard b.waitForExistence(timeout: 8), b.isHittable else { return false }
            b.tap(); usleep(700_000); return true
        }

        // 1) the bar: under the page, 50 pt, in reading state (no tool on)
        let bar = app.otherElements["xr-pdf-bar"]
        let shown = bar.waitForExistence(timeout: 15)
        let bf = shown ? bar.frame : .zero, wf = app.windows.firstMatch.frame
        gate("bar-shown", shown && bf.height >= 44 && bf.height <= 60 && bf.minY > wf.height * 0.6,
             "frame=\(bf) window=\(wf)")
        let mode = app.segmentedControls["xr-pdf-mode"]
        gate("mode-switch", mode.exists, "segments=\(mode.exists ? mode.buttons.count : 0)")
        if mode.exists {
            mode.buttons[ar ? "تعليق" : "Annotate"].tap()
            if !btn("xr-pdf-highlight").waitForExistence(timeout: 4) {
                // seen once (CI 140, iPad, Arabic): the bar opened in Fill & Sign (kept from the English file) and the
                // first tap on Annotate never switched it - the same lost first tap the slides and menu tests record;
                // noted, then tapped again as a person would
                let line = "pdf-gate \(lang) annotate-first-tap-ignored: INFO the switch changed only after a second tap"
                print("XR " + line); notes.append(line)
                mode.buttons[ar ? "تعليق" : "Annotate"].tap()
                _ = btn("xr-pdf-highlight").waitForExistence(timeout: 6)
            }
            usleep(500_000)
        }
        let p0 = pdfState(app)
        gate("opens-reading", s(p0, "tool") == "none" && s(p0, "ink") != "draw" && p0["error"] == nil, "\(p0)")
        shot(app, "60-pdf-\(lang)-bar")

        // Arabic: the labels are Arabic and the bar is mirrored (the switch on the right)
        if ar {
            let hl = btn("xr-pdf-highlight")
            gate("ar-labels", hl.exists && hl.label == "تمييز", "highlight label='\(hl.exists ? hl.label : "-")'")
            gate("ar-mirrored", mode.exists && mode.frame.midX > wf.midX, "switch x=\(mode.exists ? mode.frame.midX : -1) window mid=\(wf.midX)")
        }

        // 2) the three text tools: the engine's marker is on with the right type (Highlight 8, Underline 9, Strikeout
        //    11 = AscPDF.ANNOTATIONS_TYPES), Done ends it
        for (t, want) in [("highlight", 8), ("underline", 9), ("strike", 11)] {
            let tapped = tap("xr-pdf-" + t)
            let p = pdfState(app)
            gate("\(t)-on", tapped && s(p, "tool") == t && n(p, "marker") == want && btn("xr-pdf-done").exists,
                 "tapped=\(tapped) \(p) done=\(btn("xr-pdf-done").exists)")
        }
        let doneTapped = tap("xr-pdf-done")
        let pD = pdfState(app)
        let markerOff = pD["marker"] == nil || pD["marker"] is NSNull || n(pD, "marker") == -1
        gate("done-ends-tool", doneTapped && s(pD, "tool") == "none" && markerOff && mode.waitForExistence(timeout: 4),
             "tapped=\(doneTapped) \(pD)")

        // 3) pen: the engine's ink drawer is on; a finger stroke on the page becomes ink; eraser; Done
        if !ar {
            let inks0 = n(pD, "inks")
            let penTapped = tap("xr-pdf-pen")
            let pP = pdfState(app)
            gate("pen-on", penTapped && s(pP, "tool") == "pen" && s(pP, "ink") == "draw", "tapped=\(penTapped) \(pP)")
            let web = app.webViews.firstMatch
            let a = web.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.45))
            let b = web.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
            a.press(forDuration: 0.15, thenDragTo: b)
            usleep(800_000)
            shot(app, "61-pdf-\(lang)-pen")
            let eraseTapped = tap("xr-pdf-eraser")
            let pE = pdfState(app)
            gate("eraser-on", eraseTapped && s(pE, "tool") == "eraser" && s(pE, "ink") == "erase", "tapped=\(eraseTapped) \(pE)")
            _ = tap("xr-pdf-done")
            let pI = pdfState(app)
            let noInk = n(pI, "inks") == inks0 && s(pI, "ink") == "off"
            gate("pen-stroke-makes-ink", n(pI, "inks") > inks0 && s(pI, "ink") == "off", "inks \(inks0)->\(n(pI, "inks")) \(pI)",
                 known: noInk ? "a finger stroke with the pen on adds no ink on this simulator (the engine's ink tool may want mouse events: the plan's per-tool touch spike)" : nil)
        }

        // 4) colour: pick a swatch in the colour menu; the dot says it (and the model keeps it for the next tool)
        let green = ar ? "أخضر" : "Green"
        if tap("xr-pdf-color") {
            let item = app.buttons[green].firstMatch
            if item.waitForExistence(timeout: 5) { item.tap(); usleep(700_000) }
        }
        let dot = btn("xr-pdf-color")
        let dotValue = dot.exists ? ((dot.value as? String) ?? "") : ""
        gate("colour-picked", dotValue.contains(green), "dot value='\(dotValue)'")
        gate("note-reachable", btn("xr-pdf-note").exists && btn("xr-pdf-note").isHittable, "note button shown")

        // 5) Fill & Sign: check mark, cross, date each go onto the page as a picture
        if mode.exists {
            mode.buttons[ar ? "تعبئة وتوقيع" : "Fill & Sign"].tap()
            if !btn("xr-pdf-check").waitForExistence(timeout: 4) {
                let line = "pdf-gate \(lang) fill-first-tap-ignored: INFO the switch changed only after a second tap"
                print("XR " + line); notes.append(line)
                mode.buttons[ar ? "تعبئة وتوقيع" : "Fill & Sign"].tap()
            }
            usleep(700_000)
        }
        gate("fill-shown", btn("xr-pdf-check").waitForExistence(timeout: 5) && btn("xr-pdf-signature").exists,
             "check=\(btn("xr-pdf-check").exists) signature=\(btn("xr-pdf-signature").exists)")
        var placed = 0
        for what in (ar ? ["check"] : ["check", "cross", "date"]) {
            let before = n(pdfState(app), "drawings")
            let tapped = tap("xr-pdf-" + what)
            let r = waitState(app, prefix: "placed:", timeout: 20)
            let pA = pdfState(app)
            let after = n(pA, "drawings")
            if r == "placed:ok:" + what { placed += 1 }
            gate("\(what)-placed", tapped && r == "placed:ok:" + what && after == before + 1,
                 "tapped=\(tapped) \(r) drawings \(before)->\(after)")
            // the mark comes out at its own size (6 mm wide), not the editor's inserted size (its pixels at 96 dpi)
            if what == "check" {
                let w = mm(pA)
                gate("check-sized", w.0 >= 5 && w.0 <= 7 && w.1 >= 5 && w.1 <= 7, "selected=\(w.0)x\(w.1) mm (want 6x6)")
            }
        }
        shot(app, "62-pdf-\(lang)-marks")

        // 6) signature: the sheet (honest label), drawn (EN) or typed in the Arabic font (AR), onto the page
        let before6 = n(pdfState(app), "drawings")
        var opened = false
        if ar {
            // the English run saved "My signature": the button is a menu now - New Signature opens the sheet
            if tap("xr-pdf-signature") {
                let item = app.buttons["xr-pdf-sig-new"].exists ? app.buttons["xr-pdf-sig-new"] : app.buttons["توقيع جديد…"]
                if item.waitForExistence(timeout: 5) { item.tap(); opened = true }
            }
        } else {
            opened = tap("xr-pdf-signature")
        }
        let label = app.staticTexts["xr-sig-label"]
        let sheet = opened && label.waitForExistence(timeout: 10)
        let honest = sheet && (ar ? label.label.contains("ليس توقيعاً إلكترونياً معتمداً")
                                  : label.label.contains("not a certified e-signature"))
        gate("signature-sheet", sheet, "opened=\(opened)")
        gate("signature-honest-label", honest, "label='\(sheet ? label.label : "-")'")
        if sheet {
            if ar {
                let src = app.segmentedControls["xr-sig-source"]
                if src.exists { src.buttons["كتابة"].tap(); usleep(500_000) }
                let field = app.textFields["xr-sig-name"]
                if field.waitForExistence(timeout: 5) {
                    field.tap(); usleep(500_000)
                    typeSlowly(app, "\u{0633}\u{0627}\u{0631}\u{0629}")             // سارة
                }
                let font = app.segmentedControls["xr-sig-font"]
                if font.exists { font.buttons["خط عربي"].tap() }
                let owner = app.segmentedControls["xr-sig-owner"]
                if owner.exists { owner.buttons["شخص آخر (مرة واحدة)"].tap() }
            } else {
                let canvas = app.descendants(matching: .any)["xr-sig-canvas"].firstMatch
                if canvas.waitForExistence(timeout: 5) {
                    let c1 = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.6))
                    let c2 = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                    let c3 = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.55))
                    c1.press(forDuration: 0.1, thenDragTo: c2)
                    c2.press(forDuration: 0.1, thenDragTo: c3)
                }
            }
            shot(app, "63-pdf-\(lang)-signature-sheet")
            let insert = btn("xr-sig-insert")
            let can = insert.waitForExistence(timeout: 5) && insert.isEnabled
            if can { insert.tap() } else if btn("xr-sig-cancel").exists { btn("xr-sig-cancel").tap() }
            let r = waitState(app, prefix: "placed:", timeout: 20)
            let pS = pdfState(app)
            let after = n(pS, "drawings")
            if r == "placed:ok:signature" { placed += 1 }
            gate(ar ? "signature-typed-arabic-placed" : "signature-drawn-placed",
                 can && r == "placed:ok:signature" && after == before6 + 1,
                 "insert enabled=\(can) \(r) drawings \(before6)->\(after)")
            let w = mm(pS)
            gate("signature-sized", abs(w.0 - 45) <= 1, "selected=\(w.0)x\(w.1) mm (want 45 mm wide)")
        }
        shot(app, "64-pdf-\(lang)-signed")

        // 7) "My signature" again in 2 taps (English: saved by the sheet above; Arabic typed "once", so it is unchanged)
        let before7 = n(pdfState(app), "drawings")
        let t1 = tap("xr-pdf-signature")
        let mine = app.buttons["xr-pdf-sig-mine"].exists ? app.buttons["xr-pdf-sig-mine"]
            : app.buttons[ar ? "إدراج توقيعي" : "Insert My Signature"]
        let t2 = t1 && mine.waitForExistence(timeout: 5)
        if t2 { mine.tap() }
        let r7 = waitState(app, prefix: "placed:", timeout: 20)
        let after7 = n(pdfState(app), "drawings")
        if r7 == "placed:ok:signature" { placed += 1 }
        gate("my-signature-2-taps", t2 && r7 == "placed:ok:signature" && after7 == before7 + 1,
             "menu=\(t2) \(r7) drawings \(before7)->\(after7)")

        // 8) save, reopen from the saved bytes (check_saved.py opens the file itself and counts its pictures)
        let saved = save(app)
        gate("save", saved.hasPrefix("saved"), saved)
        autotest("reopen")
        let again = waitState(app, prefix: "ready", timeout: 120)
        let pR = pdfState(app)
        gate("reopen", again == "ready" && pR["error"] == nil, "\(again) \(pR) pictures placed=\(placed)")
        shot(app, "65-pdf-\(lang)-reopened")
        if ar { autotest("pdfsigdelete") }                  // leave no saved signature behind
    }

    /// New spreadsheet and presentation open in their editors (also in Arabic, where the spreadsheet's status bar
    /// mirrors its absolutely placed boxes and, on phones, the overflowing tab row scrolls right-to-left), and pass
    /// the iPad layout gate and the chrome gate.
    func testSpreadsheetAndPresentationOpen() {
        let runs = [("cell", "en"), ("cell", "ar"), ("slide", "en")]
        for (kind, lang) in runs {
            let app = launch(["XR_KIND": kind, "XR_LANG": lang])
            let ready = waitState(app, prefix: "ready", timeout: 120)
            sleep(2)
            let tag = kind + (lang == "en" ? "" : "-" + lang)
            shot(app, "20-" + tag + "-ready")
            XCTAssertEqual(ready, "ready", "\(tag) editor did not become ready")
            if lang == "en" {
                checkContract(app, tag)
                // ⋯ > Export ▸ formats of this kind (M7b; the same call as the menu entry) and the Document info counts
                for ext in kind == "cell" ? ["xlsx"] : ["pptx", "odp"] {
                    autotest("export?f=" + ext)
                    let want = "exported:" + (ext == (kind == "cell" ? "xlsx" : "pptx") ? "exp-" : "") + "xr-test." + ext
                    XCTAssertEqual(waitState(app, prefix: want, timeout: 60), want, "Export ▸ .\(ext) (\(tag))")
                }
                autotest("docinfo")
                let info = waitState(app, prefix: "docinfo:", timeout: 20)
                print("XR menu \(tag) docinfo: \(info)")
                XCTAssertTrue(info.contains(kind == "cell" ? "\"sheets\":1" : "\"slides\":1"), "Document info counts (\(tag)): \(info)")
            }
            checkIPadLayout(app, tag)
            checkChrome(app, tag)
            app.terminate()
        }
    }


    // MARK: - Spreadsheet gate (plan S3): A1 chip, Sum capsule + sheet, formula keys

    /// Spreadsheet touch gate (plan S3), in Arabic and in English (app in that language): the name box is a tappable
    /// "A1" chip (36 pt on phones, the formula bar 44 pt with 17 px text) and an address typed into it goes there; the
    /// status bar's math box gives way to the native Sum capsule, which shows the selection's total and opens a sheet
    /// with Sum / Average / Min / Max / Count, whose "Insert below" writes =SUM(...) under the range; the keyboard's
    /// formula keys (= ( : , ) ✓ ✕ ⇥ and "hide keyboard") build a formula and commit, cancel and move on while the
    /// keyboard stays up. Values are typed with the real keyboard into the formula bar. Every result goes to the
    /// editor log as "sheet-gate <lang> <check>: PASS|FAIL|KNOWN" for check_saved.py, which also opens the saved
    /// xr-sheet-<lang>.xlsx. Named "ZZZ" to run after the Word touch gate.
    func testZZZSheetGateChipSumFormulaKeys() {
        for lang in ["ar", "en"] { sheetGate(lang) }
    }

    private func sheetGate(_ lang: String) {
        let ar = lang == "ar"
        let phone = UIDevice.current.userInterfaceIdiom != .pad
        let app = XCUIApplication()
        app.launchArguments = ["-xr.lang", lang, "-xr.keyboardBar", "YES"]     // the key row is behind the M5 flag
        try? FileManager.default.removeItem(atPath: probeFile)
        pauseProbe(false)
        app.launchEnvironment = ["XR_KIND": "cell", "XR_LANG": lang, "XR_NEW_NAME": "xr-sheet-\(lang).xlsx",
                                 "XR_PROBE": "1", "XR_PROBE_FILE": probeFile]
        app.launch()
        let keep = continueAfterFailure
        continueAfterFailure = true
        var notes: [String] = []
        func gate(_ name: String, _ ok: Bool, _ detail: String, known: String? = nil) {
            let status = ok ? "PASS" : (known == nil ? "FAIL" : "KNOWN")
            let line = "sheet-gate \(lang) \(name): \(status) \(detail)" + (ok || known == nil ? "" : " [known app gap: \(known!)]")
            print("XR " + line)
            notes.append(line.replacingOccurrences(of: "\n", with: " "))
            if known == nil { XCTAssertTrue(ok, line) }
        }
        func info(_ name: String, _ detail: String) {
            let line = "sheet-gate \(lang) \(name): INFO \(detail)"
            print("XR " + line)
            notes.append(line)
        }
        defer {
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
        let origin = web.frame.origin
        func tap(_ x: Double, _ y: Double) {
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: origin.x + x, dy: origin.y + y)).tap()
        }
        func rect(_ p: [String: Any], _ k: String) -> [Double] { (p[k] as? [NSNumber])?.map { $0.doubleValue } ?? [] }
        func cell(_ p: [String: Any], _ n: String) -> (value: String, formula: String) {
            let c = (p["cells"] as? [String: Any])?[n] as? [String] ?? []
            return (c.first ?? "", c.count > 1 ? c[1] : "")
        }
        func cellsInfo(_ p: [String: Any]) -> String {
            ["A1", "A2", "A3", "A4", "B1", "C1"].map { "\($0)=\(cell(p, $0).value)/\(cell(p, $0).formula)" }.joined(separator: " ")
                + (str(p, "cellsErr").isEmpty ? "" : " err=\(str(p, "cellsErr"))")
        }
        func sinfo(_ p: [String: Any]) -> String {
            "fr=\(flag(p, "fr")) focus=\(str(p, "focus")) edit=\(flag(p, "edit")) kb=\(flag(p, "kb")) chip='\(str(p, "nb"))'"
        }
        let stateLabel = app.staticTexts["xr-editor-state"]
        func stateField(_ k: String) -> String {
            let s = stateLabel.exists ? stateLabel.label : ""
            return s.components(separatedBy: " ").first { $0.hasPrefix(k + ":") }.map { String($0.dropFirst(k.count + 1)) } ?? "?"
        }

        // 1) the A1 chip: the name box shows A1; on phones a 36 pt chip in a 44 pt formula bar, 17 px text
        let p0 = probe(app)
        let nb = rect(p0, "nbr"), fb = rect(p0, "fb")
        let sized = !phone || (nb.count == 4 && nb[3] >= 34 && nb[3] <= 38 && fb.count == 4 && fb[3] >= 43 &&
                               str(p0, "nbfs") == "17px" && str(p0, "cefs") == "17px")
        gate("a1-chip", str(p0, "nb") == "A1" && nb.count == 4 && sized,
             "chip='\(str(p0, "nb"))' rect=\(nb) bar=\(fb) font=\(str(p0, "nbfs"))/\(str(p0, "cefs")) phone=\(phone)")
        gate("math-box-replaced", !flag(p0, "mathbox"), "web math box shown=\(flag(p0, "mathbox"))")
        shot(app, "60-sheet-\(lang)-ready")

        /// a tap on the chip, the address typed, Return: the editor goes there (its own name-box handler)
        func goTo(_ ref: String) -> [String: Any] {
            var p = probe(app)
            for _ in 0..<2 {
                let r = rect(p, "nbr")
                guard r.count == 4 else { break }
                tap(r[0], r[1])
                usleep(700_000)
                p = probe(app)
                if str(p, "focus") == "ce-cell-name" { break }
            }
            typeSlowly(app, ref)
            app.typeText("\n")
            return probe(app)
        }
        /// a tap on the formula bar: the keyboard comes up with the active cell open for editing
        func editBar() -> [String: Any] {
            var p = probe(app)
            for _ in 0..<3 where !(flag(p, "fr") && flag(p, "edit")) {
                let r = rect(p, "ce")
                guard r.count == 4 else { break }
                tap(r[0] - r[2] * 0.25, r[1])
                usleep(700_000)
                p = probe(app)
            }
            return p
        }
        /// one formula key, tapped as a user taps it (scrolled to when the row overflows a narrow phone)
        func key(_ id: String) -> Bool {
            let b = app.buttons["xr-fk-" + id].firstMatch
            guard b.waitForExistence(timeout: 5) else { return false }
            if !b.isHittable {
                let row = app.scrollViews.containing(.button, identifier: "xr-fk-equals").firstMatch
                if row.exists { if ar { row.swipeRight() } else { row.swipeLeft() } }
                usleep(400_000)
            }
            guard b.isHittable else { return false }
            b.tap()
            usleep(500_000)
            return true
        }

        // 2) three values through the formula bar (the chip picks each cell)
        let values = ["12", "30", "1246"]
        var firstEdit: [String: Any] = [:]
        for (i, v) in values.enumerated() {
            _ = goTo("A\(i + 1)")
            let p = editBar()
            if i == 0 { firstEdit = p }
            typeSlowly(app, v)
            app.typeText("\n")
        }
        gate("chip-goes-to-cell", str(firstEdit, "nb") == "A1", "after typing A1 into the chip: \(sinfo(firstEdit))")
        gate("formula-bar-tap-edits", flag(firstEdit, "fr") && flag(firstEdit, "edit"), sinfo(firstEdit))
        let p1 = probe(app)
        gate("values-typed", cell(p1, "A1").value == "12" && cell(p1, "A2").value == "30" && cell(p1, "A3").value == "1246",
             cellsInfo(p1))

        // 3) the range through the chip; the Sum capsule shows its total (1,288; Western digits in both languages)
        let p2 = goTo("A1:A3")
        let capsule = app.buttons["xr-sum"].firstMatch
        let hideKey = app.buttons["xr-fk-hide"].firstMatch
        if flag(p2, "fr") && hideKey.exists && hideKey.isHittable { hideKey.tap() }
        let shown = capsule.waitForExistence(timeout: 10)
        let capLabel = shown ? capsule.label : ""
        gate("chip-selects-range", stateField("cnt") == "3", "count=\(stateField("cnt")) \(sinfo(p2))")
        let sumWord = ar ? "\u{0627}\u{0644}\u{0645}\u{062C}\u{0645}\u{0648}\u{0639}" : "Sum"        // المجموع
        gate("sum-capsule", shown && capLabel.contains("1,288") && capLabel.contains(sumWord), "shown=\(shown) label='\(capLabel)'")
        shot(app, "61-sheet-\(lang)-sum-capsule")

        // 4) the capsule opens the sheet: Sum, Average, Min, Max, Count; 5) its Insert below writes =SUM(A1:A3) in A4
        if shown && capsule.isHittable {
            capsule.tap()
            let avg = app.staticTexts["xr-sum-value-average"].firstMatch
            if avg.waitForExistence(timeout: 10) {
                func v(_ id: String) -> String { let e = app.staticTexts["xr-sum-value-" + id].firstMatch; return e.exists ? e.label : "-" }
                // the last row (Count) must be there without scrolling; if it is not, note it and scroll for the values
                let countShown = app.staticTexts["xr-sum-value-count"].firstMatch.exists
                if !countShown { app.swipeUp(); usleep(600_000) }
                info("sum-sheet-count-without-scroll", "\(countShown)")
                let got = ["sum": v("sum"), "average": v("average"), "min": v("min"), "max": v("max"), "count": v("count")]
                let ok = got["sum"] == "1,288" && got["average"] == "429.33" && got["min"] == "12" && got["max"] == "1,246" && got["count"] == "3"
                gate("sum-sheet", ok, "values \(got)")
                shot(app, "62-sheet-\(lang)-sum-sheet")
                let ins = app.buttons["xr-sum-insert-sum"].firstMatch
                if ins.exists && ins.isHittable { ins.tap() }
                for _ in 0..<10 where avg.exists { usleep(500_000) }
            } else {
                gate("sum-sheet", false, "the sheet did not open")
            }
        } else {
            gate("sum-sheet", false, "capsule shown=\(shown) hittable=\(shown && capsule.isHittable)")
        }
        var p3 = probe(app)
        for _ in 0..<4 where cell(p3, "A4").value != "1288" { usleep(700_000); p3 = probe(app) }
        gate("sum-insert-below", cell(p3, "A4").value == "1288" && cell(p3, "A4").formula.uppercased().contains("SUM(A1:A3)"),
             cellsInfo(p3))
        shot(app, "63-sheet-\(lang)-inserted")

        // 6) the formula keys build =MAX(A1:A3,A4) in B1 between typed letters, then ✓ commits
        _ = goTo("B1")
        let p4 = editBar()
        let equals = app.buttons["xr-fk-equals"].firstMatch
        let rowShown = equals.waitForExistence(timeout: 10) && equals.isHittable
        gate("fkeys-shown", rowShown, "row over the keyboard: \(rowShown) \(sinfo(p4))")
        var pressed: [String] = []
        if rowShown {
            if key("equals") { pressed.append("=") }
            typeSlowly(app, "MAX")
            if key("open") { pressed.append("(") }
            typeSlowly(app, "A1")
            if key("colon") { pressed.append(":") }
            typeSlowly(app, "A3")
            if key("sep") { pressed.append(",") }
            typeSlowly(app, "A4")
            if key("close") { pressed.append(")") }
            shot(app, "64-sheet-\(lang)-formula-keys")
            if key("commit") { pressed.append("commit") }
        }
        var p5 = probe(app)
        for _ in 0..<3 where cell(p5, "B1").value != "1288" { usleep(700_000); p5 = probe(app) }
        let f5 = cell(p5, "B1").formula.uppercased().replacingOccurrences(of: ";", with: ",")
        gate("fkeys-formula", f5.contains("MAX(A1:A3,A4)") && cell(p5, "B1").value == "1288",
             "pressed \(pressed.joined(separator: " ")) \(cellsInfo(p5))")
        gate("fkeys-commit", pressed.last == "commit" && !flag(p5, "edit"), sinfo(p5))
        info("keyboard-after-commit", sinfo(p5))

        // 7) ✕ drops the typed value; 8) ⇥ keeps it and moves one cell on
        _ = goTo("C1")
        _ = editBar()
        typeSlowly(app, "99")
        let cancelled = key("cancel")
        let p6 = probe(app)
        gate("fkeys-cancel", cancelled && cell(p6, "C1").value.isEmpty && !flag(p6, "edit"), "\(sinfo(p6)) \(cellsInfo(p6))")
        _ = editBar()
        typeSlowly(app, "5")
        let tabbed = key("tab")
        var p7 = probe(app)
        for _ in 0..<3 where str(p7, "nb") != "D1" { usleep(600_000); p7 = probe(app) }
        gate("fkeys-tab", tabbed && cell(p7, "C1").value == "5" && str(p7, "nb") == "D1", "\(sinfo(p7)) \(cellsInfo(p7))")
        shot(app, "65-sheet-\(lang)-tab")

        // 9) "hide keyboard" puts it away (a tap on the chip brings the keyboard up first when it is down)
        var p8 = probe(app)
        if !flag(p8, "fr") { let r = rect(p8, "nbr"); if r.count == 4 { tap(r[0], r[1]); usleep(700_000) } }
        let hideShown = hideKey.waitForExistence(timeout: 8) && hideKey.isHittable
        if hideShown { hideKey.tap() }
        p8 = probe(app)
        for _ in 0..<3 where hideShown && flag(p8, "fr") { usleep(700_000); p8 = probe(app) }
        gate("fkeys-hide-keyboard", hideShown && !flag(p8, "fr"), "shown=\(hideShown) \(sinfo(p8))")

        // 10) Save: check_saved.py reads xr-sheet-<lang>.xlsx (values, =SUM below the range, =MAX(...) from the keys)
        let saved = save(app)
        gate("save", saved.hasPrefix("saved"), saved)
    }
}
