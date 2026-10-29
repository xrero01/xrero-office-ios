import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let docx = UTType("org.openxmlformats.wordprocessingml.document") ?? UTType(importedAs: "org.openxmlformats.wordprocessingml.document")
    static let xlsx = UTType("org.openxmlformats.spreadsheetml.sheet") ?? UTType(importedAs: "org.openxmlformats.spreadsheetml.sheet")
    static let pptx = UTType("org.openxmlformats.presentationml.presentation") ?? UTType(importedAs: "org.openxmlformats.presentationml.presentation")
}

/// The editors and the file format each one saves (PDF: opened, edited and saved as PDF by the PDF editor).
enum OfficeKind: String, CaseIterable {
    case word, cell, slide, pdf

    /// what "Create Document" offers (a new PDF is made by exporting a document, not from a blank template)
    static let creatable: [OfficeKind] = [.word, .cell, .slide]

    var contentType: UTType {
        switch self {
        case .word: return .docx
        case .cell: return .xlsx
        case .slide: return .pptx
        case .pdf: return .pdf
        }
    }
    var fileExtension: String {
        switch self {
        case .word: return "docx"
        case .cell: return "xlsx"
        case .slide: return "pptx"
        case .pdf: return "pdf"
        }
    }
    init?(contentType: UTType) {
        if contentType.conforms(to: .docx) { self = .word }
        else if contentType.conforms(to: .xlsx) { self = .cell }
        else if contentType.conforms(to: .pptx) { self = .slide }
        else if contentType.conforms(to: .pdf) { self = .pdf }
        else { return nil }
    }
    init?(url: URL) {
        switch url.pathExtension.lowercased() {
        case "docx": self = .word
        case "xlsx": self = .cell
        case "pptx": self = .slide
        case "pdf": self = .pdf
        default: return nil
        }
    }
}

/// An Office file as bytes. Opening and saving the format itself happens in the editor (x2t WebAssembly);
/// the app only moves bytes between the Files app and the editor.
struct OfficeDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.docx, .xlsx, .pptx, .pdf] }
    static var writableContentTypes: [UTType] { [.docx, .xlsx, .pptx, .pdf] }

    var data: Data
    var kind: OfficeKind

    /// A new, empty document from the editors' own blank templates (Arabic templates for Arabic users).
    init(kind: OfficeKind = .word) {
        self.kind = kind
        self.data = OfficeDocument.blank(kind)
    }

    init(data: Data, kind: OfficeKind) {
        self.data = data
        self.kind = kind
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
        self.kind = OfficeKind(contentType: configuration.contentType) ?? .word
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }

    /// web/templates/ar holds Xrero's own right-to-left blanks (scripts/make_blank_templates.py: bidi paragraphs,
    /// Cairo, ar-AE; right-to-left sheet; right-aligned slide placeholders), so Arabic starts on the right at once.
    static func blank(_ kind: OfficeKind) -> Data {
        let lang = AppLanguage.current == "ar" ? "ar" : "en"
        let root = Bundle.main.resourceURL!.appendingPathComponent("web/templates")
        for folder in [lang, "en"] {
            if let d = try? Data(contentsOf: root.appendingPathComponent(folder).appendingPathComponent("new." + kind.fileExtension)) {
                return d
            }
        }
        return Data()
    }
}

/// The interface language (EN/AR): ONE observable source for Home, the sheets and the separately hosted editor.
///
/// Decision (plan M9b): the in-app switch (Home > More > Language, the editor's globe menu) is the source of truth.
/// Until the user picks one, the app follows iOS - and that already includes the per-app language from Settings >
/// Xrero Office > Language (CFBundleLocalizations en + ar), which iOS reports as Locale.preferredLanguages.first. The
/// bundle keeps both localisations because iOS itself shows the Arabic permission prompts from ar.lproj.
///
/// Reading it is cheap (a stored property): L.* and the editor read it on every render.
final class AppLanguage: ObservableObject {
    static let shared = AppLanguage()
    static let key = "xr.lang"

    /// "ar" or "en". Published so every view that observes `shared` re-renders when it changes.
    @Published private(set) var code: String

    private init() { code = AppLanguage.stored() }

    static var current: String { shared.code }

    /// Saves the choice and flips every observing screen at once (call on the main thread: UI actions only).
    static func set(_ lang: String) {
        let v = lang == "ar" ? "ar" : "en"
        UserDefaults.standard.set(v, forKey: key)
        if Thread.isMainThread { shared.code = v } else { DispatchQueue.main.async { shared.code = v } }
    }

    var isArabic: Bool { code == "ar" }
    var layoutDirection: LayoutDirection { isArabic ? .rightToLeft : .leftToRight }
    /// Dates and numbers follow the UAE variants of each language (plan M9b).
    var locale: Locale { Locale(identifier: isArabic ? "ar-AE" : "en-AE") }

    /// The UserDefaults value (UI tests pass "-xr.lang ar" in the launch arguments: argument domain, this launch only),
    /// else the iOS language for this app.
    private static func stored() -> String {
        if let v = UserDefaults.standard.string(forKey: key), v == "ar" || v == "en" { return v }
        return (Locale.preferredLanguages.first ?? "en").hasPrefix("ar") ? "ar" : "en"
    }
}

/// Mirrors a screen as one piece and gives it the app's locale for dates and numbers. Applied at the WindowGroup AND at
/// the editor's own UIHostingController root (EditorHost), which does not inherit the window's SwiftUI environment.
struct AppLanguageEnvironment: ViewModifier {
    @ObservedObject private var language = AppLanguage.shared
    func body(content: Content) -> some View {
        content
            .environment(\.layoutDirection, language.layoutDirection)
            .environment(\.locale, language.locale)
    }
}

extension View {
    func appLanguageEnvironment() -> some View { modifier(AppLanguageEnvironment()) }
}
