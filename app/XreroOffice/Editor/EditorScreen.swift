import SwiftUI

/// One open document: the Xrero editor full screen, with a back button to the documents.
struct EditorScreen: View {
    @Binding var document: OfficeDocument
    var fileURL: URL?
    /// The open file behind the title menu (Rename, Duplicate, Move…; plan M4b). nil: no title menu.
    var files: OpenDocumentModel? = nil
    /// Back to the documents (after the editor has saved). Without it the screen dismisses itself.
    var onClose: (() -> Void)? = nil
    /// Read-first opening (plan S2, ReadingView.swift): the mode DocumentOpener chose for this file. Not observed here:
    /// only the top bar, the PDF bar and the page capsule redraw on Edit / Done, never the whole screen.
    var reading: ReadingModel = .off
    @StateObject private var controller = EditorController()
    @StateObject private var barStatus = EditorBarStatus()      // the top bar's Opening / Saving / Edited / Saved line
    @State private var lang = AppLanguage.current
    @State private var share: ShareFile?
    @State private var saveAsFormats: [String] = []
    @State private var showAccount = false
    @State private var showAbout = false
    // @State, not @StateObject: the screen must NOT redraw when the model changes. A redraw rebuilds the top bar's
    // toolbar, and a ⋯ menu open at that moment stays on screen but dead - every tap ignored (CI: the Document info
    // sheet's 15 s count stop fired while the menu was open). Only the capsule and the sheet observe the model.
    @State private var menu = DocumentMenuModel()           // the ⋯ menu's Exporting capsule + Document info sheet
    @State private var recovered: RecoveryNotice?           // the editor was reopened after its web process ended
    @State private var tooLarge = false                     // ... twice within a minute: Share / Back instead
    @State private var toast: String?
    @State private var pendingLang: String?                 // asked for in the globe menu, waiting for the confirmation
    // the title menu (plan M4b)
    @State private var renaming = false                     // the Rename alert is up
    @State private var newName = ""                         // its text field
    @State private var fileAlert: String?                   // "Couldn't rename - a file with that name exists" ...
    @State private var moveFile: ShareFile?                 // the Move… picker, for the file as it is now
    @State private var afterSaveOp: (() -> Void)?           // a rename / move waiting for the save being written
    @ObservedObject private var account = XreroAccount.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var title: String {
        fileURL?.lastPathComponent ?? ("Document." + document.kind.fileExtension)
    }

    var body: some View {
        EditorWebView(document: $document, title: title, lang: lang, onCommand: handle, controller: controller,
                      reading: reading)
            .ignoresSafeArea(.container, edges: [.bottom])
            // presentations (plan S4): the phone's native slide strip with '+', and native Present
            .slidesChrome(enabled: document.kind == .slide, controller: controller, ar: lang == "ar")
            // plan S7: PDF only (hidden while reading, plan S2)
            .pdfToolBar(kind: document.kind, controller: controller, ar: lang == "ar", reading: reading)
            // plan S2: the floating page capsule and Go to Page while reading
            .readingChrome(reading, state: controller.state, controller: controller, ar: lang == "ar")
            .editorRecovery(notice: $recovered, tooLarge: tooLarge, ar: lang == "ar", share: shareDocument, back: leave)
            // spreadsheets (plan S3): the selection's Sum capsule and its Sum / Average / Min / Max / Count sheet
            .sheetSum(kind: document.kind, state: controller.state, controller: controller, ar: lang == "ar")
            // one native bar (plan M4a): Back, name + Edited / Saved, Undo (+ Redo when wide), the ⋯ document menu
            // (plan M7b: Find, Redo, Save | Share, Export, Document info | Language, Account, About, All tools)
            .editorTopBar(title: (title as NSString).deletingPathExtension, state: controller.state, status: barStatus,
                          controller: controller, ar: lang == "ar", back: close, save: { controller.userSave() },
                          find: { controller.find() },
                          menuKey: "\(lang)|\(account.isSignedIn)|\(document.kind.rawValue)",
                          titleMenu: files == nil ? nil : TitleMenuActions(rename: startRename, duplicate: duplicate,
                                                                           move: startMove),
                          format: document.kind == .word,
                          // plan S2: Edit / Done (Word, PDF)
                          reading: reading,
                          toggleReading: { reading.toggle(controller, file: fileURL, reduceMotion: reduceMotion) }) {
                DocumentMenuItems(kind: document.kind, lang: lang, signedIn: account.isSignedIn, model: menu,
                                  controller: controller,
                                  language: { if $0 != lang { pendingLang = $0 } },
                                  share: { handle("xrero:share", "") },
                                  account: { showAccount = true },
                                  about: { showAbout = true })
            }
            .documentMenuChrome(model: menu, kind: document.kind, name: title, size: document.data.count,
                                fileURL: fileURL, ar: lang == "ar")
            // Aa (top bar, keyboard bar): the format sheet / iPad popover (plan S1)
            .formatSheet(controller, ar: lang == "ar")
            .overlay(alignment: .bottom) {
                // short failure notice (paste): a capsule above the editor's bottom bar, gone after 2 s
                if let toast {
                    Text(toast)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 18)
                        .frame(height: 36)
                        .background(.regularMaterial, in: Capsule())   // solid under Reduce Transparency
                        .padding(.bottom, 72)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("xr-toast")
                }
            }
            .animation(.easeInOut(duration: 0.2), value: toast)
            .saveAsCopy(formats: $saveAsFormats, lang: lang, controller: controller)
            // the editor's page has to reopen in the other language, which clears its undo history: say so first, in
            // the language being switched to (Home and this bar flip at once; the page follows after its save)
            .confirmationDialog(pendingLang == "ar" ? "التبديل إلى العربية؟" : "Switch to English?",
                                isPresented: Binding(get: { pendingLang != nil }, set: { if !$0 { pendingLang = nil } }),
                                titleVisibility: .visible) {
                Button(pendingLang == "ar" ? "حفظ والتبديل" : "Save and Switch") {
                    if let new = pendingLang { handle("xrero:lang:" + new, "") }
                    pendingLang = nil
                }
                .accessibilityIdentifier("xr-lang-confirm")
                Button(pendingLang == "ar" ? "إلغاء" : "Cancel", role: .cancel) { pendingLang = nil }
            } message: {
                Text(pendingLang == "ar"
                     ? "يُحفظ المستند ثم يُعاد فتحه بالعربية. لن يكون التراجع عن التعديلات السابقة متاحًا بعدها."
                     : "The document is saved, then reopens in English. Earlier changes can't be undone after that.")
            }
            .titleMenuChrome(renaming: $renaming, newName: $newName, alert: $fileAlert, moveFile: $moveFile,
                             ar: lang == "ar", rename: commitRename, moved: moved)
            .sheet(item: $share) { ShareSheet(items: [$0.url]) }
            .sheet(isPresented: $showAccount) { AccountView() }
            .sheet(isPresented: $showAbout) { AboutSheet() }
            .onChange(of: account.info) { _, _ in controller.syncAccount(account.webValue) }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { controller.save() }     // never lose typing when the app is left
            }
    }

    /// Save (only when something changed: the converter would otherwise rewrite a file that was just looked at),
    /// then back to the documents - after 10 s at the latest, so a stuck save never traps the user in the editor.
    private func close() {
        reading.remember(fileURL)           // plan S2: the file reopens in the mode it is left in
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
        barStatus.note(cmd, param)
        menu.note(cmd, param)
        if !barStatus.saving, let op = afterSaveOp {         // the save it waited for has ended: rename / move now
            afterSaveOp = nil
            DispatchQueue.main.async { op() }                // not inside this message's handling
        }
        if cmd == "close" {
            close()
        } else if cmd == "recovered" {          // the last saved version is back on screen after the web process ended
            recovered = RecoveryNotice(edited: param == "edited")
        } else if cmd == "too-large" {          // it ended again within a minute: no reload loop, offer Share and Back
            recovered = nil
            tooLarge = true
        } else if cmd == "ready" {
            tooLarge = false                    // the editor came back after all (e.g. reopened in the other language)
            reading.apply(controller)           // plan S2: the page (also a reloaded one) takes the current mode
        } else if cmd == "xrero:account" || cmd == "xrero:signin" {
            showAccount = true
        } else if cmd == "paste-failed" {
            showToast(L.cannotPaste)
        } else if cmd == "export-failed" {
            showToast(lang == "ar" ? "تعذّر التصدير" : "Couldn't export")
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
            controller.save { shareDocument() }
        } else if cmd.hasPrefix("xrero:lang:") {
            let new = String(cmd.dropFirst("xrero:lang:".count)) == "ar" ? "ar" : "en"
            guard new != lang else { return }
            AppLanguage.set(new)
            controller.save { barStatus.reopening(); lang = new }  // reopen the editor in the other language
        }
    }
}

// MARK: the title menu (plan M4b): Rename, Duplicate, Move… - the file is moved under the open editor, which is never
// reloaded (undo and the caret stay); every later save lands in the file at its new place.
extension EditorScreen {
    private var baseName: String { (title as NSString).deletingPathExtension }
    private var fileExt: String { (title as NSString).pathExtension }

    /// Runs `op` now, or - while a save is being written (x2t converting, the file about to be replaced) - as soon as
    /// that save ended, so the file is never moved from under a write that is still on its way to the old place.
    private func afterSave(_ op: @escaping () -> Void) {
        if barStatus.saving {
            NSLog("XR title menu: waiting for the save in progress")
            afterSaveOp = op
        } else { op() }
    }

    fileprivate func startRename() {
        newName = baseName
        renaming = true
    }

    /// The Rename alert's button: the cleaned name (no folder separators, no extension typed by hand, no leading dot).
    fileprivate func commitRename() {
        guard let files else { return }
        let name = TitleMenuChrome.clean(newName, ext: fileExt)
        guard !name.isEmpty, name != baseName else { return }
        afterSave {
            files.rename(to: name) { err in
                switch err {
                case nil: tellEditor(files.fileURL)
                case .exists?: fileAlert = BarText.renameExists(lang == "ar")
                case .failed?: fileAlert = BarText.renameFailed(lang == "ar")
                }
            }
        }
    }

    /// Duplicate: what is on screen is saved first, then copied beside the file (the editor stays on the original).
    fileprivate func duplicate() {
        guard let files else { return }
        let ar = lang == "ar"
        let base = BarText.copyName(baseName, ar)
        // the save may never answer (the converter stuck): say the copy failed rather than nothing at all
        final class Once { var done = false }
        let once = Once()
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) {
            if !once.done { once.done = true; showToast(BarText.copyFailed(ar), seconds: 4) }
        }
        controller.save(onlyIfModified: true) {
            guard !once.done else { return }
            once.done = true
            files.duplicate(as: base) { url in
                // 4 s, not the paste notice's 2: it names the new file, which takes longer to read
                showToast(url.map { BarText.copySaved($0.deletingPathExtension().lastPathComponent, ar) } ?? BarText.copyFailed(ar),
                          seconds: 4)
            }
        }
    }

    /// Move…: the file as it is now goes to the system picker, which moves it (not a copy).
    fileprivate func startMove() {
        guard let files else { return }
        afterSave { files.flush { moveFile = ShareFile(url: files.fileURL) } }
    }

    fileprivate func moved(_ url: URL) {
        guard let files else { return }
        files.didMove(to: url)
        tellEditor(url)
    }

    /// The editor page learns the file's new name through the bridge (F0): its save log and the names of later Save As /
    /// Export copies follow. Data safety does not depend on it - the file itself is written by the app.
    private func tellEditor(_ url: URL) {
        let arg = String(data: (try? JSONSerialization.data(withJSONObject: [url.lastPathComponent])) ?? Data("[\"\"]".utf8),
                         encoding: .utf8) ?? "[\"\"]"
        controller.call("return window.__xrRename ? __xrRename(\(arg)[0]) : 'no rename';") { r, e in
            NSLog("XR rename in the editor: %@", (r as? String) ?? e ?? "?")
        }
    }

    fileprivate func showToast(_ text: String, seconds: Double = 2) {
        toast = text
        UIAccessibility.post(notification: .announcement, argument: text)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { if toast == text { toast = nil } }
    }
}

/// The title menu's sheets (plan M4b): the Rename alert with its text field, the error alert and the Move… picker.
struct TitleMenuChrome: ViewModifier {
    @Binding var renaming: Bool
    @Binding var newName: String
    @Binding var alert: String?
    @Binding var moveFile: ShareFile?
    var ar: Bool
    var rename: () -> Void
    var moved: (URL) -> Void

    func body(content: Content) -> some View {
        content
            .alert(BarText.renameTitle(ar), isPresented: $renaming) {
                TextField(BarText.name(ar), text: $newName)
                    .accessibilityIdentifier("xr-rename-field")
                Button(BarText.rename(ar), action: rename)
                    .accessibilityIdentifier("xr-rename-ok")
                Button(BarText.cancel(ar), role: .cancel) {}
                    .accessibilityIdentifier("xr-rename-cancel")
            }
            .alert(alert ?? "", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
                Button(BarText.ok(ar)) {}
                    .accessibilityIdentifier("xr-file-alert-ok")
            }
            .sheet(item: $moveFile) { f in
                MoveDocumentPicker(url: f.url) { url in
                    moveFile = nil
                    if let url { moved(url) }
                }
                .ignoresSafeArea()
            }
    }

    /// A file name from what was typed: trimmed, without "/" or ":" (folder separators), without the extension when it
    /// was typed as well, without leading dots (a hidden file), at most 200 characters.
    static func clean(_ typed: String, ext: String) -> String {
        var s = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        s = String(String.UnicodeScalarView(s.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && $0 != "/" && $0 != ":"
        }))
        if !ext.isEmpty && s.lowercased().hasSuffix("." + ext.lowercased()) { s = String(s.dropLast(ext.count + 1)) }
        while s.hasPrefix(".") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespaces)
        // the file system's limit is 255 BYTES per name, extension included: an Arabic letter takes 2 bytes, so a
        // character count would let a long Arabic name fail with the generic "couldn't rename"
        let room = 250 - (ext.isEmpty ? 0 : ext.utf8.count + 1)
        while s.utf8.count > room { s.removeLast() }
        return s.trimmingCharacters(in: .whitespaces)
    }
}

extension View {
    func titleMenuChrome(renaming: Binding<Bool>, newName: Binding<String>, alert: Binding<String?>,
                         moveFile: Binding<ShareFile?>, ar: Bool, rename: @escaping () -> Void,
                         moved: @escaping (URL) -> Void) -> some View {
        modifier(TitleMenuChrome(renaming: renaming, newName: newName, alert: alert, moveFile: moveFile, ar: ar,
                                 rename: rename, moved: moved))
    }
}

/// Move…: the system's folder picker, which MOVES the file there (asCopy: false). `done` gets the file's new place,
/// nil when cancelled.
struct MoveDocumentPicker: UIViewControllerRepresentable {
    var url: URL
    var done: (URL?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(done) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let p = UIDocumentPickerViewController(forExporting: [url], asCopy: false)
        p.delegate = context.coordinator
        p.shouldShowFileExtensions = true
        return p
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let done: (URL?) -> Void
        init(_ done: @escaping (URL?) -> Void) { self.done = done }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { done(urls.first) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { done(nil) }
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
