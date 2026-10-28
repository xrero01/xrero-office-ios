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
    @State private var showAccount = false
    @State private var recovered: RecoveryNotice?           // the editor was reopened after its web process ended
    @State private var tooLarge = false                     // ... twice within a minute: Share / Back instead
    @ObservedObject private var account = XreroAccount.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    private var title: String {
        fileURL?.lastPathComponent ?? ("Document." + document.kind.fileExtension)
    }

    var body: some View {
        EditorWebView(document: $document, title: title, lang: lang, onCommand: handle, controller: controller)
            .ignoresSafeArea(.container, edges: [.bottom])
            .editorRecovery(notice: $recovered, tooLarge: tooLarge, ar: lang == "ar", share: shareDocument, back: leave)
            .navigationTitle((title as NSString).deletingPathExtension)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: close) { Image(systemName: "chevron.backward") }
                        .accessibilityLabel(L.documents)
                }
                // language, share and account live in the system bar (full-size touch targets); the editors' own
                // header buttons for them are hidden on iOS so the ribbon tabs get the whole width
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Button { handle("xrero:lang:en", "") } label: {
                            Label("English", systemImage: lang == "en" ? "checkmark" : "")
                        }
                        Button { handle("xrero:lang:ar", "") } label: {
                            Label("العربية", systemImage: lang == "ar" ? "checkmark" : "")
                        }
                    } label: { Image(systemName: "globe") }
                        .accessibilityLabel(lang == "ar" ? "اللغة" : "Language")
                        .accessibilityIdentifier("xr-nav-lang")
                    Button { handle("xrero:share", "") } label: { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel(lang == "ar" ? "مشاركة" : "Share")
                        .accessibilityIdentifier("xr-nav-share")
                    Button { showAccount = true } label: {
                        Image(systemName: account.isSignedIn ? "person.crop.circle.fill" : "person.crop.circle")
                    }
                        .accessibilityLabel(account.isSignedIn ? (lang == "ar" ? "الحساب" : "Account")
                                                               : (lang == "ar" ? "تسجيل الدخول" : "Sign in"))
                        .accessibilityIdentifier("xr-nav-account")
                }
            }
            .sheet(item: $share) { ShareSheet(items: [$0.url]) }
            .sheet(isPresented: $showAccount) { AccountView() }
            .onChange(of: account.info) { _, _ in controller.syncAccount(account.webValue) }
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
            leave()
        }
        controller.save(onlyIfModified: true) { finish() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { finish() }
    }

    /// Back to the documents without saving (also the way out when the editor cannot be reopened).
    private func leave() {
        if let onClose { onClose() } else { dismiss() }
    }

    /// The document as last saved, handed to the share sheet as a file.
    private func shareDocument() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(title)
        try? document.data.write(to: url, options: .atomic)
        share = ShareFile(url: url)
    }

    private func handle(_ cmd: String, _ param: String) {
        if cmd == "close" {
            close()
        } else if cmd == "recovered" {          // the last saved version is back on screen after the web process ended
            recovered = RecoveryNotice(edited: param == "edited")
        } else if cmd == "too-large" {          // it ended again within a minute: no reload loop, offer Share and Back
            recovered = nil
            tooLarge = true
        } else if cmd == "ready" {
            tooLarge = false                    // the editor came back after all (e.g. reopened in the other language)
        } else if cmd == "xrero:account" || cmd == "xrero:signin" {
            showAccount = true
        } else if cmd == "xrero:signout" {
            account.signOut()
        } else if cmd == "xrero:share" {
            controller.save { shareDocument() }
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
