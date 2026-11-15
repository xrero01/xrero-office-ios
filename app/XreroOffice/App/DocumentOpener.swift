import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Opens documents over the home screen: new ones (written straight into "On My iPhone > Xrero Office"), files picked
/// in the system document picker, files handed over by Files / Share ("Open in Xrero Office") and recent files.
///
/// New documents are created by the app itself and opened by their file URL. The document browser's own
/// create-and-import path failed on the app's very first launch (the system imports the new file, then cannot resolve
/// the item it just imported: "Unable to Import Document", DocumentManager error 1) - one reason the full-screen
/// browser is gone (plan S9).
final class DocumentOpener: NSObject, ObservableObject, UIDocumentPickerDelegate {
    /// Any controller in the home screen's window; documents are presented from the window's root.
    weak var anchor: UIViewController?
    private var pending: URL?                 // asked to open while the window or another document was not ready
    private var editorOpen = false
    /// The window's root, kept while it is reachable: under a full-screen editor the home screen's views leave the
    /// window (anchor.view.window becomes nil), so the root must not be looked up through them when closing.
    private weak var lastRoot: UIViewController?
    /// The open editor and the controller that presented it.
    private weak var editorHost: UIViewController?
    private weak var editorPresenter: UIViewController?
    /// New files this app made in this session (New, a template), not yet closed, with the bytes they were made
    /// with (plan S9). Closed again without any change, such a file is removed - a tap on New by mistake or a look at a
    /// template leaves no "Document 3" behind. Only these: a file the user brought (Browse, Recent, Open in, a file
    /// this list once held and that was kept) is never deleted. Blank templates are a few KB.
    private var fresh: [String: Data] = [:]
    /// What the last picker was, for the Autotest harness (RealDocumentHarness): "<class> <style> presenter=<0|1>
    /// types=<...>", then " picked" / " cancelled". Plain text, not published: nothing on Home shows it.
    private(set) var lastPicker = ""

    private var root: UIViewController? {
        if let r = anchor?.view.window?.rootViewController { lastRoot = r; return r }
        return lastRoot
    }

    func attach(_ vc: UIViewController) {
        anchor = vc
        if let url = pending { pending = nil; DispatchQueue.main.async { self.open(url) } }
    }

    // MARK: entry points from the home screen

    func create(_ kind: OfficeKind) {
        do { open(remember(try NewDocuments.create(kind))) }
        catch { alert(L.cannotCreate, error.localizedDescription) }
    }

    /// A new file from a gallery template (plan S8), opened in the editor at once.
    func create(from template: TemplateManifest.Template, lang: String) {
        do { open(remember(try NewDocuments.create(from: template, lang: lang))) }
        catch { alert(L.cannotCreate, error.localizedDescription) }
    }

    /// The system document picker (plan S9) - Recents / Shared / Browse like the Files app, optionally for one kind of
    /// file - as a sheet over Home, with its standard Cancel: a page sheet on iPhone, a form sheet on iPad (which UIKit
    /// itself turns into a page sheet in a narrow Split View or Slide Over window). Home stays visible behind it.
    /// The file is opened where it is (asCopy: false - no copy in the app's folder), so its saves go back into it;
    /// open() holds its security-scoped access while the editor is up, and Recent keeps a bookmark to it.
    func browse(_ types: [UTType] = [.docx, .xlsx, .pptx, .pdf]) {
        guard let root, !editorOpen else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        picker.delegate = self
        picker.view.tintColor = .xrTeal
        let pad = UIDevice.current.userInterfaceIdiom == .pad
        picker.modalPresentationStyle = pad ? .formSheet : .pageSheet
        let what = "\(type(of: picker)) \(pad ? "formSheet" : "pageSheet")"
        let kinds = types.map { $0.preferredFilenameExtension ?? $0.identifier }.joined(separator: ",")
        lastPicker = what + " shown"
        top(of: root).present(picker, animated: true) { [weak self] in
            // the presenter's view is still in the window: a sheet over Home, not a full-screen cover
            let behind = root.view.window != nil
            self?.lastPicker = "\(what) presenter=\(behind ? 1 : 0) types=\(kinds)"
            NSLog("XR picker %@", self?.lastPicker ?? "")
        }
    }

    /// A document handed to the app by the system (Files "Open in", Share).
    func openExternal(_ url: URL) { open(url) }

    // MARK: picker delegate

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        lastPicker += " picked"
        guard let url = urls.first else { return }
        // the picker closes itself after a pick: the editor is presented once it has gone, never during its slide
        afterDismissal(of: controller) { self.open(url) }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        lastPicker += " cancelled"
        NSLog("XR picker cancelled")
        // the picker closes itself on Cancel. Should it stay presented (CI, iPad: Home stopped taking taps after the
        // second picker's Cancel, with nothing visible over it), it is dismissed here - after its own dismissal had
        // its chance to start, so a closing picker is never dismissed twice
        DispatchQueue.main.async {
            guard controller.presentingViewController != nil, !controller.isBeingDismissed else { return }
            NSLog("XR picker still presented after Cancel - dismissing it")
            controller.dismiss(animated: true)
        }
    }

    private final class Once { var done = false }

    /// `then`, exactly once (a second open() would queue the same file again), as soon as `vc` has left the screen:
    /// at once when it already has; else it is dismissed here unless its own dismissal is under way, and watched every
    /// 0.1 s - 2 s at most, so a dismissal UIKit dropped never leaves the picked file unopened.
    private func afterDismissal(of vc: UIViewController, _ then: @escaping () -> Void) {
        let once = Once()
        let finish = { if !once.done { once.done = true; then() } }
        if vc.presentingViewController != nil && !vc.isBeingDismissed { vc.dismiss(animated: true) { finish() } }
        watchDismissal(of: vc, n: 0, finish)
    }

    private func watchDismissal(of vc: UIViewController, n: Int, _ finish: @escaping () -> Void) {
        if vc.presentingViewController == nil || n >= 20 { finish(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.watchDismissal(of: vc, n: n + 1, finish) }
    }

    /// For the Autotest harness: what is presented over the window's root right now - "none", or its class, with
    /// " dismissing" while it goes.
    var presentedNow: String {
        guard let p = root?.presentedViewController else { return "none" }
        return "\(type(of: p))" + (p.isBeingDismissed ? " dismissing" : "")
    }

    // MARK: new files closed without a change (plan S9)

    private static func key(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }

    /// A file just made by create(): remembered with its bytes until its editor closes.
    private func remember(_ url: URL) -> URL {
        fresh[Self.key(url)] = (try? Data(contentsOf: url)) ?? Data()
        return url
    }

    /// The editor of `url` has closed (its UIDocument too). A file this app made in this session is removed when
    /// nothing happened to it: the engine never reported an edit, nothing was saved into it, it was not renamed,
    /// moved or duplicated (OpenDocumentModel.touched), it is still where it was made, and its bytes are still the
    /// ones it was made with. Any doubt keeps the file. Its Recent row goes first, so Home never shows it.
    private func closed(_ url: URL, _ model: OpenDocumentModel) {
        guard let made = fresh.removeValue(forKey: Self.key(url)) else { return }     // the first close only
        let here = Self.key(model.fileURL) == Self.key(url)
        let same = !made.isEmpty && (try? Data(contentsOf: url)) == made
        guard !model.touched, here, same else {
            NSLog("XR new file kept: %@ (touched=%ld moved=%ld changed=%ld)", url.lastPathComponent,
                  model.touched ? 1 : 0, here ? 0 : 1, same ? 0 : 1)
            return
        }
        RecentFiles.shared.forget(url)
        DispatchQueue.global(qos: .utility).async {
            var cerr: NSError?
            var removed = false
            // coordinated, as every other write to a document: the Files app may be presenting the folder
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forDeleting, error: &cerr) { u in
                removed = (try? FileManager.default.removeItem(at: u)) != nil
            }
            let ok = removed && cerr == nil
            DispatchQueue.main.async {
                NSLog("XR untouched new file %@: %@", url.lastPathComponent, ok ? "removed" : "not removed")
                // could not be removed: it stays a normal file, listed in Recent again
                if !ok && FileManager.default.fileExists(atPath: url.path) { RecentFiles.shared.add(url) }
            }
        }
    }

    // MARK: opening

    private func openPending() {
        if let next = pending { pending = nil; open(next) }
    }

    func open(_ url: URL) {
        NSLog("XR open %@ editorOpen=%ld", url.lastPathComponent, editorOpen ? 1 : 0)
        guard let root, !editorOpen else { pending = url; return }
        guard OfficeKind(url: url) != nil else { alert(L.cannotOpen, url.lastPathComponent); return }
        editorOpen = true
        let scoped = url.startAccessingSecurityScopedResource()       // documents outside the app's own folder
        let file = OfficeFile(fileURL: url)
        file.open { [weak self] ok in
            guard let self else { return }
            guard ok, let model = OpenDocumentModel(file: file) else {
                if scoped { url.stopAccessingSecurityScopedResource() }
                self.editorOpen = false
                self.fresh.removeValue(forKey: Self.key(url))           // never shown: never removed by the app later
                self.alert(L.cannotOpen, url.lastPathComponent)
                return
            }
            RecentFiles.shared.add(url)
            let host = UIHostingController(rootView: AnyView(EmptyView()))
            host.rootView = AnyView(EditorHost(model: model) { [weak self] in
                file.close { _ in
                    if scoped { url.stopAccessingSecurityScopedResource() }
                    guard let self else { return }
                    // the editor is closed as far as opening the next file goes, whatever the animation does
                    self.editorOpen = false
                    NSLog("XR editor closed")
                    self.closed(url, model)
                    self.dismissEditor { self.openPending() }
                }
            })
            host.modalPresentationStyle = .fullScreen
            self.editorHost = host
            self.editorPresenter = root
            if let shown = root.presentedViewController {            // e.g. the account card: replace it with the editor
                root.dismiss(animated: false) { root.present(host, animated: true) }
            } else {
                root.present(host, animated: true)
            }
        }
    }

    /// Back to the home screen: dismisses the editor and anything still above it (the account sheet, the keyboard).
    /// UIKit silently drops a dismissal asked for while another presentation is still animating (a sheet sliding
    /// down, the keyboard going away) - wait for that, and check that the editor really went.
    private func dismissEditor(attempt: Int = 0, then done: @escaping () -> Void) {
        guard let host = editorHost, let r = host.presentingViewController ?? editorPresenter else { done(); return }
        guard r.presentedViewController != nil else { done(); return }
        host.view.endEditing(true)
        let busy = r.transitionCoordinator != nil || host.isBeingPresented || host.isBeingDismissed
            || (host.presentedViewController.map { $0.isBeingPresented || $0.isBeingDismissed } ?? false)
        if busy && attempt < 20 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.dismissEditor(attempt: attempt + 1, then: done) }
            return
        }
        var settled = false
        let check = {
            if settled { return }
            settled = true
            if r.presentedViewController != nil && attempt < 20 {      // still there (dropped dismissal): try again
                NSLog("XR editor still shown after dismiss, retrying")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.dismissEditor(attempt: attempt + 1, then: done) }
            } else {
                NSLog("XR editor dismissed")
                done()
            }
        }
        // from the presenter: closes the editor AND anything still above it (the account sheet)
        r.dismiss(animated: true) { check() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { check() }   // no completion = the request was dropped
    }

    private func top(of vc: UIViewController) -> UIViewController {
        var t = vc
        while let p = t.presentedViewController, !p.isBeingDismissed { t = p }
        return t
    }

    private func alert(_ title: String, _ message: String) {
        guard let root else { return }
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: L.ok, style: .default))
        top(of: root).present(a, animated: true)
    }
}

/// Recently opened files (security-scoped bookmarks, so files from iCloud Drive / other apps reopen too).
final class RecentFiles: ObservableObject {
    static let shared = RecentFiles()
    struct Item: Identifiable, Equatable {
        let id: String          // file path when added: one row per file
        let name: String
        let date: Date          // when it was last opened (the Recent subtitle)
        let bookmark: Data
        /// Where the file lives, stored as a key and worded at render time so a language switch rewords it:
        /// "device" (On My iPhone > Xrero Office), "icloud" or "folder:<name>". Empty for 20.2 entries until reopened.
        var place: String = ""
        var kind: OfficeKind? { OfficeKind(url: URL(fileURLWithPath: name)) }
    }
    @Published private(set) var items: [Item] = []
    private let key = "xr.recents"
    private let limit = 20

    init() { load() }

    /// `behindFirst`: a copy made from the open document (title menu > Duplicate) goes right after it - the open file
    /// stays the most recent one.
    func add(_ url: URL, behindFirst: Bool = false) {
        guard let bm = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        var list = items.filter { $0.id != url.path }
        let item = Item(id: url.path, name: url.lastPathComponent, date: Date(), bookmark: bm, place: Self.place(of: url))
        list.insert(item, at: behindFirst ? min(1, list.count) : 0)
        items = Array(list.prefix(limit))
        save()
    }

    /// The open file was renamed or moved (title menu, plan M4b): its row now points at the new place with a fresh
    /// bookmark, keeping its position and date, so Home shows the new name and reopens the file where it is now.
    func replace(_ old: URL, with new: URL) {
        guard let bm = try? new.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        // compared in one form: the editor's file URL can differ from the opened one (/var vs /private/var), and a
        // missed match would leave the old row behind, its bookmark now pointing at the renamed file (two rows)
        func same(_ id: String) -> Bool {
            URL(fileURLWithPath: id).standardizedFileURL.resolvingSymlinksInPath().path
                == old.standardizedFileURL.resolvingSymlinksInPath().path
        }
        guard let i = items.firstIndex(where: { $0.id == old.path || same($0.id) }) else { add(new); return }
        var list = items
        list[i] = Item(id: new.path, name: new.lastPathComponent, date: list[i].date, bookmark: bm, place: Self.place(of: new))
        // one row per file: an older row for the new path (a file once known by this name) goes
        list = list.enumerated().filter { $0.offset == i || $0.element.id != new.path }.map(\.element)
        items = list
        save()
    }

    func remove(_ item: Item) {
        items.removeAll { $0.id == item.id }
        save()
    }

    /// The row(s) of a file the app removed itself (an untouched new file, plan S9), compared in one form (/var vs
    /// /private/var) as in replace().
    func forget(_ url: URL) {
        let p = url.standardizedFileURL.resolvingSymlinksInPath().path
        let before = items.count
        items.removeAll { $0.id == url.path || URL(fileURLWithPath: $0.id).standardizedFileURL.resolvingSymlinksInPath().path == p }
        if items.count != before { save() }
    }

    /// The file's current location (it may have been moved or renamed since), nil when it is gone. A stale bookmark
    /// (the file moved) still resolves; it is renewed right after, while the file is reachable, so the next launch
    /// does not depend on the old one.
    func resolve(_ item: Item) -> URL? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: item.bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        else {
            // a bookmark made right after a rename can fail to resolve while the file is still there under its row's
            // path (CI: the renamed file "gone" on reopen); the app's own folder needs no bookmark, so use that path
            let here = URL(fileURLWithPath: item.id)
            if Self.place(of: here) == "device", FileManager.default.fileExists(atPath: here.path) {
                DispatchQueue.main.async { self.renew(item, at: here) }
                return here
            }
            return nil
        }
        if stale {
            // not during a view update: publishing from inside `body` is not allowed
            DispatchQueue.main.async { self.renew(item, at: url) }
        }
        return url
    }

    private func renew(_ item: Item, at url: URL) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let bm = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        items[i] = Item(id: item.id, name: url.lastPathComponent, date: item.date, bookmark: bm, place: Self.place(of: url))
        save()
    }

    /// "device" for the app's own folder, "icloud" for iCloud Drive, else the containing folder's name.
    static func place(of url: URL) -> String {
        let path = url.resolvingSymlinksInPath().path
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
           path.hasPrefix(docs.resolvingSymlinksInPath().path) { return "device" }
        if path.contains("/Mobile Documents/") { return "icloud" }
        return "folder:" + url.deletingLastPathComponent().lastPathComponent
    }

    private func load() {
        guard let raw = UserDefaults.standard.array(forKey: key) as? [[String: Any]] else { return }
        items = raw.compactMap { d in
            guard let id = d["id"] as? String, let name = d["name"] as? String, let date = d["date"] as? Date,
                  let bm = d["bookmark"] as? Data else { return nil }
            return Item(id: id, name: name, date: date, bookmark: bm, place: d["place"] as? String ?? "")
        }
    }

    private func save() {
        UserDefaults.standard.set(items.map { ["id": $0.id, "name": $0.name, "date": $0.date, "bookmark": $0.bookmark,
                                               "place": $0.place] },
                                  forKey: key)
    }
}

/// Lets the home screen hand its window's controllers to the opener.
struct PresenterAnchor: UIViewControllerRepresentable {
    let opener: DocumentOpener
    func makeUIViewController(context: Context) -> UIViewController {
        let vc = AnchorController()
        vc.onAppear = { [weak vc] in if let vc { opener.attach(vc) } }
        return vc
    }
    func updateUIViewController(_ vc: UIViewController, context: Context) {}

    final class AnchorController: UIViewController {
        var onAppear: (() -> Void)?
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            onAppear?()
        }
    }
}
