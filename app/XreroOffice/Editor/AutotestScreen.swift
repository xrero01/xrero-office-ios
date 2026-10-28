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
            name = env["XR_NEW_NAME"] ?? ("xr-test." + kind.fileExtension)     // own file per test (clipboard test)
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
            if url.host == "selectall" {        // clipboard test: select the document's text (selection is not under test)
                let js = """
                (function(){var f=document.querySelector('iframe');var w=f&&f.contentWindow;var ed=w&&w.Asc&&w.Asc.editor;
                 if(!ed)return 'no editor';ed.asc_EditSelectAll();return 'ok';})()
                """
                controller.coordinator?.web?.evaluateJavaScript(js) { r, e in handle("log", "selectall: \(r ?? e?.localizedDescription ?? "?")") }
            }
            if url.host == "pbset",             // clipboard test: text "from another app" (written in-app: no Allow Paste prompt)
               let t = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "t" })?.value {
                UIPasteboard.general.string = t
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
