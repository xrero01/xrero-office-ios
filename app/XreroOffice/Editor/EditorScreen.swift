import SwiftUI

/// One open document: the Xrero editor full screen, with a back button to the documents.
struct EditorScreen: View {
    @Binding var document: OfficeDocument
    var fileURL: URL?
    /// Back to the documents (after the editor has saved). Without it the screen dismisses itself.
    var onClose: (() -> Void)? = nil
    @StateObject private var controller = EditorController()
    @State private var lang = AppLanguage.current
    @State private var share: ShareFile?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    private var title: String {
        fileURL?.lastPathComponent ?? ("Document." + document.kind.fileExtension)
    }

    var body: some View {
        EditorWebView(document: $document, title: title, lang: lang, onCommand: handle, controller: controller)
            .ignoresSafeArea(.container, edges: [.bottom])
            .navigationTitle((title as NSString).deletingPathExtension)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: close) { Image(systemName: "chevron.backward") }
                        .accessibilityLabel(L.documents)
                }
            }
            .sheet(item: $share) { ShareSheet(items: [$0.url]) }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { controller.save() }     // never lose typing when the app is left
            }
    }

    /// Save (only when something changed: the converter would otherwise rewrite a file that was just looked at),
    /// then back to the documents - after 10 s at the latest, so a stuck save never traps the user in the editor.
    private func close() {
        var finished = false
        let finish = {
            if finished { return }
            finished = true
            if let onClose { onClose() } else { dismiss() }
        }
        controller.save(onlyIfModified: true) { finish() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { finish() }
    }

    private func handle(_ cmd: String, _ param: String) {
        if cmd == "close" {
            close()
        } else if cmd == "xrero:share" {
            controller.save {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(title)
                try? document.data.write(to: url, options: .atomic)
                share = ShareFile(url: url)
            }
        } else if cmd.hasPrefix("xrero:lang:") {
            let new = String(cmd.dropFirst("xrero:lang:".count)) == "ar" ? "ar" : "en"
            guard new != lang else { return }
            AppLanguage.set(new)
            controller.save { lang = new }                       // reopen the editor in the other language
        }
    }
}

struct ShareFile: Identifiable { let url: URL; var id: URL { url } }

struct ShareSheet: UIViewControllerRepresentable {
    var items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
