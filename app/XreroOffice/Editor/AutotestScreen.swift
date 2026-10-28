import SwiftUI

#if XR_AUTOTEST
/// CI only (build configuration "Autotest"). Opens one document straight in the editor so XCUITest can type into
/// it with the real keyboard path. Environment: XR_KIND=word|cell|slide, or XR_DOC_NAME + XR_DOC_B64 (a sample).
/// Writes Documents/<name> on every save and Documents/xr-log-<name>.txt (editor log) for the workflow.
struct AutotestScreen: View {
    @State private var document: OfficeDocument
    @State private var state = "loading"
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
        // the same Save As list as the real editor screen (the UI test taps a format in it)
        .saveAsCopy(formats: $saveAsFormats, lang: ProcessInfo.processInfo.environment["XR_LANG"] ?? AppLanguage.current,
                    controller: controller)
        // test-only trigger that needs no tapping: XCUIApplication.open(URL("xrero-autotest://save"))
        .onOpenURL { url in
            guard url.scheme == "xrero-autotest" else { return }
            if url.host == "save" { controller.save() }
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
        }
    }

    private func handle(_ cmd: String, _ param: String) {
        switch cmd {
        case "ready": state = "ready"
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
            if param.hasPrefix("open failed") || param.hasPrefix("engine error") { state = "error: " + param }
        default: break
        }
    }
}
#endif
