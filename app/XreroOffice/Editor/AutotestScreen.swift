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
            if n.hasSuffix(".xlsx") { d.kind = .cell } else if n.hasSuffix(".pptx") { d.kind = .slide } else { d.kind = .word }
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
            if url.scheme == "xrero-autotest" && url.host == "save" { controller.save() }
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
