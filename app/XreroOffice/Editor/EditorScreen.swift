import SwiftUI

/// One open document: the Xrero editor full screen, with the system's back-to-Files navigation.
struct EditorScreen: View {
    @Binding var document: OfficeDocument
    var fileURL: URL?
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbarRole(.editor)
            .sheet(item: $share) { ShareSheet(items: [$0.url]) }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { controller.save() }     // never lose typing when the app is left
            }
    }

    private func handle(_ cmd: String, _ param: String) {
        if cmd == "close" {
            controller.save { dismiss() }
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
