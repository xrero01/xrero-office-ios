import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The start screen of one window: the system document browser (Recents / Shared / Browse, like the Files app). Its
/// Create Document button asks for a new document, spreadsheet or presentation.
///
/// New documents are written straight into "On My iPhone > Xrero Office" and opened by their file URL. The browser's
/// own create-and-import path (and SwiftUI's DocumentGroup built on it) fails on the app's very first launch: the
/// system imports the new file, then cannot resolve the item it just imported ("Unable to Import Document",
/// DocumentManager error 1) - so a new user's first tap on Create Document showed an error.
struct BrowserScene: View {
    @StateObject private var coordinator = BrowserCoordinator()

    var body: some View {
        DocumentBrowser(coordinator: coordinator)
            .ignoresSafeArea()
            .onOpenURL { url in
                if url.isFileURL { coordinator.openExternal(url) }      // "Open in Xrero Office" from Files / Share
            }
    }
}

struct DocumentBrowser: UIViewControllerRepresentable {
    let coordinator: BrowserCoordinator

    func makeCoordinator() -> BrowserCoordinator { coordinator }

    func makeUIViewController(context: Context) -> UIDocumentBrowserViewController {
        let browser = UIDocumentBrowserViewController(forOpening: [.docx, .xlsx, .pptx])
        browser.allowsDocumentCreation = true
        browser.allowsPickingMultipleItems = false
        browser.delegate = context.coordinator
        browser.view.tintColor = UIColor(red: 0.12, green: 0.48, blue: 0.55, alpha: 1)
        context.coordinator.attach(browser)
        return browser
    }

    func updateUIViewController(_ browser: UIDocumentBrowserViewController, context: Context) {}
}

final class BrowserCoordinator: NSObject, ObservableObject, UIDocumentBrowserViewControllerDelegate {
    private weak var browser: UIDocumentBrowserViewController?
    private var pending: URL?                 // asked to open while the browser or another document was not ready
    private var editorOpen = false

    func attach(_ browser: UIDocumentBrowserViewController) {
        self.browser = browser
        if let url = pending { pending = nil; DispatchQueue.main.async { self.open(url) } }
    }

    // MARK: browser delegate

    /// The browser's "Create Document" (+): ask which kind, create it ourselves (see the type comment), import nothing.
    func documentBrowser(_ controller: UIDocumentBrowserViewController,
                         didRequestDocumentCreationWithHandler importHandler: @escaping (URL?, UIDocumentBrowserViewController.ImportMode) -> Void) {
        let sheet = UIAlertController(title: L.new, message: nil, preferredStyle: .actionSheet)
        for kind in OfficeKind.allCases {
            sheet.addAction(UIAlertAction(title: L.name(kind), style: .default) { [weak self] _ in
                importHandler(nil, .none)
                self?.createAndOpen(kind)
            })
        }
        sheet.addAction(UIAlertAction(title: L.cancel, style: .cancel) { _ in importHandler(nil, .none) })
        if let pop = sheet.popoverPresentationController {           // iPad / Mac: a centred popover
            pop.sourceView = controller.view
            pop.sourceRect = CGRect(x: controller.view.bounds.midX, y: controller.view.bounds.midY, width: 1, height: 1)
            pop.permittedArrowDirections = []
        }
        controller.present(sheet, animated: true)
    }

    func documentBrowser(_ controller: UIDocumentBrowserViewController, didPickDocumentsAt documentURLs: [URL]) {
        if let url = documentURLs.first { open(url) }
    }

    func documentBrowser(_ controller: UIDocumentBrowserViewController, didImportDocumentAt sourceURL: URL,
                         toDestinationURL destinationURL: URL) {
        open(destinationURL)
    }

    func documentBrowser(_ controller: UIDocumentBrowserViewController, failedToImportDocumentAt documentURL: URL, error: Error?) {
        alert(L.cannotOpen, error?.localizedDescription ?? documentURL.lastPathComponent)
    }

    // MARK: opening

    func createAndOpen(_ kind: OfficeKind) {
        do { open(try NewDocuments.create(kind)) }
        catch { alert(L.cannotCreate, error.localizedDescription) }
    }

    /// A document handed to the app by the system (Files "Open in", Share): show it in the browser, then open it.
    func openExternal(_ url: URL) {
        guard let browser else { pending = url; return }
        browser.revealDocument(at: url, importIfNeeded: true) { [weak self] revealed, _ in
            self?.open(revealed ?? url)
        }
    }

    func open(_ url: URL) {
        guard let browser, !editorOpen else { pending = url; return }
        guard OfficeKind(url: url) != nil else { alert(L.cannotOpen, url.lastPathComponent); return }
        editorOpen = true
        let scoped = url.startAccessingSecurityScopedResource()       // documents outside the app's own folder
        let file = OfficeFile(fileURL: url)
        file.open { [weak self] ok in
            guard let self else { return }
            guard ok, let model = OpenDocumentModel(file: file) else {
                if scoped { url.stopAccessingSecurityScopedResource() }
                self.editorOpen = false
                self.alert(L.cannotOpen, url.lastPathComponent)
                return
            }
            let host = UIHostingController(rootView: AnyView(EmptyView()))
            host.rootView = AnyView(EditorHost(model: model) { [weak self, weak host] in
                file.close { _ in
                    if scoped { url.stopAccessingSecurityScopedResource() }
                    host?.dismiss(animated: true) {
                        guard let self else { return }
                        self.editorOpen = false
                        if let next = self.pending { self.pending = nil; self.open(next) }
                    }
                }
            })
            host.modalPresentationStyle = .fullScreen
            browser.present(host, animated: true)
        }
    }

    private func alert(_ title: String, _ message: String) {
        guard let browser else { return }
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default))
        var top: UIViewController = browser
        while let p = top.presentedViewController { top = p }
        top.present(a, animated: true)
    }
}

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
    static var documents: String { ar ? "المستندات" : "Documents" }
    static var cannotOpen: String { ar ? "تعذّر فتح الملف" : "Couldn't open the file" }
    static var cannotCreate: String { ar ? "تعذّر إنشاء الملف" : "Couldn't create the file" }
    static func name(_ kind: OfficeKind) -> String {
        switch kind {
        case .word: return ar ? "مستند" : "Document"
        case .cell: return ar ? "جدول بيانات" : "Spreadsheet"
        case .slide: return ar ? "عرض تقديمي" : "Presentation"
        }
    }
}
