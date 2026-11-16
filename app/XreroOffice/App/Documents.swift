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
            touched = true
            file.data = document.data
            file.updateChangeCount(.done)
            file.autosave(completionHandler: nil)
        }
    }

    /// Where the file is now (the title menu's Rename / Move change it). Published so the editor's title, its ⋯ >
    /// Document info and the Share copy follow at once; the editor page itself is never reloaded for it.
    @Published private(set) var fileURL: URL
    /// Where the saves go, set by DocumentOpener before the editor shows (plan S11: the imported-copy notice).
    var origin: DocumentOrigin = .own
    /// A place picked in Move… outside the app's own folder: held open while the document is (later saves go there).
    private var scopedURL: URL?
    /// Something happened to the file beyond being looked at: the engine reported an edit (noteEdited), the editor
    /// wrote into it, or it was renamed, moved or duplicated. A new file the app made in this session is removed on
    /// close only while this is false (plan S9, DocumentOpener.closed). Sticky: an edit undone still counts.
    /// A plain value, not published: it is set while typing (the first edit) and nothing on screen shows it.
    private(set) var touched = false

    /// The engine's "document modified" mark went on (EditorScreen: the "modified" 1 message, once per change of the
    /// mark - O(1), it can arrive while typing).
    func noteEdited() { touched = true }

    init?(file: OfficeFile) {
        guard let kind = OfficeKind(url: file.fileURL) else { return nil }
        self.file = file
        self.fileURL = file.fileURL
        self.document = OfficeDocument(data: file.data, kind: kind)
    }

    deinit { scopedURL?.stopAccessingSecurityScopedResource() }

    // MARK: the title menu (plan M4b): Rename, Duplicate, Move. Data-loss class, so every step is coordinated:
    //  - pending changes are written to the CURRENT file first (flush), so nothing is left for the old place;
    //  - the move itself is an NSFileCoordinator move off the main thread (Apple: never coordinate on the main thread);
    //    the open UIDocument is a file presenter, so it is told (presentedItemDidMove) and writes every later save -
    //    the editor's next Save, the autosave, the save on close - to the new place. No ghost file at the old name;
    //  - the Recent entry is replaced by one for the new place (a fresh bookmark), so Home reopens the renamed file.
    // The screen queues these behind a save that is being written (EditorScreen.afterSave).

    enum FileOpError: Error { case exists, failed }

    /// Writes changes UIDocument still holds to the file as it is now, then `then` (on the main thread).
    func flush(then: @escaping () -> Void) {
        guard file.hasUnsavedChanges else { then(); return }
        file.save(to: file.fileURL, for: .forOverwriting) { _ in DispatchQueue.main.async { then() } }
    }

    /// Renames the open file in its folder; `base` is the new name without the extension (the extension never changes:
    /// it is the format the editor saves). `done(nil)` once the file is at its new place.
    func rename(to base: String, done: @escaping (FileOpError?) -> Void) {
        let old = file.fileURL
        let ext = old.pathExtension
        let dest = old.deletingLastPathComponent().appendingPathComponent(base + (ext.isEmpty ? "" : "." + ext))
        guard dest.standardizedFileURL.path != old.standardizedFileURL.path else { done(nil); return }
        // only the letter case changes: on a case-insensitive volume the "existing" file is this one
        let caseOnly = dest.path.lowercased() == old.path.lowercased()
        if !caseOnly && FileManager.default.fileExists(atPath: dest.path) { done(.exists); return }
        flush {
            DispatchQueue.global(qos: .userInitiated).async {
                let c = NSFileCoordinator(filePresenter: nil)
                var cerr: NSError?
                var failure: FileOpError?
                c.coordinate(writingItemAt: old, options: .forMoving, writingItemAt: dest, options: .forReplacing,
                             error: &cerr) { from, to in
                    if !caseOnly && FileManager.default.fileExists(atPath: to.path) { failure = .exists; return }
                    do {
                        c.item(at: from, willMoveTo: to)
                        try FileManager.default.moveItem(at: from, to: to)
                        c.item(at: from, didMoveTo: to)
                    } catch {
                        NSLog("XR rename failed: %@", error.localizedDescription)
                        failure = .failed
                    }
                }
                if cerr != nil && failure == nil { failure = .failed }
                DispatchQueue.main.async {
                    if let failure { done(failure); return }
                    self.adopt(dest, from: old)
                    done(nil)
                }
            }
        }
    }

    /// Move…: the system picker moved the file to `url` (UIDocumentPickerViewController, not a copy).
    func didMove(to url: URL) {
        let old = file.fileURL
        if url.startAccessingSecurityScopedResource() {
            scopedURL?.stopAccessingSecurityScopedResource()
            scopedURL = url
        }
        adopt(url, from: old)
    }

    /// The open document now lives at `url`: the UIDocument writes there (the coordinator normally told it already; a
    /// move made by the system picker may not, so it is told here as well - the same URL twice is harmless), the
    /// screen shows the new name and Recent points at it.
    private func adopt(_ url: URL, from old: URL) {
        touched = true
        let f = file
        if f.fileURL.standardizedFileURL != url.standardizedFileURL {
            f.presentedItemOperationQueue.addOperation { f.presentedItemDidMove(to: url) }
        }
        fileURL = url
        RecentFiles.shared.replace(old, with: url)
        NSLog("XR document now at %@", url.lastPathComponent)
    }

    /// Duplicate: a copy of the document as last saved (`document.data`: the screen saves what is on screen first)
    /// beside it - in the app's own folder when that folder cannot be written. Listed in Recent right after the open
    /// file. `done` gets the copy's URL, nil when it could not be written.
    func duplicate(as base: String, done: @escaping (URL?) -> Void) {
        touched = true
        let src = file.fileURL
        let ext = src.pathExtension
        let fm = FileManager.default
        var folder = src.deletingLastPathComponent()
        if !fm.isWritableFile(atPath: folder.path),
           let docs = try? fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
            folder = docs
        }
        var dest = folder.appendingPathComponent(base + "." + ext)
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            dest = folder.appendingPathComponent("\(base) \(n).\(ext)")
            n += 1
        }
        let bytes = document.data
        let target = dest
        DispatchQueue.global(qos: .userInitiated).async {
            var cerr: NSError?
            var ok = false
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: target, options: .forReplacing, error: &cerr) { url in
                ok = (try? bytes.write(to: url, options: .atomic)) != nil
            }
            DispatchQueue.main.async {
                if ok && cerr == nil {
                    RecentFiles.shared.add(target, behindFirst: true)
                    done(target)
                } else { done(nil) }
            }
        }
    }
}

/// The editor screen presented over the browser, with a back button to the documents. It lives in its own
/// UIHostingController (DocumentOpener), so the language environment is applied here again: the editor's bar, its
/// menus and alerts mirror with Home.
struct EditorHost: View {
    @ObservedObject var model: OpenDocumentModel
    /// Reading or editing when it opens (plan S2): chosen by DocumentOpener.
    var reading: ReadingModel = .off
    var onClose: () -> Void

    var body: some View {
        NavigationStack {
            EditorScreen(document: $model.document, fileURL: model.fileURL, files: model, onClose: onClose,
                         reading: reading)
        }
        .appLanguageEnvironment()
    }
}

/// New documents from the editors' blank templates, in the app's own folder ("On My iPhone > Xrero Office").
enum NewDocuments {
    static func create(_ kind: OfficeKind) throws -> URL {
        let data = OfficeDocument.blank(kind)
        guard !data.isEmpty else { throw CocoaError(.fileWriteUnknown) }
        let url = try freeURL(L.name(kind), kind.fileExtension)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// A new file from a gallery template (plan S8): a copy of the bundled file in the chosen language, named after
    /// the template in that language ("Tax invoice" / "فاتورة ضريبية", then "... 2", "... 3").
    static func create(from template: TemplateManifest.Template, lang: String) throws -> URL {
        let data = try Data(contentsOf: template.url(lang))
        guard !data.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        let url = try freeURL(template.name.text(lang), template.officeKind.fileExtension)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// "<base>.<ext>" in the app's Documents folder, or "<base> 2.<ext>", "<base> 3.<ext>"... when it is taken.
    private static func freeURL(_ base: String, _ ext: String) throws -> URL {
        let fm = FileManager.default
        let folder = try fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        var url = folder.appendingPathComponent(base + "." + ext)
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(n).\(ext)")
            n += 1
        }
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
    static var cannotPaste: String { ar ? "تعذّر اللصق" : "Couldn't paste" }
    // the editor's native edit menu (plan S5; Bold / Italic as on the keyboard bar)
    static var cut: String { ar ? "قص" : "Cut" }
    static var copy: String { ar ? "نسخ" : "Copy" }
    static var paste: String { ar ? "لصق" : "Paste" }
    static var selectAll: String { ar ? "تحديد الكل" : "Select All" }
    static var bold: String { ar ? "غامق" : "Bold" }
    static var italic: String { ar ? "مائل" : "Italic" }
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
