import SwiftUI
import UIKit

/// One open document file: bytes in, bytes out (the format itself is handled by the editor, x2t WebAssembly).
final class OfficeFile: UIDocument {
    var data = Data()

    override func contents(forType typeName: String) throws -> Any { data }

    override func load(fromContents contents: Any, ofType typeName: String?) throws {
        if let d = contents as? Data { data = d }
        else if let w = contents as? FileWrapper, let d = w.regularFileContents { data = d }
        else { throw CocoaError(.fileReadCorruptFile) }
    }
}

/// The editor's view of an open file: every save from the editor is written to disk right away.
final class OpenDocumentModel: ObservableObject {
    let file: OfficeFile
    @Published var document: OfficeDocument {
        didSet {
            guard document.data != oldValue.data else { return }
            file.data = document.data
            file.updateChangeCount(.done)
            file.autosave(completionHandler: nil)
        }
    }

    init?(file: OfficeFile) {
        guard let kind = OfficeKind(url: file.fileURL) else { return nil }
        self.file = file
        self.document = OfficeDocument(data: file.data, kind: kind)
    }
}

/// The editor screen presented over the browser, with a back button to the documents.
struct EditorHost: View {
    @ObservedObject var model: OpenDocumentModel
    var onClose: () -> Void

    var body: some View {
        NavigationStack {
            EditorScreen(document: $model.document, fileURL: model.file.fileURL, onClose: onClose)
        }
    }
}

/// New documents from the editors' blank templates, in the app's own folder ("On My iPhone > Xrero Office").
enum NewDocuments {
    static func create(_ kind: OfficeKind) throws -> URL {
        let fm = FileManager.default
        let folder = try fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let base = L.name(kind)
        var url = folder.appendingPathComponent(base + "." + kind.fileExtension)
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(n).\(kind.fileExtension)")
            n += 1
        }
        let data = OfficeDocument.blank(kind)
        guard !data.isEmpty else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url, options: .atomic)
        return url
    }
}

/// Start-screen words in the interface language (EN/AR).
enum L {
    static var ar: Bool { AppLanguage.current == "ar" }
    static var new: String { ar ? "جديد" : "New" }
    static var cancel: String { ar ? "إلغاء" : "Cancel" }
    static var ok: String { ar ? "حسناً" : "OK" }
    static var documents: String { ar ? "المستندات" : "Documents" }
    static var cannotOpen: String { ar ? "تعذّر فتح الملف" : "Couldn't open the file" }
    static var cannotCreate: String { ar ? "تعذّر إنشاء الملف" : "Couldn't create the file" }
    static var noConnection: String { ar ? "لا يوجد اتصال بالإنترنت" : "No internet connection" }
    static var accountDisabled: String { ar ? "هذا الحساب موقوف" : "This account is disabled" }
    static func name(_ kind: OfficeKind) -> String {
        switch kind {
        case .word: return ar ? "مستند" : "Document"
        case .cell: return ar ? "جدول بيانات" : "Spreadsheet"
        case .slide: return ar ? "عرض تقديمي" : "Presentation"
        case .pdf: return "PDF"
        }
    }
}
