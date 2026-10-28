import SwiftUI

#if XR_AUTOTEST
/// CI only (build configuration "Autotest"). Opens one document straight in the editor so XCUITest can type into
/// it with the real keyboard path. Environment: XR_KIND=word|cell|slide, or XR_DOC_NAME + XR_DOC_B64 (a sample).
/// Writes Documents/<name> on every save and Documents/xr-log-<name>.txt (editor log) for the workflow.
struct AutotestScreen: View {
    @State private var document: OfficeDocument
    @State private var state = "loading"
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
            name = "xr-test." + kind.fileExtension
        }
        try? FileManager.default.removeItem(at: docs.appendingPathComponent("xr-log-" + name + ".txt"))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            EditorWebView(document: $document, title: name, lang: ProcessInfo.processInfo.environment["XR_LANG"] ?? AppLanguage.current,
                          onCommand: handle, controller: controller)
                .ignoresSafeArea(.container, edges: [.bottom])      // same as the real editor screen
            VStack(alignment: .leading, spacing: 2) {
                Text(state).font(.system(size: 6)).accessibilityIdentifier("xr-state")
                Button("save") { controller.save() }.font(.system(size: 6)).accessibilityIdentifier("xr-save")
            }
            .opacity(0.02)
        }
        // test-only trigger that needs no tapping: XCUIApplication.open(URL("xrero-autotest://save"))
        .onOpenURL { url in
            guard url.scheme == "xrero-autotest" else { return }
            if url.host == "save" { controller.save() }
            if url.host == "pdfedit" {          // PDF editing test: rotate page 1, add a page, add a free-text box
                let js = """
                (function(){var f=document.querySelector('iframe');var w=f&&f.contentWindow;var ed=w&&w.Asc&&w.Asc.editor;
                 if(!ed)return 'no editor';ed.asc_RotatePage(90,[0]);ed.asc_AddPage(1);
                 setTimeout(function(){try{ed.AddFreeTextAnnot(0);}catch(e){}},800);return 'ok';})()
                """
                controller.coordinator?.web?.evaluateJavaScript(js) { r, e in handle("log", "pdfedit: \(r ?? e?.localizedDescription ?? "?")") }
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
                var bc=d.querySelector('.toolbar .box-controls'),tb=d.querySelector('#toolbar');if(vis(bc)&&tb){var lim=Math.min(R(bc).b,R(tb).b)+1;
                 [].slice.call(bc.querySelectorAll('.panel.active .btn-toolbar, .panel.static .btn-toolbar, .panel.active .btn-toolbar .caption')).filter(vis).forEach(function(e){if(R(e).b>lim)bad.push('ribbon clipped '+(e.id||e.textContent.trim().slice(0,12))+' '+Math.round(R(e).b)+'>'+Math.round(lim));});}
                var rm=d.querySelector('#right-menu');var rmw=rm?Math.round(rm.getBoundingClientRect().width):0;if(w.innerWidth<w.innerHeight&&rmw>100)bad.push('right panel open in portrait '+rmw);
                var S=w.Common&&w.Common.Utils&&w.Common.Utils.InternalSettings;var info='w='+w.innerWidth+'x'+w.innerHeight+' items='+items.length+' rm='+rmw+(bc&&tb?' bc='+Math.round(R(bc).t)+'-'+Math.round(R(bc).b)+' tb='+Math.round(R(tb).t)+'-'+Math.round(R(tb).b):'')+(S?' ctrl='+S.get('toolbar-height-controls')+' normal='+S.get('toolbar-height-normal'):'');
                return bad.length?'geom:fail '+bad.slice(0,6).join('; ')+' ('+info+')':'geom:ok ('+info+')';})()
                """
                controller.coordinator?.web?.evaluateJavaScript(js) { r, e in
                    let res = (r as? String) ?? "geom:fail " + (e?.localizedDescription ?? "no result")
                    handle("log", res)
                    state = res
                }
            }
        }
    }

    private func handle(_ cmd: String, _ param: String) {
        switch cmd {
        case "ready": state = "ready"
        case "saved":
            try? document.data.write(to: docs.appendingPathComponent(name), options: .atomic)
            state = "saved:" + param
        case "log":
            let line = (param + "\n").data(using: .utf8)!
            let url = docs.appendingPathComponent("xr-log-" + name + ".txt")      // one log per test document
            if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line); try? h.close() }
            else { try? line.write(to: url) }
            if param.hasPrefix("open failed") || param.hasPrefix("engine error") { state = "error: " + param }
        default: break
        }
    }
}
#endif
