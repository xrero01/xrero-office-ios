import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Opens documents over the home screen: new ones (written straight into "On My iPhone > Xrero Office"), files picked
/// in the system document browser, files handed over by Files / Share ("Open in Xrero Office") and recent files.
///
/// New documents are created by the app itself and opened by their file URL. The document browser's own
/// create-and-import path fails on the app's very first launch (the system imports the new file, then cannot resolve
/// the item it just imported: "Unable to Import Document", DocumentManager error 1).
final class DocumentOpener: NSObject, ObservableObject, UIDocumentBrowserViewControllerDelegate {
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
        do { open(try NewDocuments.create(kind)) }
        catch { alert(L.cannotCreate, error.localizedDescription) }
    }

    /// The system document browser (Recents / Shared / Browse, like the Files app), optionally for one kind of file.
    func browse(_ types: [UTType] = [.docx, .xlsx, .pptx, .pdf]) {
        guard let root, !editorOpen else { return }
        let browser = UIDocumentBrowserViewController(forOpening: types)
        browser.allowsDocumentCreation = false
        browser.allowsPickingMultipleItems = false
        browser.delegate = self
        browser.view.tintColor = UIColor(red: 0.12, green: 0.48, blue: 0.55, alpha: 1)
        let done = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak browser] _ in
            browser?.dismiss(animated: true)
        })
        done.accessibilityIdentifier = "xr-browser-close"
        browser.additionalLeadingNavigationBarButtonItems = [done]
        browser.modalPresentationStyle = .fullScreen
        top(of: root).present(browser, animated: true)
    }

    /// A document handed to the app by the system (Files "Open in", Share).
    func openExternal(_ url: URL) { open(url) }

    // MARK: browser delegate

    func documentBrowser(_ controller: UIDocumentBrowserViewController, didPickDocumentsAt documentURLs: [URL]) {
        guard let url = documentURLs.first else { return }
        controller.dismiss(animated: true) { self.open(url) }
    }

    func documentBrowser(_ controller: UIDocumentBrowserViewController, didImportDocumentAt sourceURL: URL,
                         toDestinationURL destinationURL: URL) {
        controller.dismiss(animated: true) { self.open(destinationURL) }
    }

    func documentBrowser(_ controller: UIDocumentBrowserViewController, failedToImportDocumentAt documentURL: URL, error: Error?) {
        alert(L.cannotOpen, error?.localizedDescription ?? documentURL.lastPathComponent)
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
        a.addAction(UIAlertAction(title: "OK", style: .default))
        top(of: root).present(a, animated: true)
    }
}

/// Recently opened files (security-scoped bookmarks, so files from iCloud Drive / other apps reopen too).
final class RecentFiles: ObservableObject {
    static let shared = RecentFiles()
    struct Item: Identifiable, Equatable {
        let id: String          // file path when added: one row per file
        let name: String
        let date: Date
        let bookmark: Data
        var kind: OfficeKind? { OfficeKind(url: URL(fileURLWithPath: name)) }
    }
    @Published private(set) var items: [Item] = []
    private let key = "xr.recents"
    private let limit = 20

    init() { load() }

    func add(_ url: URL) {
        guard let bm = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        var list = items.filter { $0.id != url.path }
        list.insert(Item(id: url.path, name: url.lastPathComponent, date: Date(), bookmark: bm), at: 0)
        items = Array(list.prefix(limit))
        save()
    }

    func remove(_ item: Item) {
        items.removeAll { $0.id == item.id }
        save()
    }

    /// The file's current location (it may have been moved or renamed since), nil when it is gone.
    func resolve(_ item: Item) -> URL? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: item.bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        else { return nil }
        return url
    }

    private func load() {
        guard let raw = UserDefaults.standard.array(forKey: key) as? [[String: Any]] else { return }
        items = raw.compactMap { d in
            guard let id = d["id"] as? String, let name = d["name"] as? String, let date = d["date"] as? Date,
                  let bm = d["bookmark"] as? Data else { return nil }
            return Item(id: id, name: name, date: date, bookmark: bm)
        }
    }

    private func save() {
        UserDefaults.standard.set(items.map { ["id": $0.id, "name": $0.name, "date": $0.date, "bookmark": $0.bookmark] },
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
