import SwiftUI
import UIKit
import Combine
import UniformTypeIdentifiers

#if XR_AUTOTEST
/// CI only (build configuration "Autotest"). Opens one document straight in the editor so XCUITest can type into
/// it with the real keyboard path. Environment: XR_KIND=word|cell|slide, or XR_DOC_NAME + XR_DOC_B64 (a sample);
/// XR_DOC_NAME alone names a new blank document (its own log file). Writes Documents/<name> on every save and
/// Documents/xr-log-<name>.txt (editor log) for the workflow.
struct AutotestScreen: View {
    @State private var document: OfficeDocument
    @State private var state = "loading"
    @State private var showAbout = false
    @State private var showAccount = false
    // @State, not @StateObject: the screen must NOT redraw when the model changes. A redraw rebuilds the top bar's
    // toolbar, and a ⋯ menu open at that moment stays on screen but dead - every tap ignored (CI: the Document info
    // sheet's 15 s count stop fired while the menu was open). Only the capsule and the sheet observe the model.
    @State private var menu = DocumentMenuModel()
    @State private var recovery = "none"                    // sticky: "recovered:edited" / "recovered:" / "too-large"
    @State private var recovered: RecoveryNotice?
    @State private var tooLarge = false
    @State private var modified = "0"                      // the engine's "document modified" mark (crash test)
    @State private var ended = 0                            // "web process ended" log lines seen (the delegate fired)
    @State private var clipCount = 0
    @State private var saveAsFormats: [String] = []
    @StateObject private var controller = EditorController()
    @StateObject private var barStatus = EditorBarStatus()
    /// XR_BAR=1: the editor under the app's native top bar (plan M4a), the way EditorScreen shows it - for the bar's
    /// own test. Without it the editor fills the screen as before, so the typing tests keep their exact geometry.
    private let bar = ProcessInfo.processInfo.environment["XR_BAR"] == "1"
    private let lang = ProcessInfo.processInfo.environment["XR_LANG"] ?? AppLanguage.current
    private let name: String
    private let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    /// open: a file already in Documents (a template copy just made, TemplateAutotestRoot); XR_OPEN_NAME does the
    /// same from the environment (the template test's reopen after a relaunch).
    init(open: String? = nil) {
        let env = ProcessInfo.processInfo.environment
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if let n = open ?? env["XR_OPEN_NAME"], let data = try? Data(contentsOf: folder.appendingPathComponent(n)), !data.isEmpty {
            _document = State(initialValue: OfficeDocument(data: data, kind: OfficeKind(url: URL(fileURLWithPath: n)) ?? .word))
            name = n
        } else if let b64 = env["XR_DOC_B64"], let data = Data(base64Encoded: b64), let n = env["XR_DOC_NAME"] {
            var d = OfficeDocument(kind: OfficeKind(rawValue: env["XR_KIND"] ?? "") ?? .word)
            d.data = data
            d.kind = OfficeKind(url: URL(fileURLWithPath: n)) ?? .word
            _document = State(initialValue: d)
            name = n
        } else {
            let kind = OfficeKind(rawValue: env["XR_KIND"] ?? "") ?? .word
            _document = State(initialValue: OfficeDocument(kind: kind))
            name = env["XR_DOC_NAME"] ?? env["XR_NEW_NAME"] ?? ("xr-test." + kind.fileExtension)     // own file per test (crash, clipboard tests)
        }
        try? FileManager.default.removeItem(at: docs.appendingPathComponent("xr-log-" + name + ".txt"))
    }

    var body: some View {
        if ProcessInfo.processInfo.environment["XR_REAL"] == "1" {
            RealDocumentHarness()
        } else if bar {
            NavigationStack {
                // the real ⋯ document menu (plan M7b); the actions that would leave the test's editor (language
                // switch, share sheet) report in the state label instead
                // the real presentation chrome (plan S4): slide strip, layout picker, Present
                screen.slidesChrome(enabled: document.kind == .slide, controller: controller, ar: lang == "ar")
                      .editorTopBar(title: (name as NSString).deletingPathExtension, state: controller.state,
                                    status: barStatus, controller: controller, ar: lang == "ar",
                                    back: { state = "back" }, save: { controller.userSave() },
                                    find: { controller.find() }, menuKey: "\(lang)|\(document.kind.rawValue)",
                                    format: document.kind == .word) {
                    DocumentMenuItems(kind: document.kind, lang: lang, signedIn: false, model: menu, controller: controller,
                                      language: { state = "lang:" + $0 }, share: { state = "share" },
                                      account: { showAccount = true }, about: { showAbout = true })
                }
                .documentMenuChrome(model: menu, kind: document.kind, name: name, size: document.data.count,
                                    fileURL: docs.appendingPathComponent(name), ar: lang == "ar")
                .canvasAccessibilityNote(ar: lang == "ar")            // S12 (the test forces it: -xr.canvasNote YES)
            }
            .environment(\.layoutDirection, lang == "ar" ? .rightToLeft : .leftToRight)
            .background(UIKitLayoutDirection(rtl: lang == "ar"))
        } else {
            // UIKit mirrored as in the real app (EditorHost's appLanguageEnvironment): the typing tests type under
            // the same trait a user in Arabic gets
            screen.background(UIKitLayoutDirection(rtl: lang == "ar"))
        }
    }

    private var screen: some View {
        ZStack(alignment: .topLeading) {
            EditorWebView(document: $document, title: name, lang: ProcessInfo.processInfo.environment["XR_LANG"] ?? AppLanguage.current,
                          onCommand: handle, controller: controller)
                .ignoresSafeArea(.container, edges: [.bottom])      // same as the real editor screen
                .pdfToolBar(kind: document.kind, controller: controller,    // plan S7, as in EditorScreen
                            ar: (ProcessInfo.processInfo.environment["XR_LANG"] ?? AppLanguage.current) == "ar")
                .editorRecovery(notice: $recovered, tooLarge: tooLarge, ar: (ProcessInfo.processInfo.environment["XR_LANG"] ?? AppLanguage.current) == "ar",
                                hold: Double(ProcessInfo.processInfo.environment["XR_RECOVERY_HOLD"] ?? "") ?? 3,
                                share: { state = "share" }, back: { state = "back" })
                .sheetSum(kind: document.kind, state: controller.state, controller: controller,
                          ar: (ProcessInfo.processInfo.environment["XR_LANG"] ?? AppLanguage.current) == "ar")
            VStack(alignment: .leading, spacing: 2) {
                Text(state).font(.system(size: 6)).accessibilityIdentifier("xr-state")
                Text(recovery).font(.system(size: 6)).accessibilityIdentifier("xr-recovery")
                Text("modified:" + modified).font(.system(size: 6)).accessibilityIdentifier("xr-modified")
                EditorStateProbe(state: controller.state)
                Button("save") { controller.save() }.font(.system(size: 6)).accessibilityIdentifier("xr-save")
                // touch gate (XR_PROBE=1 only): the editor's caret / selection / zoom / focus, read by the test from a
                // label instead of a hook URL - a URL could itself change who holds the keyboard
                if ProcessInfo.processInfo.environment["XR_PROBE"] == "1" { ProbeLabel(controller: controller) }
            }
            // store screenshots (XR_CLEAN=1): the labels stay readable by the test but leave no trace in the picture
            .opacity(ProcessInfo.processInfo.environment["XR_CLEAN"] == "1" ? 0.001 : 0.02)
        }
        // the Aa format sheet as in the real editor screen (plan S1: the touch gate opens it from the keyboard bar)
        .formatSheet(controller, ar: lang == "ar")
        // the same Save As list as the real editor screen (the UI test taps a format in it)
        .saveAsCopy(formats: $saveAsFormats, lang: ProcessInfo.processInfo.environment["XR_LANG"] ?? AppLanguage.current,
                    controller: controller)
        // test-only trigger that needs no tapping: XCUIApplication.open(URL("xrero-autotest://save"))
        .onOpenURL { url in
            guard url.scheme == "xrero-autotest" else { return }
            if url.host == "save" { controller.save() }
            if url.host == "usersave" { controller.userSave() }   // the user's Save (the bar's ⋯ > Save, asc_Save)
            if url.host == "caret" {            // typing tests: where the new page's first line is (the editor's own text
                                                // cursor, which sits there after open) - a fixed tap point drifts when
                                                // the ribbon height changes and then lands in the page margin
                let js = """
                (function(){var f=document.querySelector('iframe');var w=f&&f.contentWindow;var d=w&&w.document;
                 var e=d&&d.getElementById('id_target_cursor');if(!e)return 'caret:none';var r=e.getBoundingClientRect(),o=f.getBoundingClientRect();
                 if(r.height<4)return 'caret:none';return 'caret:'+Math.round(o.left+r.left)+','+Math.round(o.top+r.top+r.height/2);})()
                """
                controller.coordinator?.web?.evaluateJavaScript(js) { r, _ in state = (r as? String) ?? "caret:none" }
            }
            if url.host == "about" { showAbout = true }      // About & Licences over the open editor
            if url.host == "busy" {             // touch gate: the editor page held busy right after the NEXT touch (the
                                                // keyboard coming back after an alert, a redraw), so a short tap reaches
                                                // the engine's touch manager late, as a long press: it must stay a tap
                let ms = Int(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "ms" }?.value ?? "") ?? 900
                controller.call(Self.busyJS(ms)) { r, e in handle("log", "busy hook: \((r as? String) ?? e ?? "?")") }
            }
            if url.host == "doctext" {          // template test (S8): the document's text after a reopen (Word only)
                controller.call("var a=(this.Asc&&this.Asc.editor)||this.editor;var d=a&&a.WordControl&&a.WordControl.m_oLogicDocument;"
                                + "return d&&d.GetText?String(d.GetText()).replace(/[\\s]+/g,' ').slice(0,4000):'none';") { r, e in
                    state = "doctext:" + ((r as? String) ?? (e ?? "none"))
                }
            }
            if url.host == "note",              // touch gate: the test's results into the editor log (check_saved.py)
               let t = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "t" })?.value {
                for line in t.split(separator: "\n") { handle("log", String(line)) }
            }
            if url.host == "reopen" {           // typing gate: reload the editor from the saved bytes (the document data
                                                // the save handler updated; the file on disk is checked by check_saved.py)
                state = "reopening"
                controller.coordinator?.load()
            }
            if url.host == "crash" {            // crash recovery test: end the editor's web process the way iOS does
                guard let web = controller.coordinator?.web else { return }
                // WebKit's own test hook (WKWebViewPrivate). Only in this CI build configuration, never in the app.
                let kill = NSSelectorFromString("_killWebContentProcess")
                if web.responds(to: kill) {
                    handle("log", "autotest: ending the web content process")
                    let before = ended
                    _ = web.perform(kill)
                    // if this WebKit ends the process without telling the delegate, still prove the recovery path
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        guard ended == before else { return }
                        handle("log", "autotest: no termination callback within 5 s - running the recovery path directly")
                        controller.coordinator?.recoverFromTermination()
                    }
                } else {
                    handle("log", "autotest: no kill hook in this WebKit - running the recovery path directly")
                    controller.coordinator?.recoverFromTermination()
                }
            }
            if url.host == "filemenu" {         // opens File and logs which entries are visible (check_saved.py)
                let js = """
                (function(){var f=document.querySelector('iframe');var w=f&&f.contentWindow;if(!w)return 'no frame';
                 var d=w.document,p=d.getElementById('file-menu-panel'),t=d.querySelector('a[data-tab="file"]');
                 var tab=!!(t&&t.offsetParent);w.XreroHost.log('file tab shown: '+(tab?1:0));
                 if(!p||p.style.display==='none'){if(tab)t.click();else w.XreroHost.log('all tools: '+(w.__xrAllTools?w.__xrAllTools():'missing'));}
                 setTimeout(function(){var ids=[].slice.call(d.querySelectorAll('#file-menu-panel .panel-menu > li.fm-btn'))
                   .filter(function(li){return w.getComputedStyle(li).display!=='none';}).map(function(li){return li.id;});
                   var tiles=[].slice.call(d.querySelectorAll('#panel-saveas .format-item'))
                   .filter(function(el){return w.getComputedStyle(el).display!=='none';})
                   .map(function(el){var b=el.querySelector('.btn-doc-format');return b?b.getAttribute('format'):'?';});
                   w.XreroHost.log('file menu visible: '+ids.join(' '));
                   w.XreroHost.log('download as formats: '+tiles.join(' '));},1500);return 'ok';})()
                """
                controller.coordinator?.web?.evaluateJavaScript(js) { r, e in handle("log", "filemenu: \(r ?? e?.localizedDescription ?? "?")") }
            }
            if url.host == "tile" {             // taps a "Download As" format tile, e.g. xrero-autotest://tile?f=67 (ODT)
                let f = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "f" }?.value ?? "")
                    .filter(\.isNumber)
                let js = """
                (function(){var f=document.querySelector('iframe');var w=f&&f.contentWindow;if(!w)return 'no frame';
                 var b=w.document.querySelector('#panel-saveas .btn-doc-format[format="\(f)"]');if(!b)return 'no tile';
                 b.click();return 'ok';})()
                """
                controller.coordinator?.web?.evaluateJavaScript(js) { r, e in handle("log", "tile \(f): \(r ?? e?.localizedDescription ?? "?")") }
            }
            // engine API calls go through controller.call (the editor frame), like the app's own controls
            if url.host == "saveas" {           // the call File > Save As makes (fallback when the tap cannot reach it)
                controller.call("var a=window.Asc&&Asc.editor||window.editor;if(!a)return 'no editor';a.asc_DownloadAs();return 'ok';") { r, e in
                    handle("log", "saveas: \((r as? String) ?? e ?? "?")")
                }
            }
            if url.host == "pdfedit" {          // PDF editing test: rotate page 1, add a page, add a free-text box
                controller.call("""
                var ed=window.Asc&&Asc.editor;if(!ed)return 'no editor';ed.asc_RotatePage(90,[0]);ed.asc_AddPage(1);
                setTimeout(function(){try{ed.AddFreeTextAnnot(0);}catch(e){}},800);return 'ok';
                """) { r, e in handle("log", "pdfedit: \((r as? String) ?? e ?? "?")") }
            }
            if url.host == "selectall" {        // clipboard test: select the document's text (selection is not under test)
                controller.call("var ed=window.Asc&&Asc.editor;if(!ed)return 'no editor';ed.asc_EditSelectAll();return 'ok';") { r, e in
                    handle("log", "selectall: \((r as? String) ?? e ?? "?")")
                }
            }
            if url.host == "addtext",           // clipboard test: the text to copy, without the keyboard (typing has its own tests)
               let t = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "t" })?.value {
                let arg = String(data: (try? JSONSerialization.data(withJSONObject: [t])) ?? Data("[\"\"]".utf8), encoding: .utf8) ?? "[\"\"]"
                controller.call("var ed=window.Asc&&Asc.editor;if(!ed)return 'no editor';ed.asc_AddText(\(arg)[0]);return 'ok';") { r, e in
                    handle("log", "addtext: \((r as? String) ?? e ?? "?")")
                }
            }
            if url.host == "uikitdir" {         // ⋯ menu test (M7b review): UIKit's own direction, which the menus it
                                                // draws for SwiftUI follow (UIKitLayoutDirection)
                let d = controller.coordinator?.web?.effectiveUserInterfaceLayoutDirection
                state = (d == nil ? "dir:none" : (d == .rightToLeft ? "dir:rtl" : "dir:ltr")) +
                        (UIKitLayoutDirection.forced ? "+force" : "")
            }
            if url.host == "menuprobe" {        // ⋯ menu test (M7b): is the editor's Find panel / File backstage open,
                                                // is the File tab hidden; "close" also shuts both again
                let close = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "close" }?.value == "1"
                state = "probing"                   // the test waits for a fresh "menu:" answer
                controller.call("""
                var app=window.DE||window.PE||window.SSE||window.PDFE,lm=app&&app.getController('LeftMenu');if(!lm)return 'menu:fail no left menu';
                var fm=lm.leftMenu.menuFile,f=fm&&fm.isVisible()?1:0,s=window.__xrSearchShown&&__xrSearchShown()?1:0,vp=app.getController('Viewport');
                var t=document.querySelector('a[data-tab="file"]'),tab=t&&t.offsetParent?1:0;
                if(\(close)){try{if(f)fm.hide();if(s&&lm.isSearchPanelVisible())lm.onShowHideSearch(false);if(s&&vp.isSearchBarVisible())vp.searchBar.hide();}catch(e){}}
                return 'menu:search='+s+' file='+f+' filetab='+tab;
                """) { r, e in
                    let res = (r as? String) ?? "menu:fail " + (e ?? "?")
                    handle("log", res)
                    state = res
                }
            }
            if url.host == "export" {           // Export ▸ without the menu (spreadsheet / presentation formats)
                let ext = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "f" }?.value ?? ""
                menu.export(ext, controller)
            }
            if url.host == "docinfo" {          // Document info counts without the sheet (spreadsheet / presentation)
                state = "counting"
                controller.docInfo()
            }
            if url.host == "pdfspike" {         // the PDF spike (M7b): can this x2t build write a PDF? (log only)
                controller.call("return window.__xrExport ? __xrExport('pdf', true) : 'no export';") { r, e in
                    handle("log", "pdf spike request: \((r as? String) ?? e ?? "?")")
                }
            }
            if url.host == "pdfstate" {         // PDF bar gate (S7): the tool that is on + the page objects, as JSON
                let n = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "n" }?.value ?? "0"
                controller.call("return window.__xrPdfState ? __xrPdfState() : '{}';") { r, e in
                    state = "pdf\(n):" + ((r as? String) ?? ("{\"error\":\"" + (e ?? "?") + "\"}"))
                }
            }
            if url.host == "pdfsigdelete" { SignatureStore.delete() }   // PDF bar gate: start without a saved signature
            if url.host == "bridge" { checkBridge() }
            if url.host == "contract" { checkContract() }
            if url.host == "openhome" {         // clipboard test: phones fold the ribbon - drop the Home panel so the
                                                // test's tap on Copy / Paste lands on the button, never on the page
                let js = """
                (function(){var f=document.querySelector('iframe');var d=f&&f.contentDocument;if(!d)return 'no editor';
                 var bar=d.querySelector('.toolbar.folded');if(!bar)return 'not folded';if(bar.classList.contains('expanded'))return 'open';
                 var a=d.querySelector('.ribtab > a[data-tab="home"]');if(!a)return 'no home tab';
                 a.parentNode.classList.remove('active');a.parentNode.click();return 'opened';})()
                """
                controller.coordinator?.web?.evaluateJavaScript(js) { r, e in handle("log", "openhome: \(r ?? e?.localizedDescription ?? "?")") }
            }
            if url.host == "pbset",             // clipboard test: text "from another app" (written in-app: no Allow Paste prompt)
               let t = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "t" })?.value {
                UIPasteboard.general.string = t
            }
            if url.host == "rpopen" {           // rotation test (M3): open the right settings panel the way a user does
                let js = """
                (function(){var f=document.querySelector('iframe');var d=f&&f.contentWindow&&f.contentWindow.document;if(!d)return 'no editor';
                var b=[].slice.call(d.querySelectorAll('#right-menu .tool-menu-btns .btn')).filter(function(e){return e.offsetParent&&!e.classList.contains('disabled')&&!e.disabled;})[0];
                if(!b)return 'no button';if(!b.classList.contains('active'))b.click();return 'clicked';})()
                """
                controller.coordinator?.web?.evaluateJavaScript(js) { r, _ in
                    handle("log", "rpopen: \(r ?? "?")")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        let wjs = "(function(){var f=document.querySelector('iframe');var d=f&&f.contentWindow&&f.contentWindow.document;var rm=d&&d.querySelector('#right-menu');return 'rp:'+(rm?Math.round(rm.getBoundingClientRect().width):0);})()"
                        controller.coordinator?.web?.evaluateJavaScript(wjs) { r2, _ in state = (r2 as? String) ?? "rp:0" }
                    }
                }
            }
            if url.host == "appearance" {       // M6: switch the editor to dark / back to light the way iOS does (a trait
                                                // change on the web view -> the live switch, no reload)
                let dark = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "dark" }?.value == "1"
                controller.coordinator?.web?.overrideUserInterfaceStyle = dark ? .dark : .light
                // the top bar's test: the whole window (the native bar too), as when iOS itself switches
                if bar { controller.coordinator?.web?.window?.overrideUserInterfaceStyle = dark ? .dark : .light }
                handle("log", "autotest: appearance " + (dark ? "dark" : "light"))
            }
            if url.host == "chrome" {           // M6 gate: neutral editor chrome - theme follows the appearance, line
                                                // tabs, Xrero kind accent on the tab underline, iOS bar colour on the tab
                                                // row, system font, canvas colour, no tab arrows on touch. Also reports
                                                // the tab row (web view points) and its scroll position for the swipe test.
                                                // Also: a primary dialog button's label contrast (>= 4.5:1, opened and
                                                // closed here), the editor instance (inst=: same id = no reload), undo
                                                // still available (undo=) and, with has=, the typed text still there.
                let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let want = q.first { $0.name == "want" }?.value == "dark" ? "dark" : "light"
                let tag = "chrome" + (q.first { $0.name == "n" }?.value ?? "").filter(\.isNumber) + ":"    // this run's answer
                let has = (q.first { $0.name == "has" }?.value ?? "").filter { $0.isLetter || $0.isNumber || $0 == " " }
                let js = """
                (function(){var f=document.querySelector('iframe');var w=f&&f.contentWindow;var d=w&&w.document;if(!d||!d.body)return '\(tag)fail no editor';
                var want='\(want)',bad=[],b=d.body,cs=w.getComputedStyle(b),p=w.location.pathname;
                var th=b.classList.contains('theme-night')?'dark':b.classList.contains('theme-white')?'light':'other';if(th!==want)bad.push('theme '+th+' ('+b.className.slice(0,80)+')');
                var S=w.Common&&w.Common.Utils&&w.Common.Utils.InternalSettings;var ts=S&&S.get('settings-tab-style');if(ts!=='line')bad.push('tab style '+ts);
                var kind=/spreadsheeteditor/.test(p)?'spreadsheet':/presentationeditor/.test(p)?'presentation':/pdfeditor/.test(p)?'pdf':'document';
                var acc={light:{document:'#2f6bd8',spreadsheet:'#1e9e5a',presentation:'#e0612f',pdf:'#c62828'},dark:{document:'#7aa7f0',spreadsheet:'#4cc38a',presentation:'#ff8a65',pdf:'#ff6b6b'}}[want][kind];
                var tok=function(n){var v=cs.getPropertyValue(n).trim().toLowerCase();return v.indexOf('var(--')===0?cs.getPropertyValue(v.slice(4,-1)).trim().toLowerCase():v;};
                var u=tok('--highlight-toolbar-tab-underline-'+kind);if(u!==acc)bad.push('accent '+u+' want '+acc);
                var cv=tok('--canvas-background');if(cv!==(want==='dark'?'#000':'#f2f2f7'))bad.push('canvas '+cv);
                var ul=d.querySelector('.toolbar .tabs > ul'),bgOf=function(e){while(e&&e.nodeType===1){var c=w.getComputedStyle(e).backgroundColor;if(c&&c!=='transparent'&&c.slice(-4)!==', 0)')return c;e=e.parentNode;}return 'none';};
                var bg=ul?bgOf(ul):'no tabs';if(bg!==(want==='dark'?'rgb(28, 28, 30)':'rgb(249, 249, 249)'))bad.push('tab row '+bg);
                var a=d.querySelector('.toolbar .tabs .ribtab > a');var ff=a?w.getComputedStyle(a).fontFamily:'';if(!/apple-system|system-ui/.test(ff))bad.push('font '+ff.slice(0,40));
                var coarse=!w.matchMedia('(any-pointer:fine)').matches;var arrows=[].slice.call(d.querySelectorAll('.toolbar .tabs .scroll')).filter(function(e){return e.offsetParent;}).length;if(coarse&&arrows)bad.push('tab arrows '+arrows);
                if(kind==='presentation'){var pb=d.querySelector('.xr-present-btn');if(pb&&pb.offsetParent){var pr=pb.getBoundingClientRect(),pc=w.getComputedStyle(pb).backgroundColor;
                 var hx=function(c){return 'rgb('+parseInt(c.substr(1,2),16)+', '+parseInt(c.substr(3,2),16)+', '+parseInt(c.substr(5,2),16)+')';};
                 if(pc!==hx(want==='dark'?'#ff8a65':'#c4502a'))bad.push('present '+pc);if(pr.height<35||pr.height>37)bad.push('present height '+Math.round(pr.height));}
                 else bad.push('present button missing');}
                var lum=function(c){var v=(String(c).match(/[0-9.]+/g)||[]).slice(0,3).map(function(x){x=x/255;return x<=0.03928?x/12.92:Math.pow((x+0.055)/1.055,2.4);});return v.length<3?-1:0.2126*v[0]+0.7152*v[1]+0.0722*v[2];};
                var U=w.Common&&w.Common.UI,dlg=null,dinfo='none';try{dlg=U&&U.info?U.info({msg:'Xrero',buttons:['ok']}):null;}catch(e){bad.push('dialog '+e);}
                if(dlg){var db=dlg.$window&&dlg.$window.find('.dlg-btn.primary')[0];if(!db)bad.push('dialog: no primary button');else{var dc=w.getComputedStyle(db),l1=lum(dc.color),l2=lum(dc.backgroundColor),cr=(Math.max(l1,l2)+0.05)/(Math.min(l1,l2)+0.05);
                 dinfo=cr.toFixed(2);if(l1<0||l2<0||cr<4.5)bad.push('dialog button '+dc.color+' on '+dc.backgroundColor+' = '+dinfo);}try{dlg.close();}catch(e){}}else bad.push('dialog did not open');
                if(!w.__xrInst)w.__xrInst=Math.random().toString(36).slice(2,8);
                var api=(w.Asc&&w.Asc.editor)||w.editor,undo='-',txt='-';try{undo=api&&api.asc_getCanUndo&&api.asc_getCanUndo()?'1':'0';}catch(e){}
                var has='\(has)';if(has){try{var ld=api.WordControl&&api.WordControl.m_oLogicDocument;txt=ld&&ld.GetText&&ld.GetText().indexOf(has)>=0?'1':'0';}catch(e){txt='0';}}
                var r=ul&&ul.getBoundingClientRect(),o=f.getBoundingClientRect();
                var info=want+' '+kind+' inst='+w.__xrInst+' undo='+undo+' text='+txt+' dialog='+dinfo+' tabs='+(r?Math.round(o.left+r.left)+','+Math.round(o.left+r.right)+','+Math.round(o.top+r.top+r.height/2)+','+Math.round(Math.abs(ul.scrollLeft))+','+(ul.scrollWidth-ul.clientWidth):'none');
                return bad.length?'\(tag)fail '+bad.join('; ')+' ('+info+')':'\(tag)ok ('+info+')';})()
                """
                controller.coordinator?.web?.evaluateJavaScript(js) { r, e in
                    let res = (r as? String) ?? tag + "fail " + (e?.localizedDescription ?? "no result")
                    handle("log", res)
                    state = res
                }
            }
            if url.host == "geom" {             // iPad layout gate (M3): status bar, sheet tabs, ribbon, settings panel
                // Inside the editor frame: visible status-bar controls must not overlap, no empty label pills, nothing
                // under the window-resize corner (28 pt), spreadsheets show at least one sheet tab, ribbon buttons and
                // their captions end inside the toolbar, and the right settings panel is closed in portrait.
                let js = """
                (function(){var f=document.querySelector('iframe');var w=f&&f.contentWindow;var d=w&&w.document;if(!d||!d.querySelector('#statusbar'))return 'geom:fail no editor';
                var bad=[],vis=function(e){if(!e)return false;var r=e.getBoundingClientRect(),s=w.getComputedStyle(e);return r.width>1&&r.height>1&&s.visibility!=='hidden'&&s.display!=='none';};
                var R=function(e){var r=e.getBoundingClientRect();return {l:r.left,t:r.top,r:r.right,b:r.bottom};};
                var sb=d.querySelector('#statusbar');var items=[].slice.call(sb.querySelectorAll('.btn-toolbar,label,#status-sheets-bar li>span')).filter(vis).filter(function(e){return !e.closest('.dropdown-menu')&&!(e.tagName==='LABEL'&&e.closest('.btn-toolbar'));});
                var clip=d.querySelector('#status-sheets-bar-box');var cb=clip&&R(clip);
                items=items.map(function(e){var r=R(e);if(cb&&clip.contains(e)){r.l=Math.max(r.l,cb.l);r.r=Math.min(r.r,cb.r);}return {e:e,r:r};}).filter(function(o){return o.r.r-o.r.l>1;});
                for(var i=0;i<items.length;i++)for(var j=i+1;j<items.length;j++){var a=items[i],b=items[j];if(a.e.contains(b.e)||b.e.contains(a.e))continue;
                 var ox=Math.min(a.r.r,b.r.r)-Math.max(a.r.l,b.r.l),oy=Math.min(a.r.b,b.r.b)-Math.max(a.r.t,b.r.t);if(ox>2&&oy>2)bad.push('overlap '+(a.e.id||a.e.textContent.trim().slice(0,10))+'/'+(b.e.id||b.e.textContent.trim().slice(0,10)));}
                [].slice.call(sb.querySelectorAll('label')).filter(vis).forEach(function(l){if(!l.textContent.trim())bad.push('empty label '+l.id);});
                var maxR=0;items.forEach(function(o){maxR=Math.max(maxR,o.r.r);});if(maxR>w.innerWidth-28)bad.push('under resize corner '+Math.round(maxR)+'/'+w.innerWidth);
                if(/spreadsheeteditor/.test(w.location.pathname)){var tabs=items.filter(function(o){return clip&&clip.contains(o.e)&&o.r.r-o.r.l>20;});if(!tabs.length)bad.push('no sheet tab visible');}
                var bc=d.querySelector('.toolbar .box-controls'),tb=d.querySelector('#toolbar'),tx=d.querySelector('#toolbar .toolbar');if(vis(bc)&&tb&&tx){var lim=Math.min(R(tb).b,R(tx).b)+1;
                 if(R(bc).b>lim)bad.push('ribbon row cut '+Math.round(R(bc).b)+'>'+Math.round(lim));
                 var mid=d.querySelector('#viewport-vbox-layout > .layout-item.middle');if(mid&&R(mid).t<R(tb).b-1)bad.push('ribbon over page '+Math.round(R(mid).t)+'<'+Math.round(R(tb).b));
                 [].slice.call(bc.querySelectorAll('.panel.active .btn-toolbar, .panel.static .btn-toolbar, .panel.active .btn-toolbar .caption, .panel.static .btn-toolbar .caption')).filter(vis).forEach(function(e){var b=R(e).b,own=e.classList.contains('caption')&&e.closest('.btn-toolbar');
                  if(b>lim||b>R(bc).b+1)bad.push('ribbon clipped '+(e.id||e.textContent.trim().slice(0,12))+' '+Math.round(b)+'>'+Math.round(Math.min(lim,R(bc).b+1)));
                  else if(own&&b>R(own).b+6)bad.push('caption below button '+e.textContent.trim().slice(0,12)+' '+Math.round(b)+'>'+Math.round(R(own).b));});}
                var rm=d.querySelector('#right-menu');var rmw=rm?Math.round(rm.getBoundingClientRect().width):0;if(w.innerWidth<w.innerHeight&&rmw>100)bad.push('right panel open in portrait '+rmw);
                var S=w.Common&&w.Common.Utils&&w.Common.Utils.InternalSettings;var info='w='+w.innerWidth+'x'+w.innerHeight+' items='+items.length+' rm='+rmw+(bc&&tb?' bc='+Math.round(R(bc).t)+'-'+Math.round(R(bc).b)+' tb='+Math.round(R(tb).t)+'-'+Math.round(R(tb).b):'')+(tx?' tx='+Math.round(R(tx).b):'')+(S?' ctrl='+S.get('toolbar-height-controls')+' normal='+S.get('toolbar-height-normal'):'');
                return bad.length?'geom:fail '+bad.slice(0,6).join('; ')+' ('+info+')':'geom:ok ('+info+')';})()
                """
                controller.coordinator?.web?.evaluateJavaScript(js) { r, e in
                    let res = (r as? String) ?? "geom:fail " + (e?.localizedDescription ?? "no result")
                    handle("log", res)
                    state = res
                }
            }
        }
        .sheet(isPresented: $showAbout) { AboutSheet() }
        .sheet(isPresented: $showAccount) { AccountView() }
    }

    /// The "busy" hook (touch gate): arms a ONE-shot listener in the editor frame that holds the page's main thread
    /// busy for `ms` right AFTER the engine's own handler has taken the next finger down (window bubble phase of
    /// pointerdown; the touchstart that WebKit dispatches after it is the fallback if the engine stopped the
    /// pointerdown there). The finger's up then reaches the touch manager `ms` late, so a short tap is timed as a long
    /// press - what the keyboard coming back after the Rename alert did (CI runs 136 / 138). The page must keep it a
    /// tap: xr-host.js editMenu logs "kept as a tap" and shows no menu. CI build only.
    private static func busyJS(_ ms: Int) -> String {
        """
        var ms=\(max(100, min(ms, 3000))),done=false;
        function busy(why){if(done)return;done=true;
         window.removeEventListener('pointerdown',pd,false);window.removeEventListener('touchstart',ts,true);
         var t0=performance.now();while(performance.now()-t0<ms){}
         if(window.XreroHost&&XreroHost.log)XreroHost.log('busy hook: the page was held busy '+ms+' ms right after a touch ('+why+')');}
        function pd(e){if(e.pointerType==='touch')busy('pointerdown');}
        function ts(){busy('touchstart');}
        window.addEventListener('pointerdown',pd,false);
        window.addEventListener('touchstart',ts,{capture:true,passive:true});
        return 'armed '+ms+' ms';
        """
    }

    /// Bridge check (20.3 F0): a native call reaches the engine and the engine's answer comes back through the state
    /// channel - Bold on, then off, through controller.call; EditorState must follow both, show undo after the typing
    /// test, a text selection, and the channel's callbacks must stay within the typing budget (< 0.2 ms average).
    /// Result in the state label: "bridge:ok (...)" or "bridge:fail <reasons> (...)".
    private func checkBridge() {
        state = "bridge:running"
        let s = controller.state
        func after(_ d: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + d, execute: f) }
        controller.call("__xrApi.put_TextPrBold(true);return 'ok';") { r1, e1 in
            after(1.5) {
                let boldOn = s.bold
                controller.call("__xrApi.put_TextPrBold(false);return 'ok';") { r2, e2 in
                    after(1.5) {
                        let boldOff = !s.bold
                        controller.call("return window.__xrState ? __xrState() : '';") { r3, e3 in
                            var n = 0.0, ms = 0.0, mx = 0.0
                            if let j = (r3 as? String)?.data(using: .utf8),
                               let o = (try? JSONSerialization.jsonObject(with: j)) as? [String: Any] {
                                n = (o["n"] as? Double) ?? 0; ms = (o["ms"] as? Double) ?? 0; mx = (o["max"] as? Double) ?? 0
                            }
                            let avg = n > 0 ? ms / n : 0
                            var bad: [String] = []
                            if (r1 as? String) != "ok" || (r2 as? String) != "ok" { bad.append("call failed: \(e1 ?? "-") / \(e2 ?? "-")") }
                            if !boldOn { bad.append("Bold on did not reach the app") }
                            if !boldOff { bad.append("Bold off did not reach the app") }
                            if !s.canUndo { bad.append("no undo after typing") }
                            if s.selection != .text { bad.append("selection \(s.selection.rawValue), not text") }
                            if s.updates == 0 { bad.append("no state message") }
                            if n == 0 { bad.append("no timed callbacks (\(e3 ?? "?"))") }
                            if n >= 20 && avg >= 0.2 { bad.append(String(format: "callbacks %.3f ms on average (budget 0.2)", avg)) }
                            let res = (bad.isEmpty ? "bridge:ok" : "bridge:fail " + bad.joined(separator: "; ")) +
                                String(format: " (%@ callbacks=%.0f avg=%.4fms max=%.2fms)", s.summary, n, avg, mx)
                            handle("log", res)
                            state = res
                        }
                    }
                }
            }
        }
    }

    /// Engine-contract check (20.3 F0) in the running editor: every entry of the bundled xr-contract.json that
    /// applies to this editor and device must exist (globals, API methods, DOM, controllers). The build step
    /// (scripts/check_contract.py) checks the same names in the editors' code. Result: "contract:ok|fail ...".
    private func checkContract() {
        let url = Bundle.main.resourceURL!.appendingPathComponent("web/xr-contract.json")
        guard let manifest = try? String(contentsOf: url, encoding: .utf8) else { state = "contract:fail no xr-contract.json"; return }
        let js = """
        var M=\(manifest), kind='\(document.kind.rawValue)', device=Math.min(screen.width,screen.height)>=600?'tablet':'phone';
        var apps={word:'DE',cell:'SSE',slide:'PE',pdf:'PDFE'}, miss=[], n=0;
        function get(o,p){var a=p.split('.');for(var i=0;i<a.length;i++){if(o==null)return undefined;o=o[a[i]];}return o;}
        M.checks.forEach(function(c){
          if(c.editors&&c.editors.indexOf(kind)<0)return; if(c.devices&&c.devices.indexOf(device)<0)return;
          var ok, what;
          if(c.kind==='global'){what=c.path;var v=get(window,c.path);ok=v!==undefined&&v!==null&&(!('equals' in c)||v===c.equals);}
          else if(c.kind==='api'){what='api.'+c.name;ok=!!window.__xrApi&&typeof window.__xrApi[c.name]==='function';}
          else if(c.kind==='dom'){what=c.selector;ok=!!document.querySelector(c.selector);}
          else if(c.kind==='controller'){what=apps[kind]+'.'+c.name+(c.path?'.'+c.path:'');var app=window[apps[kind]],ctl=null;
            try{ctl=app&&app.getController&&app.getController(c.name);}catch(e){}ok=!!ctl&&(!c.path||get(ctl,c.path)!=null);}
          else return;
          n++; if(!ok)miss.push(what);
        });
        return (miss.length?'contract:fail missing '+miss.join(', '):'contract:ok')+' ('+n+' checks, '+kind+', '+device+')';
        """
        controller.call(js) { r, e in
            let res = (r as? String) ?? "contract:fail " + (e ?? "no result")
            handle("log", res)
            state = res
        }
    }

    private func handle(_ cmd: String, _ param: String) {
        barStatus.note(cmd, param)
        menu.note(cmd, param)
        switch cmd {
        case "ready": state = "ready"; tooLarge = false
        case "modified": modified = param
        case "recovered":
            recovery = "recovered:" + param
            recovered = RecoveryNotice(edited: param == "edited")
        case "too-large":
            recovery = "too-large"
            recovered = nil
            tooLarge = true
        case "saved":
            try? document.data.write(to: docs.appendingPathComponent(name), options: .atomic)
            state = "saved:" + param
        case "export-failed": state = "export-failed:" + param
        case "docinfo": state = "docinfo:" + param
        case "pdf-placed": state = "placed:" + param           // PDF bar (S7): a picture reached the page (or not)
        case "saveas": saveAsFormats = param.split(separator: ",").map(String.init)
        case "export":                       // Save As copy -> Documents/<name> for the workflow to check
            // (an export in the document's own format gets an "exp-" name: the test document's file is not replaced)
            let src = URL(fileURLWithPath: param)
            let dst = docs.appendingPathComponent((src.lastPathComponent == name ? "exp-" : "") + src.lastPathComponent)
            try? FileManager.default.removeItem(at: dst)
            try? FileManager.default.copyItem(at: src, to: dst)
            state = "exported:" + dst.lastPathComponent
        case "log":
            let line = (param + "\n").data(using: .utf8)!
            let url = docs.appendingPathComponent("xr-log-" + name + ".txt")      // one log per test document
            if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line); try? h.close() }
            else { try? line.write(to: url) }
            if param.hasPrefix("web process ended") { ended += 1 }
            if param.hasPrefix("open failed") || param.hasPrefix("engine error") { state = "error: " + param }
            // clipboard test: each finished Copy / Paste shows (numbered, so the test sees every new one)
            if param.hasPrefix("copy: ") || param.hasPrefix("paste: ") { clipCount += 1; state = "clip\(clipCount) " + param }
        default: break
        }
    }
}

/// The editor's state as one line for the UI tests (EditorState.summary); observes the state object itself, the way
/// the app's own controls will.
private struct EditorStateProbe: View {
    @ObservedObject var state: EditorState
    var body: some View {
        Text(state.summary).font(.system(size: 6)).accessibilityIdentifier("xr-editor-state")
    }
}

/// Touch gate probe label (XR_PROBE=1). Its own view with its own state, so the 0.5 s updates redraw this one line
/// and not the editor screen. "t=<ms since 1970>|<json>": the test (same clock on the simulator) waits for a probe
/// taken after its last action.
private struct ProbeLabel: View {
    let controller: EditorController
    @State private var probe = "t=0|{}"
    @State private var probing = false
    @State private var keyboardUp = false
    private static let tick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(probe).font(.system(size: 6)).lineLimit(1).frame(maxWidth: 40, alignment: .leading)
            .allowsHitTesting(false).accessibilityIdentifier("xr-probe")
            .onReceive(Self.tick) { _ in poll() }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in keyboardUp = true }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in keyboardUp = false }
    }

    /// Touch gate probe (Word): the caret's place on screen (web view points) and in the document (dx / dy in mm on
    /// page dpg: unchanged when only the view scrolled), the selected text, the document text,
    /// bold at the caret (Bold or, for Arabic script, BoldCS), the engine zoom, the visual viewport scale (1 = WebKit is not magnifying a bitmap), who has
    /// focus in the editor frame, whether the phone ribbon is folded, plus keypress-to-frame latency samples taken by
    /// listeners on the editor's input field (keydown/input -> second requestAnimationFrame, not the canvas paint itself;
    /// simulator figures: informational only). Native side: does the web view
    /// hold first responder (the keyboard), and is a software keyboard shown.
    private static let probeJS = """
    (function(){var f=document.querySelector('iframe');var w=f&&f.contentWindow;var d=w&&w.document;var a=w&&w.Asc&&w.Asc.editor;
     if(a&&d&&a.wb&&a.wbModel&&!a.WordControl){var r={sheet:1},o=f.getBoundingClientRect();
      var q=function(e){if(!e||!e.offsetParent)return null;var b=e.getBoundingClientRect();return [Math.round(o.left+b.left+b.width/2),Math.round(o.top+b.top+b.height/2),Math.round(b.width),Math.round(b.height)];};
      var nb=d.getElementById('ce-cell-name'),cc=d.getElementById('ce-cell-content');
      r.nb=nb?nb.value:'';r.nbr=q(nb);r.nbfs=nb?w.getComputedStyle(nb).fontSize:'';r.fb=q(d.getElementById('cell-editing-box'));r.ce=q(cc);r.cefs=cc?w.getComputedStyle(cc).fontSize:'';
      var ae=d.activeElement;r.focus=ae?(ae.id||ae.tagName):'';r.area=!!ae&&(ae.id==='ce-cell-content'||ae.id==='ce-cell-name');r.hasFocus=d.hasFocus();
      try{r.edit=!!a.asc_getCellEditMode();}catch(e){}
      var mb=d.getElementById('status-math-box');r.mathbox=!!mb&&!!mb.offsetParent&&w.getComputedStyle(mb).display!=='none';
      try{var ws=a.wbModel.getActiveWs();r.cells={};['A1','A2','A3','A4','B1','C1','D1'].forEach(function(n){var g=ws.getCell3(+n.slice(1)-1,n.charCodeAt(0)-65);r.cells[n]=[String(g.getValueWithFormat()||''),String(g.getFormula()||'')];});}catch(e){r.cellsErr=String(e);}
      r.menu=[].slice.call(d.querySelectorAll('.dropdown-menu')).filter(function(m){return w.getComputedStyle(m).display!=='none'&&m.getBoundingClientRect().height>4;}).length;
      return JSON.stringify(r);}
     if(!a||!d||!a.WordControl)return JSON.stringify({err:'no editor'});
     var r={},o=f.getBoundingClientRect(),c=d.getElementById('id_target_cursor');
     if(c){var sd=c.style.display,sv=c.style.visibility;c.style.display='block';c.style.visibility='visible';var b=c.getBoundingClientRect();
      c.style.display=sd;c.style.visibility=sv;r.caretShown=(sd!=='none'||sv==='visible');
      if(b.height>=4){r.cx=Math.round(o.left+b.left);r.cy=Math.round(o.top+b.top+b.height/2);r.ch=Math.round(b.height);}}
     var ld=a.WordControl.m_oLogicDocument;
     if(ld){try{r.sel=(ld.IsSelectionUse()&&!ld.IsSelectionEmpty())?(ld.GetSelectedText(false)||''):'';}catch(e){r.sel='';r.selErr=String(e);}
      try{r.text=ld.Content.map(function(p){return p.GetText?p.GetText({ParaSeparator:''}):'';}).join('|');r.paras=ld.Content.length;}catch(e){r.text='';}
      try{var tp=ld.GetCalculatedTextPr();r.bold=!!(tp.Bold||tp.BoldCS);}catch(e){}
      try{var q=ld.GetCurPosXY();r.dx=Math.round(q.X*10)/10;r.dy=Math.round(q.Y*10)/10;r.dpg=q.PageNum;}catch(e){}}
     r.zoom=a.WordControl.m_nZoomValue;
     r.vv=window.visualViewport?Math.round(window.visualViewport.scale*100)/100:1;r.vvi=w.visualViewport?Math.round(w.visualViewport.scale*100)/100:1;
     var ic=w.AscCommon&&w.AscCommon.g_inputContext,A=ic&&ic.HtmlArea,ae=d.activeElement;
     r.focus=ae?(ae.id||ae.tagName):'';r.area=!!(A&&ae===A);r.hasFocus=d.hasFocus();
     var bar=d.querySelector('.toolbar.folded');r.fold=bar?(bar.classList.contains('expanded')?'open':'closed'):'none';
     r.menu=[].slice.call(d.querySelectorAll('.dropdown-menu')).filter(function(m){return w.getComputedStyle(m).display!=='none'&&m.getBoundingClientRect().height>4;}).length;
     var ems=w.__xrEditMenuStats;r.emk=ems?ems.kept:-1;r.emm=ems?ems.multi:-1;
     r.btn={};['bold','select-all'].forEach(function(k){var e=[].slice.call(d.querySelectorAll('[id="id-toolbar-btn-'+k+'"]')).filter(function(x){var q=x.getBoundingClientRect();return x.offsetParent&&q.width>4&&q.height>4;})[0],b=e&&e.getBoundingClientRect();
      if(!b)return;if(k==='bold'){r.bact=e.classList.contains('active');var h=d.elementFromPoint(b.left+b.width/2,b.top+b.height/2),hb=h&&h.closest&&h.closest('[id]');r.bhit=hb?hb.id:'';r.bhitc=h?(h.tagName+'.'+String(h.className||'').slice(0,60)+(hb&&hb!==h?' in '+hb.tagName+'.'+String(hb.className||'').slice(0,60):'')):'';r.bn=d.querySelectorAll('[id="id-toolbar-btn-bold"]').length;}var z=1;for(var x=e;x&&x!==d.documentElement;x=x.parentElement)z*=parseFloat(w.getComputedStyle(x).zoom)||1;
      r.btn[k]=[Math.round(o.left+(b.left+b.width/2)*z),Math.round(o.top+(b.top+b.height/2)*z)];});
     if(A&&!w.__xrLat){var L=w.__xrLat=[],pend=false;var on=function(){if(pend)return;pend=true;var t0=w.performance.now();
      w.requestAnimationFrame(function(){w.requestAnimationFrame(function(){L.push(w.performance.now()-t0);pend=false;});});};
      A.addEventListener('keydown',on,true);A.addEventListener('input',on,true);}
     if(w.__xrLat&&w.__xrLat.length){var s=w.__xrLat.slice().sort(function(x,y){return x-y;});
      r.lat={n:s.length,med:Math.round(s[Math.floor(s.length/2)]),p95:Math.round(s[Math.min(s.length-1,Math.floor(s.length*0.95))])};}
     return JSON.stringify(r);})()
    """

    private func poll() {
        guard !probing, let web = controller.coordinator?.web else { return }
        // plan C1 gate: a keyboard switch the test asks for (<probe file>.kblang holds the language tag). The tag only
        // stands in for the keyboard's own language (the simulator's keyboard list cannot be changed from a test); the
        // switch itself is the system's UITextInputMode.currentInputModeDidChangeNotification, so an answer arrives
        // only through the observer the editor registered (none when the setting is off). A file, not a hook URL, so
        // the keyboard focus it depends on is not moved.
        if let f = ProcessInfo.processInfo.environment["XR_PROBE_FILE"],
           let tag = try? String(contentsOfFile: f + ".kblang", encoding: .utf8) {
            try? FileManager.default.removeItem(atPath: f + ".kblang")
            controller.coordinator?.testKeyboardLanguage = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            // the keyboard's own input mode as the object, as a real switch would carry one
            let mode = XRWebView.firstResponder(in: web)?.textInputMode
            NotificationCenter.default.post(name: UITextInputMode.currentInputModeDidChangeNotification, object: mode)
        }
        // the test pauses the probe while it types (<probe file>.pause): its full-document read on the main thread
        // would otherwise sit inside the keypress-latency samples it collects
        if let f = ProcessInfo.processInfo.environment["XR_PROBE_FILE"], FileManager.default.fileExists(atPath: f + ".pause") { return }
        probing = true
        // the probe's time is when its read STARTED: the test takes the first probe stamped after its action, and a
        // read already running when the action happened (one takes up to a second on a busy iPad) returns the page as
        // it was before it - stamped with its end time, CI run 138 read "nothing selected, no menu" right after a long
        // press whose word and native menu were already on screen (the gate's own screenshot, taken just after)
        let started = Int64(Date().timeIntervalSince1970 * 1000)
        web.evaluateJavaScript(Self.probeJS) { r, e in
            probing = false
            var o = ((r as? String)?.data(using: .utf8)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                ?? ["err": e?.localizedDescription ?? "no result"]
            o["fr"] = Self.holdsFirstResponder(web)
            o["kb"] = keyboardUp
            // the native edit menu (plan S5): presentations so far and the last action's answer
            o["em"] = controller.editMenuShown
            o["ema"] = controller.editMenuLast
            // plan C1: the paragraph direction at the caret (state channel) and the last keyboard switch's answer
            o["dir"] = controller.state.direction.rawValue
            o["kbd"] = controller.kbDirLast
            // ... and whether the editor registered its keyboard-switch observer (the setting decides, per language)
            o["kbobs"] = controller.coordinator?.inputModeObserver != nil
            let line = "t=\(started)|"
                + ((try? JSONSerialization.data(withJSONObject: o)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}")
            // the simulator shares the Mac's file system: a file the test reads costs no accessibility query (each one
            // walks the whole editor page and times out on the iPad); the label stays as the fallback
            if let f = ProcessInfo.processInfo.environment["XR_PROBE_FILE"],
               (try? Data(line.utf8).write(to: URL(fileURLWithPath: f), options: .atomic)) != nil {
                if probe != "file" { probe = "file" }
            } else {
                probe = line
            }
        }
    }

    /// The web view (its private content view, found by walking the public subview tree) is the first responder.
    private static func holdsFirstResponder(_ v: UIView) -> Bool {
        v.isFirstResponder || v.subviews.contains { holdsFirstResponder($0) }
    }
}

/// XR_REAL=1 (plan M4b): the REAL document path instead of the test editor - the app's DocumentOpener opens
/// Documents/<XR_NEW_NAME> as a UIDocument and presents the real EditorHost / EditorScreen over this screen (top bar,
/// title menu, ⋯ menu, save on close), exactly as from Home. Back closes it again; "reopen" opens the first Recent
/// entry by its bookmark, as Home's Recent row does. The test renames through the title menu, edits, saves and
/// reopens; check_saved.py then finds the content in the renamed file and no file left at the old name.
/// XR_REAL_IDLE=1 (plan S9): nothing opens at start; the buttons below do what Home's Browse files / Open a PDF /
/// New document do (the same opener calls), "list" shows the office files in Documents; a label refreshed every 0.5 s
/// (no tap needed, so it also reports while something swallows taps) says what the last picker was and what is
/// presented over the screen now, and what the last close decided for a new file (DocumentOpener.lastClosed).
/// Hooks (plan S9 review): xrero-autotest://pick?name=<file> makes the presented picker pick that file from Documents
/// (the delegate call a real pick makes); "newheld" is "new" plus another iPad / Mac window opening that new file as
/// soon as it is open here (a second UIDocument, counted as open by the opener, as that window's editor would be);
/// "release" closes it in that other window again.
/// A blank this harness creates is a NEW document (opened for editing, as Home's create tiles do); with XR_DOC_B64
/// the file is written from those bytes and opened as an EXISTING one (plan S2: read-first, as from Recent / Browse),
/// as is a file that is already there.
struct RealDocumentHarness: View {
    @StateObject private var opener = DocumentOpener()
    @ObservedObject private var recents = RecentFiles.shared
    @State private var state = "starting"
    @State private var files = "files:"
    @State private var listed = 0                   // "files#<n>:": the test sees that its tap refreshed the labels
    @State private var taps = [String: Int]()       // taps each button received (did a tap reach the app at all?)
    @State private var hit = "hit:none"             // xrero-autotest://hit?x=&y=: which window / view gets a touch there
    @State private var hook = "hook:none"           // what the pick / hold / release hooks did
    @State private var held: OfficeFile?            // the file "another window" holds open (hold / release)
    private let name = ProcessInfo.processInfo.environment["XR_NEW_NAME"] ?? "xr-real.docx"
    private let idle = ProcessInfo.processInfo.environment["XR_REAL_IDLE"] == "1"

    var body: some View {
        VStack(spacing: 12) {
            Text(state).accessibilityIdentifier("xr-state")
            Text(recents.items.first?.name ?? "none").accessibilityIdentifier("xr-real-recent")
            Button("reopen") { reopen() }.accessibilityIdentifier("xr-real-reopen")
            if idle {
                HStack(spacing: 16) {
                    Button("browse") { count("browse"); opener.browse() }.accessibilityIdentifier("xr-real-browse")
                    Button("pdf") { count("pdf"); opener.browse([.pdf]) }.accessibilityIdentifier("xr-real-pdf")
                    Button("new") { count("new"); opener.create(.word) }.accessibilityIdentifier("xr-real-new")
                    Button("list") { count("list"); list() }.accessibilityIdentifier("xr-real-list")
                    Button("newheld") {
                        count("newheld")
                        let before = recents.items.first?.id
                        opener.create(.word)
                        holdWhenOpen(after: before, n: 0)
                    }.accessibilityIdentifier("xr-real-newheld")
                    Button("release") { count("release"); release() }.accessibilityIdentifier("xr-real-release")
                }
                Text(files).font(.system(size: 9)).accessibilityIdentifier("xr-real-files")
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    VStack(spacing: 4) {
                        Text("picker:" + (opener.lastPicker.isEmpty ? "none" : opener.lastPicker) + " presented:" + opener.presentedNow)
                            .font(.system(size: 9)).accessibilityIdentifier("xr-real-picker")
                        Text("closed:" + (opener.lastClosed.isEmpty ? "none" : opener.lastClosed))
                            .font(.system(size: 9)).accessibilityIdentifier("xr-real-closed")
                    }
                }
                Text("taps:" + ["browse", "pdf", "new", "list", "newheld", "release"].map { "\($0)=\(taps[$0] ?? 0)" }.joined(separator: " "))
                    .font(.system(size: 9)).accessibilityIdentifier("xr-real-taps")
                Text(hit).font(.system(size: 9)).accessibilityIdentifier("xr-real-hit")
                Text(hook).font(.system(size: 9)).accessibilityIdentifier("xr-real-hook")
            }
        }
        // 0 x 0, as on Home: a full-size anchor view was hit-tested above the buttons after a form sheet (iPad)
        .background(PresenterAnchor(opener: opener).frame(width: 0, height: 0))
        .onAppear(perform: start)
        .onOpenURL { url in
            guard url.scheme == "xrero-autotest" else { return }
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func num(_ k: String) -> CGFloat { CGFloat(Double(q.first { $0.name == k }?.value ?? "") ?? 0) }
            switch url.host ?? "" {
            case "hit": hit = Self.hitReport(CGPoint(x: num("x"), y: num("y")))
            case "pick":
                let n = q.first { $0.name == "name" }?.value ?? name
                hook = opener.autotestPick(n) ? "hook:pick sent " + n : "hook:pick no picker"
            default: break
            }
        }
    }

    /// Waits (0.25 s steps, 10 s at most; a timer, so it runs under the full-screen editor too) until the new file is
    /// open here - it is then the newest Recent row - and holds it.
    private func holdWhenOpen(after before: String?, n: Int) {
        if let first = recents.items.first?.id, first != before { hold(); return }
        guard n < 40 else { hook = "hook:hold never opened"; return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { holdWhenOpen(after: before, n: n + 1) }
    }

    /// Another window opens the file open here: the newest Recent row - the open editor's file - by its bookmark, as
    /// Home's Recent row in that window would, as a second UIDocument counted by the opener.
    private func hold() {
        guard held == nil, let item = recents.items.first, let url = recents.resolve(item) else { hook = "hook:hold nothing"; return }
        let f = OfficeFile(fileURL: url)
        DocumentOpener.noteOpened(url)
        hook = "hook:hold opening " + url.lastPathComponent
        f.open { ok in
            if ok { held = f } else { DocumentOpener.noteClosed(url) }
            hook = (ok ? "hook:hold open " : "hook:hold failed ") + url.lastPathComponent
        }
    }

    /// That other window closes the file again.
    private func release() {
        guard let f = held else { hook = "hook:release nothing"; return }
        held = nil
        let url = f.fileURL
        f.close { _ in
            DocumentOpener.noteClosed(url)
            hook = "hook:released " + url.lastPathComponent
        }
    }

    private func count(_ b: String) { taps[b, default: 0] += 1 }

    /// "hit:<window class>@<level>[*key]=<hit view class> ..." for every visible window of the scene at a screen point:
    /// the top one that answers gets a touch there (CI, iPad: it found the full-size anchor view taking the taps).
    @MainActor static func hitReport(_ p: CGPoint) -> String {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return "hit:no scene" }
        let parts = scene.windows.sorted { $0.windowLevel.rawValue > $1.windowLevel.rawValue }.map { w -> String in
            let v = w.isHidden ? nil : w.hitTest(w.convert(p, from: nil), with: nil)
            let name = v.map { view in "\(type(of: view))" + (view.superview.map { sup in "<\(type(of: sup))" } ?? "") } ?? "nil"
            return "\(type(of: w))@\(Int(w.windowLevel.rawValue))\(w.isKeyWindow ? "*" : "")\(w.isHidden ? "h" : "")=\(name)"
        }
        return "hit:\(Int(p.x)),\(Int(p.y)) " + parts.joined(separator: " ")
    }

    private func start() {
        guard state == "starting" else { return }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if let incoming = ProcessInfo.processInfo.environment["XR_INCOMING"] { startIncoming(incoming, docs: docs); return }
        let url = docs.appendingPathComponent(name)
        let kind = OfficeKind(url: url) ?? .word
        var how = DocumentOpener.OpenAs.existing
        if !FileManager.default.fileExists(atPath: url.path) {
            if let b64 = ProcessInfo.processInfo.environment["XR_DOC_B64"], let d = Data(base64Encoded: b64) {
                try? d.write(to: url, options: .atomic)
            } else {
                try? OfficeDocument.blank(kind).write(to: url, options: .atomic)
                how = .edit
            }
        }
        if idle { state = "idle"; list(); return }       // the file is there for the picker to find
        state = "opened " + name
        opener.open(url, as: how)
    }

    /// Open-in test (plan S11, OpenInUITests): a file handed over by another app, through the app's own
    /// DocumentOpener.openExternal. XR_INCOMING_MODE=copy (default): the system's copy in the Inbox (Mail, WhatsApp,
    /// share sheet), Documents/Inbox or else tmp/<bundle>-Inbox; XR_INCOMING_CLASH=1 first puts a file of the same
    /// name in the app's folder (the copy must not replace it). XR_INCOMING_MODE=inplace: a file outside the app's
    /// folder (Library/Application Support/Outside, standing in for iCloud Drive / another app), opened in place.
    private func startIncoming(_ name: String, docs: URL) {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment
        let blank = OfficeDocument.blank(OfficeKind(url: URL(fileURLWithPath: name)) ?? .word)
        if env["XR_INCOMING_MODE"] == "inplace" {
            let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Outside", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: url.path) { try? blank.write(to: url, options: .atomic) }
            state = "incoming inplace " + name
            opener.openExternal(url)
            return
        }
        if env["XR_INCOMING_CLASH"] == "1" {
            let mine = docs.appendingPathComponent(name)
            if !fm.fileExists(atPath: mine.path) { try? blank.write(to: mine, options: .atomic) }
        }
        var url = docs.appendingPathComponent("Inbox", isDirectory: true).appendingPathComponent(name)
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try blank.write(to: url, options: .atomic)
        } catch {
            let dir = fm.temporaryDirectory.appendingPathComponent("com.xrero.office-Inbox", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            url = dir.appendingPathComponent(name)
            try? blank.write(to: url, options: .atomic)
        }
        state = "incoming copy " + url.deletingLastPathComponent().lastPathComponent
        opener.openExternal(url)
    }

    private func reopen() {
        guard let item = recents.items.first, let url = recents.resolve(item) else { state = "no recent"; return }
        state = "reopened " + url.lastPathComponent
        opener.open(url)
    }

    /// "files#<n>:a.docx|b.xlsx" (office files only, sorted).
    private func list() {
        listed += 1
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: docs.path)) ?? [])
            .filter { OfficeKind(url: URL(fileURLWithPath: $0)) != nil }.sorted()
        files = "files#\(listed):" + names.joined(separator: "|")
    }
}
#endif
