import SwiftUI

/// The editor's ⋯ document menu (plan M7b): a familiar iOS list of "get this file somewhere" actions in place of the
/// desktop's File backstage. The top bar (EditorTopBar) draws section 1 - Find, Redo on iPhone, Save; this view adds
///   2. Share…, Export ▸ (one entry per format the on-device converter writes correctly), Document info;
///   3. Language ▸, Account, About & Licences, All tools (the editor's File backstage, for what has no native
///      equivalent yet: protection, properties, page setup...).
/// Mirrored with the screen it sits in. Every entry reaches the editor through EditorController (the F0 bridge).
///
/// PDF and Print are left out on purpose: in the PDF spike (CI, `xrero-autotest://pdfspike`) route (a), this
/// WebAssembly converter writing the PDF, fails (x2t exit code 80); route (b), the editor's print-renderer output turned
/// into a PDF, is a follow-up (plan.json M7b "deferred"). They are offered only once an exported Arabic PDF passes a
/// copy-text check there.
struct DocumentMenuItems: View {
    var kind: OfficeKind
    var lang: String
    var signedIn: Bool
    var model: DocumentMenuModel
    var controller: EditorController
    /// Asked for in Language ▸ (the screen confirms first: the editor page reopens).
    var language: (String) -> Void
    var share: () -> Void
    var account: () -> Void
    var about: () -> Void

    private var ar: Bool { lang == "ar" }

    var body: some View {
        Section {
            Button(action: share) { Label(ar ? "مشاركة…" : "Share…", systemImage: "square.and.arrow.up") }
                .accessibilityIdentifier("xr-nav-share")
            let formats = DocumentMenuModel.exportFormats(kind)
            if !formats.isEmpty {
                Menu {
                    ForEach(formats, id: \.self) { ext in
                        Button(SaveAsCopy.label(ext, lang)) { model.export(ext, controller) }
                            .disabled(model.exporting != nil)     // one export at a time: the capsule is for that one
                            .accessibilityIdentifier("xr-export-" + ext)
                    }
                } label: { Label(ar ? "تصدير" : "Export", systemImage: "square.and.arrow.up.on.square") }
                    .accessibilityIdentifier("xr-menu-export")
            }
            Button { model.showInfo(controller) } label: {
                Label(ar ? "معلومات المستند" : "Document Info", systemImage: "doc.text.magnifyingglass")
            }
                .accessibilityIdentifier("xr-menu-info")
        }
        Section {
            Menu {
                Button { language("en") } label: { Label("English", systemImage: lang == "en" ? "checkmark" : "") }
                    .accessibilityIdentifier("xr-nav-lang-en")
                Button { language("ar") } label: { Label("العربية", systemImage: lang == "ar" ? "checkmark" : "") }
                    .accessibilityIdentifier("xr-nav-lang-ar")
            } label: { Label(ar ? "اللغة" : "Language", systemImage: "globe") }
                .accessibilityIdentifier("xr-nav-lang")
            Button(action: account) {
                Label(signedIn ? (ar ? "الحساب" : "Account") : (ar ? "تسجيل الدخول" : "Sign in"),
                      systemImage: signedIn ? "person.crop.circle.fill" : "person.crop.circle")
            }
                .accessibilityIdentifier("xr-nav-account")
            Button(action: about) { Label(ar ? "حول التطبيق والتراخيص" : "About & Licences", systemImage: "info.circle") }
                .accessibilityIdentifier("xr-menu-about")
            Button { controller.allTools() } label: {
                Label(ar ? "كل الأدوات" : "All Tools", systemImage: "slider.horizontal.3")
            }
                .accessibilityIdentifier("xr-menu-alltools")
        }
    }
}

/// What the ⋯ menu shows around the editor: the "Exporting…" capsule while an export runs and the Document info
/// sheet. Fed by the editor's commands (note), which the screen passes on - O(1), they arrive while typing too.
final class DocumentMenuModel: ObservableObject {
    /// The format being exported (nil when none): the capsule under the bar.
    @Published private(set) var exporting: String?
    @Published var infoShown = false
    /// The editor's counts for the info sheet (pages, words, chars, charsSpaces, paragraphs / slides / sheets).
    @Published private(set) var counts: [String: Int] = [:]
    @Published private(set) var counting = false

    /// Export ▸ entries: only formats the on-device converter writes correctly (a subset of SAVE_AS in xr-host.js,
    /// each one exported and opened again in CI). Templates stay in Save As; spreadsheets get no .ods (its writer
    /// drops header cells), PDFs are saved in place, and PDF output waits for the spike (see DocumentMenuItems).
    static func exportFormats(_ kind: OfficeKind) -> [String] {
        switch kind {
        case .word: return ["docx", "odt", "rtf"]
        case .cell: return ["xlsx"]
        case .slide: return ["pptx", "odp"]
        case .pdf: return []
        }
    }

    func note(_ cmd: String, _ param: String) {
        switch cmd {
        case "exporting": if exporting != param { exporting = param }
        case "export", "export-failed": if exporting != nil { exporting = nil }
        case "docinfo":
            guard counting else { break }          // only the answer to an opening still counting
            var c: [String: Int] = [:]
            if let d = param.data(using: .utf8), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
                for (k, v) in o { if let n = (v as? NSNumber)?.intValue, n >= 0 { c[k] = n } }
            }
            counts = c
            counting = false
        default: break
        }
    }

    /// Export ▸ <format>: the copy is converted in the editor and comes back as an 'export' message (share sheet).
    /// The entries are disabled while one runs (the capsule and its end message belong to that one).
    func export(_ ext: String, _ controller: EditorController) {
        guard exporting == nil else { return }
        exporting = ext
        controller.export(ext) { [weak self] r in if r != "ok" { self?.exporting = nil } }
    }

    /// Document info: the sheet opens at once with what the app knows; the editor's counts follow. Each opening has
    /// its own number, so a late answer or the 15 s stop of an earlier opening never ends this one's count.
    private var infoRequest = 0
    func showInfo(_ controller: EditorController) {
        infoRequest += 1
        let mine = infoRequest
        counts = [:]
        counting = true
        infoShown = true
        controller.docInfo { [weak self] r in if r != "ok", self?.infoRequest == mine { self?.counting = false } }
        // a count that never ends (a very large document) must not spin for ever
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            if self?.infoRequest == mine { self?.counting = false }
        }
    }
}

extension View {
    /// The ⋯ menu's capsule and info sheet on an editor screen.
    func documentMenuChrome(model: DocumentMenuModel, kind: OfficeKind, name: String, size: Int, fileURL: URL?,
                            ar: Bool) -> some View {
        modifier(DocumentMenuChrome(model: model, kind: kind, name: name, size: size, fileURL: fileURL, ar: ar))
    }
}

private struct DocumentMenuChrome: ViewModifier {
    @ObservedObject var model: DocumentMenuModel
    var kind: OfficeKind
    var name: String
    var size: Int
    var fileURL: URL?
    var ar: Bool

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if model.exporting != nil {
                    Text(ar ? "جارٍ التصدير…" : "Exporting…")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 18)
                        .frame(height: 36)
                        .background(.regularMaterial, in: Capsule())   // solid under Reduce Transparency
                        .padding(.top, 8)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("xr-exporting")
                }
            }
            .animation(.easeInOut(duration: 0.2), value: model.exporting)
            .sheet(isPresented: $model.infoShown) {
                DocumentInfoSheet(model: model, kind: kind, name: name, size: size, fileURL: fileURL, ar: ar)
            }
    }
}

/// Document info as a native sheet: name, type, size, location and modified date from the file; pages, words and
/// characters (Word), slides or sheets from the editor. Digits stay Western in both languages (never mirrored).
struct DocumentInfoSheet: View {
    @ObservedObject var model: DocumentMenuModel
    var kind: OfficeKind
    var name: String
    var size: Int
    var fileURL: URL?
    var ar: Bool
    @Environment(\.dismiss) private var dismiss

    private var number: IntegerFormatStyle<Int> { IntegerFormatStyle<Int>(locale: Locale(identifier: ar ? "ar-u-nu-latn" : "en")) }

    private var kindName: String {
        switch kind {
        case .word: return ar ? "مستند" : "Document"
        case .cell: return ar ? "جدول بيانات" : "Spreadsheet"
        case .slide: return ar ? "عرض تقديمي" : "Presentation"
        case .pdf: return "PDF"
        }
    }

    private var location: String {
        guard let dir = fileURL?.deletingLastPathComponent() else { return ar ? "غير محفوظ بعد" : "Not saved yet" }
        return FileManager.default.displayName(atPath: dir.path)
    }

    private var modified: Date? {
        (try? fileURL?.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// The editor's counts, in reading order, with their labels.
    private struct Row: Identifiable { let id: String; let en: String; let ar: String }
    private var rows: [Row] {
        let all = [
            Row(id: "pages", en: "Pages", ar: "الصفحات"), Row(id: "words", en: "Words", ar: "الكلمات"),
            Row(id: "chars", en: "Characters (no spaces)", ar: "الأحرف (دون مسافات)"),
            Row(id: "charsSpaces", en: "Characters (with spaces)", ar: "الأحرف (مع المسافات)"),
            Row(id: "paragraphs", en: "Paragraphs", ar: "الفقرات"), Row(id: "slides", en: "Slides", ar: "الشرائح"),
            Row(id: "sheets", en: "Sheets", ar: "الأوراق")
        ]
        return all.filter { model.counts[$0.id] != nil }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent(ar ? "الاسم" : "Name", value: name)
                        .accessibilityIdentifier("xr-docinfo-name")
                    LabeledContent(ar ? "النوع" : "Type", value: kindName)
                    LabeledContent(ar ? "الحجم (آخر حفظ)" : "Size (last saved)",
                                   value: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                        .accessibilityIdentifier("xr-docinfo-size")
                    LabeledContent(ar ? "الموقع" : "Location", value: location)
                        .accessibilityIdentifier("xr-docinfo-location")
                    if let modified {
                        LabeledContent(ar ? "آخر تعديل" : "Modified",
                                       value: modified.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened)
                                                                    .locale(Locale(identifier: ar ? "ar-u-nu-latn" : "en"))))
                    }
                }
                Section {
                    if model.counting {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(ar ? "جارٍ العد…" : "Counting…").foregroundStyle(.secondary)
                        }
                        .accessibilityIdentifier("xr-docinfo-counting")
                    } else if rows.isEmpty {
                        Text(ar ? "لا تتوفر أعداد لهذا المستند." : "No counts for this document.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(rows) { r in
                        LabeledContent(ar ? r.ar : r.en, value: (model.counts[r.id] ?? 0).formatted(number))
                            .accessibilityIdentifier("xr-docinfo-" + r.id)
                    }
                }
            }
            .navigationTitle(ar ? "معلومات المستند" : "Document Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(ar ? "تم" : "Done") { dismiss() }
                        .accessibilityIdentifier("xr-docinfo-done")
                }
            }
        }
        .environment(\.layoutDirection, ar ? .rightToLeft : .leftToRight)
        .presentationDetents([.medium, .large])
    }
}
