import SwiftUI

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
            name = env["XR_DOC_NAME"] ?? ("xr-test." + kind.fileExtension)
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
            }
            .opacity(0.02)
        }
        // test-only trigger that needs no tapping: XCUIApplication.open(URL("xrero-autotest://save"))
        .onOpenURL { url in
            guard url.scheme == "xrero-autotest" else { return }
            if url.host == "save" { controller.save() }
            if url.host == "about" { showAbout = true }      // About & Licences over the open editor
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
            if url.host == "pdfedit" {          // PDF editing test: rotate page 1, add a page, add a free-text box
                let js = """
                (function(){var f=document.querySelector('iframe');var w=f&&f.contentWindow;var ed=w&&w.Asc&&w.Asc.editor;
                 if(!ed)return 'no editor';ed.asc_RotatePage(90,[0]);ed.asc_AddPage(1);
                 setTimeout(function(){try{ed.AddFreeTextAnnot(0);}catch(e){}},800);return 'ok';})()
                """
                controller.coordinator?.web?.evaluateJavaScript(js) { r, e in handle("log", "pdfedit: \(r ?? e?.localizedDescription ?? "?")") }
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
        case "log":
            let line = (param + "\n").data(using: .utf8)!
            let url = docs.appendingPathComponent("xr-log-" + name + ".txt")      // one log per test document
            if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line); try? h.close() }
            else { try? line.write(to: url) }
            if param.hasPrefix("web process ended") { ended += 1 }
            if param.hasPrefix("open failed") || param.hasPrefix("engine error") { state = "error: " + param }
        default: break
        }
    }
}
#endif
