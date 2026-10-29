import SwiftUI
import Combine

#if XR_AUTOTEST
/// CI only (build configuration "Autotest"). Opens one document straight in the editor so XCUITest can type into
/// it with the real keyboard path. Environment: XR_KIND=word|cell|slide, or XR_DOC_NAME + XR_DOC_B64 (a sample);
/// XR_DOC_NAME alone names a new blank document (its own log file). Writes Documents/<name> on every save and
/// Documents/xr-log-<name>.txt (editor log) for the workflow.
struct AutotestScreen: View {
    @State private var document: OfficeDocument
    @State private var state = "loading"
    @State private var showAbout = false
    @State private var recovery = "none"                    // sticky: "recovered:edited" / "recovered:" / "too-large"
    @State private var recovered: RecoveryNotice?
    @State private var tooLarge = false
    @State private var modified = "0"                      // the engine's "document modified" mark (crash test)
    @State private var ended = 0                            // "web process ended" log lines seen (the delegate fired)
    @State private var clipCount = 0
    @State private var saveAsFormats: [String] = []
    @StateObject private var controller = EditorController()
    private let name: String
    private let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    init() {
        let env = ProcessInfo.processInfo.environment
        if let b64 = env["XR_DOC_B64"], let data = Data(base64Encoded: b64), let n = env["XR_DOC_NAME"] {
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
        ZStack(alignment: .topLeading) {
            EditorWebView(document: $document, title: name, lang: ProcessInfo.processInfo.environment["XR_LANG"] ?? AppLanguage.current,
                          onCommand: handle, controller: controller)
                .ignoresSafeArea(.container, edges: [.bottom])      // same as the real editor screen
                .editorRecovery(notice: $recovered, tooLarge: tooLarge, ar: (ProcessInfo.processInfo.environment["XR_LANG"] ?? AppLanguage.current) == "ar",
                                hold: Double(ProcessInfo.processInfo.environment["XR_RECOVERY_HOLD"] ?? "") ?? 3,
                                share: { state = "share" }, back: { state = "back" })
            VStack(alignment: .leading, spacing: 2) {
                Text(state).font(.system(size: 6)).accessibilityIdentifier("xr-state")
                Text(recovery).font(.system(size: 6)).accessibilityIdentifier("xr-recovery")
                Text("modified:" + modified).font(.system(size: 6)).accessibilityIdentifier("xr-modified")
                Button("save") { controller.save() }.font(.system(size: 6)).accessibilityIdentifier("xr-save")
                // touch gate (XR_PROBE=1 only): the editor's caret / selection / zoom / focus, read by the test from a
                // label instead of a hook URL - a URL could itself change who holds the keyboard
                if ProcessInfo.processInfo.environment["XR_PROBE"] == "1" { ProbeLabel(controller: controller) }
            }
            .opacity(0.02)
        }
        // the same Save As list as the real editor screen (the UI test taps a format in it)
        .saveAsCopy(formats: $saveAsFormats, lang: ProcessInfo.processInfo.environment["XR_LANG"] ?? AppLanguage.current,
                    controller: controller)
        // test-only trigger that needs no tapping: XCUIApplication.open(URL("xrero-autotest://save"))
        .onOpenURL { url in
            guard url.scheme == "xrero-autotest" else { return }
            if url.host == "save" { controller.save() }
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
            if url.host == "note",              // touch gate: the test's results into the editor log (check_saved.py)
               let t = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "t" })?.value {
                for line in t.split(separator: "\n") { handle("log", String(line)) }
            }
            if url.host == "reopen" {           // typing gate: open the document again from what the last save wrote
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
                 if(t&&(!p||p.style.display==='none'))t.click();
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
            if url.host == "saveas" {           // the call File > Save As makes (fallback when the tap cannot reach it)
                let js = """
                (function(){var f=document.querySelector('iframe');var w=f&&f.contentWindow;var a=w&&(w.Asc&&w.Asc.editor||w.editor);
                 if(!a)return 'no editor';a.asc_DownloadAs();return 'ok';})()
                """
                controller.coordinator?.web?.evaluateJavaScript(js) { r, e in handle("log", "saveas: \(r ?? e?.localizedDescription ?? "?")") }
            }
            if url.host == "pdfedit" {          // PDF editing test: rotate page 1, add a page, add a free-text box
                let js = """
                (function(){var f=document.querySelector('iframe');var w=f&&f.contentWindow;var ed=w&&w.Asc&&w.Asc.editor;
                 if(!ed)return 'no editor';ed.asc_RotatePage(90,[0]);ed.asc_AddPage(1);
                 setTimeout(function(){try{ed.AddFreeTextAnnot(0);}catch(e){}},800);return 'ok';})()
                """
                controller.coordinator?.web?.evaluateJavaScript(js) { r, e in handle("log", "pdfedit: \(r ?? e?.localizedDescription ?? "?")") }
            }
            if url.host == "selectall" {        // clipboard test: select the document's text (selection is not under test)
                let js = """
                (function(){var f=document.querySelector('iframe');var w=f&&f.contentWindow;var ed=w&&w.Asc&&w.Asc.editor;
                 if(!ed)return 'no editor';ed.asc_EditSelectAll();return 'ok';})()
                """
                controller.coordinator?.web?.evaluateJavaScript(js) { r, e in handle("log", "selectall: \(r ?? e?.localizedDescription ?? "?")") }
            }
            if url.host == "addtext",           // clipboard test: the text to copy, without the keyboard (typing has its own tests)
               let t = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "t" })?.value {
                let arg = String(data: (try? JSONSerialization.data(withJSONObject: [t])) ?? Data("[\"\"]".utf8), encoding: .utf8) ?? "[\"\"]"
                let js = """
                (function(){var f=document.querySelector('iframe');var w=f&&f.contentWindow;var ed=w&&w.Asc&&w.Asc.editor;
                 if(!ed)return 'no editor';ed.asc_AddText(\(arg)[0]);return 'ok';})()
                """
                controller.coordinator?.web?.evaluateJavaScript(js) { r, e in handle("log", "addtext: \(r ?? e?.localizedDescription ?? "?")") }
            }
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
    }

    private func handle(_ cmd: String, _ param: String) {
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
        case "saveas": saveAsFormats = param.split(separator: ",").map(String.init)
        case "export":                       // Save As copy -> Documents/<name> for the workflow to check
            let src = URL(fileURLWithPath: param), dst = docs.appendingPathComponent(src.lastPathComponent)
            try? FileManager.default.removeItem(at: dst)
            try? FileManager.default.copyItem(at: src, to: dst)
            state = "exported:" + src.lastPathComponent
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

    /// Touch gate probe (Word): the caret's place on screen (web view points), the selected text, the document text,
    /// bold at the caret, the engine zoom, the visual viewport scale (1 = WebKit is not magnifying a bitmap), who has
    /// focus in the editor frame, whether the phone ribbon is folded, plus keypress-to-frame latency samples taken by
    /// listeners on the editor's input field (simulator figures: informational only). Native side: does the web view
    /// hold first responder (the keyboard), and is a software keyboard shown.
    private static let probeJS = """
    (function(){var f=document.querySelector('iframe');var w=f&&f.contentWindow;var d=w&&w.document;var a=w&&w.Asc&&w.Asc.editor;
     if(!a||!d||!a.WordControl)return JSON.stringify({err:'no editor'});
     var r={},o=f.getBoundingClientRect(),c=d.getElementById('id_target_cursor');
     if(c){var sd=c.style.display,sv=c.style.visibility;c.style.display='block';c.style.visibility='visible';var b=c.getBoundingClientRect();
      c.style.display=sd;c.style.visibility=sv;r.caretShown=(sd!=='none'||sv==='visible');
      if(b.height>=4){r.cx=Math.round(o.left+b.left);r.cy=Math.round(o.top+b.top+b.height/2);r.ch=Math.round(b.height);}}
     var ld=a.WordControl.m_oLogicDocument;
     if(ld){try{r.sel=(ld.IsSelectionUse()&&!ld.IsSelectionEmpty())?(ld.GetSelectedText(false)||''):'';}catch(e){r.sel='';r.selErr=String(e);}
      try{r.text=ld.Content.map(function(p){return p.GetText?p.GetText({ParaSeparator:''}):'';}).join('|');r.paras=ld.Content.length;}catch(e){r.text='';}
      try{r.bold=!!ld.GetCalculatedTextPr().Bold;}catch(e){}}
     r.zoom=a.WordControl.m_nZoomValue;
     r.vv=window.visualViewport?Math.round(window.visualViewport.scale*100)/100:1;r.vvi=w.visualViewport?Math.round(w.visualViewport.scale*100)/100:1;
     var ic=w.AscCommon&&w.AscCommon.g_inputContext,A=ic&&ic.HtmlArea,ae=d.activeElement;
     r.focus=ae?(ae.id||ae.tagName):'';r.area=!!(A&&ae===A);r.hasFocus=d.hasFocus();
     var bar=d.querySelector('.toolbar.folded');r.fold=bar?(bar.classList.contains('expanded')?'open':'closed'):'none';
     r.menu=[].slice.call(d.querySelectorAll('.dropdown-menu')).filter(function(m){return w.getComputedStyle(m).display!=='none'&&m.getBoundingClientRect().height>4;}).length;
     r.btn={};['bold','select-all'].forEach(function(k){var e=[].slice.call(d.querySelectorAll('[id="id-toolbar-btn-'+k+'"]')).filter(function(x){var q=x.getBoundingClientRect();return x.offsetParent&&q.width>4&&q.height>4;})[0],b=e&&e.getBoundingClientRect();
      if(b)r.btn[k]=[Math.round(o.left+b.left+b.width/2),Math.round(o.top+b.top+b.height/2)];});
     if(A&&!w.__xrLat){var L=w.__xrLat=[],pend=false;var on=function(){if(pend)return;pend=true;var t0=w.performance.now();
      w.requestAnimationFrame(function(){w.requestAnimationFrame(function(){L.push(w.performance.now()-t0);pend=false;});});};
      A.addEventListener('keydown',on,true);A.addEventListener('input',on,true);}
     if(w.__xrLat&&w.__xrLat.length){var s=w.__xrLat.slice().sort(function(x,y){return x-y;});
      r.lat={n:s.length,med:Math.round(s[Math.floor(s.length/2)]),p95:Math.round(s[Math.min(s.length-1,Math.floor(s.length*0.95))])};}
     return JSON.stringify(r);})()
    """

    private func poll() {
        guard !probing, let web = controller.coordinator?.web else { return }
        probing = true
        web.evaluateJavaScript(Self.probeJS) { r, e in
            probing = false
            var o = ((r as? String)?.data(using: .utf8)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                ?? ["err": e?.localizedDescription ?? "no result"]
            o["fr"] = Self.holdsFirstResponder(web)
            o["kb"] = keyboardUp
            let json = (try? JSONSerialization.data(withJSONObject: o)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            probe = "t=\(Int64(Date().timeIntervalSince1970 * 1000))|" + json
        }
    }

    /// The web view (its private content view, found by walking the public subview tree) is the first responder.
    private static func holdsFirstResponder(_ v: UIView) -> Bool {
        v.isFirstResponder || v.subviews.contains { holdsFirstResponder($0) }
    }
}
#endif
