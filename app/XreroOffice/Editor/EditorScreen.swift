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
    @State private var saveAsFormats: [String] = []
    @State private var showAccount = false
    @ObservedObject private var account = XreroAccount.shared
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
            .saveAsCopy(formats: $saveAsFormats, lang: lang, controller: controller)
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
            if let onClose { onClose() } else { dismiss() }
        }
        controller.save(onlyIfModified: true) { finish() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { finish() }
    }

    private func handle(_ cmd: String, _ param: String) {
        if cmd == "close" {
            close()
        } else if cmd == "xrero:account" || cmd == "xrero:signin" {
            showAccount = true
        } else if cmd == "xrero:signout" {
            account.signOut()
        } else if cmd == "saveas" {
            saveAsFormats = param.split(separator: ",").map(String.init)
        } else if cmd == "export" {
            // only the bridge's own Save As copies: a script in the page can send any ui command through
            // execCommand, so a path outside xr-export must never reach the share sheet
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xr-export", isDirectory: true)
            let url = URL(fileURLWithPath: param).standardizedFileURL
            guard url.deletingLastPathComponent().resolvingSymlinksInPath().path
                    == dir.resolvingSymlinksInPath().path else { return }
            share = ShareFile(url: url)    // the copy: Save to Files, AirDrop, Mail...
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

/// File > Save As: the formats the editor can really write, as a system list. The pick goes back to the editor,
/// which converts a copy (the original file stays as it is); closing the list without a pick cancels.
struct SaveAsCopy: ViewModifier {
    @Binding var formats: [String]
    var lang: String
    var controller: EditorController
    @State private var waiting = false

    func body(content: Content) -> some View {
        content
            .onChange(of: formats) { _, f in if !f.isEmpty { waiting = true } }
            .confirmationDialog(lang == "ar" ? "حفظ نسخة بصيغة" : "Save a copy as",
                                isPresented: Binding(get: { !formats.isEmpty }, set: { shown in
                                    guard !shown else { return }
                                    formats = []
                                    // after any button action of this same tap: only a dismissal without a pick cancels
                                    DispatchQueue.main.async {
                                        if waiting { waiting = false; controller.answerSaveAs("") }
                                    }
                                }),
                                titleVisibility: .visible) {
                ForEach(formats, id: \.self) { ext in
                    Button(SaveAsCopy.label(ext, lang)) {
                        waiting = false
                        formats = []
                        controller.answerSaveAs(ext)
                    }
                    .accessibilityIdentifier("xr-saveas-" + ext)
                }
                Button(lang == "ar" ? "إلغاء" : "Cancel", role: .cancel) {}
                    .accessibilityIdentifier("xr-saveas-cancel")
            } message: {
                Text(lang == "ar" ? "يبقى الملف الأصلي كما هو." : "The original file stays as it is.")
            }
    }

    /// Plain names (no product names), the extension always shown so the choice is unambiguous.
    static func label(_ ext: String, _ lang: String) -> String {
        let ar = lang == "ar"
        let name: String
        switch ext {
        case "docx": name = ar ? "مستند" : "Document"
        case "dotx": name = ar ? "قالب مستند" : "Document template"
        case "odt": name = ar ? "نص OpenDocument" : "OpenDocument text"
        case "ott": name = ar ? "قالب نص OpenDocument" : "OpenDocument text template"
        case "rtf": name = ar ? "نص منسّق" : "Rich text"
        case "xlsx": name = ar ? "جدول بيانات" : "Spreadsheet"
        case "xltx": name = ar ? "قالب جدول بيانات" : "Spreadsheet template"
        case "pptx": name = ar ? "عرض تقديمي" : "Presentation"
        case "potx": name = ar ? "قالب عرض تقديمي" : "Presentation template"
        case "ppsx": name = ar ? "عرض شرائح" : "Slide show"
        case "odp": name = ar ? "عرض OpenDocument" : "OpenDocument presentation"
        case "otp": name = ar ? "قالب عرض OpenDocument" : "OpenDocument presentation template"
        default: name = ext.uppercased()
        }
        return name + " (." + ext + ")"
    }
}

extension View {
    func saveAsCopy(formats: Binding<[String]>, lang: String, controller: EditorController) -> some View {
        modifier(SaveAsCopy(formats: formats, lang: lang, controller: controller))
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
