import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let docx = UTType("org.openxmlformats.wordprocessingml.document") ?? UTType(importedAs: "org.openxmlformats.wordprocessingml.document")
    static let xlsx = UTType("org.openxmlformats.spreadsheetml.sheet") ?? UTType(importedAs: "org.openxmlformats.spreadsheetml.sheet")
    static let pptx = UTType("org.openxmlformats.presentationml.presentation") ?? UTType(importedAs: "org.openxmlformats.presentationml.presentation")
}

/// The three editors and the file format each one saves.
enum OfficeKind: String, CaseIterable {
    case word, cell, slide

    var contentType: UTType {
        switch self {
        case .word: return .docx
        case .cell: return .xlsx
        case .slide: return .pptx
        }
    }
    var fileExtension: String {
        switch self {
        case .word: return "docx"
        case .cell: return "xlsx"
        case .slide: return "pptx"
        }
    }
    init?(contentType: UTType) {
        if contentType.conforms(to: .docx) { self = .word }
        else if contentType.conforms(to: .xlsx) { self = .cell }
        else if contentType.conforms(to: .pptx) { self = .slide }
        else { return nil }
    }
}

/// An Office file as bytes. Opening and saving the format itself happens in the editor (x2t WebAssembly);
/// the app only moves bytes between the Files app and the editor.
struct OfficeDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.docx, .xlsx, .pptx] }
    static var writableContentTypes: [UTType] { [.docx, .xlsx, .pptx] }

    var data: Data
    var kind: OfficeKind

    /// A new, empty document from the editors' own blank templates (Arabic templates for Arabic users).
    init(kind: OfficeKind = .word) {
        self.kind = kind
        self.data = OfficeDocument.blank(kind)
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
        self.kind = OfficeKind(contentType: configuration.contentType) ?? .word
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }

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

/// Interface language of the editors: the user's choice (EN/AR switch in the editor header), else the device's.
enum AppLanguage {
    static let key = "xr.lang"
    static var current: String {
        if let v = UserDefaults.standard.string(forKey: key), v == "ar" || v == "en" { return v }
        return (Locale.preferredLanguages.first ?? "en").hasPrefix("ar") ? "ar" : "en"
    }
    static func set(_ lang: String) { UserDefaults.standard.set(lang == "ar" ? "ar" : "en", forKey: key) }
}
