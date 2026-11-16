import SwiftUI
import UIKit

@main
struct XreroOfficeApp: App {
    /// Home Screen quick actions reach the app through its delegate (QuickActions.swift)
    @UIApplicationDelegateAdaptor(XRAppDelegate.self) private var appDelegate

    var body: some Scene {
        #if XR_AUTOTEST
        // CI build only (configuration "Autotest"): opens a fresh document straight in the editor for the UI tests
        // (XR_GALLERY=1: the template gallery first - TemplateGallery.swift, TemplateGalleryUITests; otherwise
        // AutotestRoot, QuickActions.swift: the test editor, or Home for the quick-action, scan and accessibility tests)
        WindowGroup {
            if ProcessInfo.processInfo.environment["XR_GALLERY"] == "1" { TemplateAutotestRoot() } else { AutotestRoot() }
        }
        .commands {
            // the same menu bar (EditorUITests window gate) + a test-only probe (AutotestScreen.swift)
            XreroCommands(language: AppLanguage.shared, targets: MenuBarTargets.shared)
            AutotestMenuProbe(targets: MenuBarTargets.shared)
        }
        #else
        WindowGroup { HomeScene().appLanguageEnvironment() }   // start screen; documents open over it (HomeScene.swift, DocumentOpener.swift)
            .commands { XreroCommands(language: AppLanguage.shared, targets: MenuBarTargets.shared) }
        #endif
    }
}

// MARK: the menu bar (plan S6)

/// A window's open editor as the menu bar sees it (MenuBarTargets.editor).
struct EditorMenuTarget {
    let controller: EditorController
    let kind: OfficeKind

    /// Bold / Italic / Underline: Word documents, where the keyboard bar and the Aa sheet offer them too.
    var formats: Bool { kind == .word }

    // The keyboard bar's own engine calls (EditorController.toggleFormat), one log line per use ("menu: bold" - CI
    // reads it). Only on a menu pick, never per keystroke.
    func bold() { controller.toggleFormat("bold", source: "menu") }
    func italic() { controller.toggleFormat("italic", source: "menu") }
    func underline() { controller.toggleFormat("underline", source: "menu") }
    func find() { controller.find() }
    func close() { controller.close() }
}

/// Which home screen and which open editor each window has, for the menu bar (plan S6).
///
/// Not SwiftUI's focusedSceneValue: the shipped editor lives in its own UIHostingController (EditorHost) that
/// DocumentOpener presents full screen through UIKit, outside the scene's SwiftUI tree - the home screen's views even
/// leave the window while it is up - and nothing guarantees that a focused value set in there, or left behind by the
/// home screen, reaches the scene's Commands. So both register here with plain UIKit facts instead: an editor's web
/// view while it is in a window (XRWebView.didMoveToWindow - the real EditorScreen and the CI's AutotestScreen alike),
/// a home screen's opener once its window is up (DocumentOpener.attach - HomeScene and the CI's RealDocumentHarness
/// alike). The menu asks for the window in front: the scene whose window last became key (UIKit's key window, the one
/// the menu bar and the ⌘-hold list act on). CI gate: EditorUITests.testZZZZZMenuBarOnRealEditor (the shipped
/// DocumentOpener -> EditorHost path) and testZZZZWindowLayoutAndKeyCommands.
final class MenuBarTargets: ObservableObject {
    static let shared = MenuBarTargets()

    private final class EditorEntry {
        weak var view: UIView?
        weak var controller: EditorController?
        let kind: OfficeKind
        init(_ view: UIView, _ controller: EditorController, _ kind: OfficeKind) {
            self.view = view; self.controller = controller; self.kind = kind
        }
    }
    private final class HomeEntry {
        weak var opener: DocumentOpener?
        weak var scene: UIWindowScene?
        init(_ opener: DocumentOpener, _ scene: UIWindowScene?) { self.opener = opener; self.scene = scene }
    }
    private var editors: [EditorEntry] = []
    private var homes: [HomeEntry] = []
    private weak var keyScene: UIWindowScene?          // the scene whose window last became key
    private var keyObserver: NSObjectProtocol?

    private init() {
        // the menu's enabled items follow the window in front (iPad: two app windows side by side, Stage Manager)
        keyObserver = NotificationCenter.default.addObserver(forName: UIWindow.didBecomeKeyNotification, object: nil,
                                                             queue: .main) { [weak self] note in
            guard let self, let scene = (note.object as? UIWindow)?.windowScene, scene !== self.keyScene else { return }
            self.keyScene = scene
            self.changed()
        }
    }

    /// An editor's web view entered a window.
    func editorShown(_ view: UIView, controller: EditorController, kind: OfficeKind) {
        editors.removeAll { $0.view == nil || $0.controller == nil || $0.view === view }
        editors.append(EditorEntry(view, controller, kind))
        changed()
    }

    /// An editor's web view left its window (the editor closed): the menu no longer acts on it.
    func editorHidden(_ view: UIView) {
        editors.removeAll { $0.view == nil || $0.controller == nil || $0.view === view }
        changed()
    }

    /// A home screen's opener has its window (File > New Document / Spreadsheet / Presentation, Open…).
    func homeShown(_ opener: DocumentOpener, scene: UIWindowScene?) {
        homes.removeAll { $0.opener == nil || $0.opener === opener }
        homes.append(HomeEntry(opener, scene))
        changed()
    }

    /// The window in front: the only one (every iPhone, most iPads - no guess to make), else the one whose window last
    /// became key, else the one holding a key window.
    private var front: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if scenes.count == 1 { return scenes.first }
        if let s = keyScene, scenes.contains(where: { $0 === s }) { return s }
        return scenes.first { s in s.windows.contains { $0.isKeyWindow } }
    }

    /// The open editor of the window in front; nil when that window shows none.
    var editor: EditorMenuTarget? {
        guard let scene = front else { return nil }
        for e in editors.reversed() {
            if let v = e.view, let c = e.controller, v.window?.windowScene === scene {
                return EditorMenuTarget(controller: c, kind: e.kind)
            }
        }
        return nil
    }

    /// The home screen (its document opener) of the window in front.
    var home: DocumentOpener? {
        guard let scene = front else { return nil }
        return homes.reversed().first { $0.opener != nil && $0.scene === scene }?.opener
    }

    /// The menu is rebuilt after the UIKit callback that changed something - never from inside a SwiftUI view update.
    private func changed() { DispatchQueue.main.async { self.objectWillChange.send() } }
}

/// The menu bar on iPad and the Mac, and the list iPadOS shows while ⌘ is held (plan S6): File, Edit and Format
/// commands for the window in front. Each reaches that window's home screen or open editor through MenuBarTargets
/// and is disabled when the window has none. Words in the app's own language (EN / AR).
///
/// Bold / Italic / Underline and Find are listed WITHOUT a key equivalent: ⌘B / ⌘I / ⌘U belong to the editor view's
/// own key commands (XRWebView.formatKey - the page does not reliably get them on iOS) and ⌘F to the web editor; a
/// menu key equivalent as well would claim the same key twice. The system's own Format (Font / Text) and Find
/// entries are replaced for the same reason: they act only on system text views, so here they were always disabled.
/// CI gate: EditorUITests.testZZZZWindowLayoutAndKeyCommands and testZZZZZMenuBarOnRealEditor (a test-only menu
/// command runs `perform` - what these items run - with Bold and Close on the shipped editor path).
struct XreroCommands: Commands {
    @ObservedObject var language: AppLanguage
    @ObservedObject var targets: MenuBarTargets

    private var ar: Bool { language.isArabic }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(ar ? "مستند جديد" : "New Document") { Self.perform(.newDocument, targets) }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(targets.home == nil)
            Button(ar ? "جدول بيانات جديد" : "New Spreadsheet") { Self.perform(.newSpreadsheet, targets) }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(targets.home == nil)
            Button(ar ? "عرض تقديمي جديد" : "New Presentation") { Self.perform(.newPresentation, targets) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(targets.home == nil)
            Divider()
            // files open from the home screen (one document at a time): not over an open editor
            Button(ar ? "فتح…" : "Open…") { Self.perform(.open, targets) }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(targets.home == nil || targets.editor != nil)
            Divider()
            // no ⌘W: CI run 155 pressed it with this menu active and it never reached Close - on the iPhone the key
            // went on to the page, so another (system) ⌘W entry owns the key. A shortcut shown here that does not work
            // would over-promise.
            Button(ar ? "إغلاق" : "Close") { Self.perform(.close, targets) }
                .disabled(targets.editor == nil)
        }
        CommandGroup(replacing: .textEditing) {
            Button(ar ? "بحث…" : "Find…") { Self.perform(.find, targets) }
                .disabled(targets.editor == nil)
        }
        CommandGroup(replacing: .textFormatting) {
            Button(ar ? "غامق" : "Bold") { Self.perform(.bold, targets) }
                .disabled(!(targets.editor?.formats ?? false))
            Button(ar ? "مائل" : "Italic") { Self.perform(.italic, targets) }
                .disabled(!(targets.editor?.formats ?? false))
            Button(ar ? "تسطير" : "Underline") { Self.perform(.underline, targets) }
                .disabled(!(targets.editor?.formats ?? false))
        }
    }

    enum Action: String {
        case newDocument, newSpreadsheet, newPresentation, open, close, find, bold, italic, underline
    }

    /// What each item does, for the window in front at the moment it is picked. One place, so the CI's test-only menu
    /// command (AutotestMenuProbe) runs exactly what the menu item runs.
    static func perform(_ action: Action, _ targets: MenuBarTargets) {
        let editor = targets.editor
        switch action {
        case .newDocument: create(.word, targets)
        case .newSpreadsheet: create(.cell, targets)
        case .newPresentation: create(.slide, targets)
        case .open: if editor == nil { targets.home?.browse() }
        case .close: editor?.close()
        case .find: editor?.find()
        case .bold: if editor?.formats == true { editor?.bold() }
        case .italic: if editor?.formats == true { editor?.italic() }
        case .underline: if editor?.formats == true { editor?.underline() }
        }
    }

    /// A new blank document. Over an open editor, that one saves and closes first and the new one opens after it
    /// (DocumentOpener.open holds a file asked for while an editor is still up).
    private static func create(_ kind: OfficeKind, _ targets: MenuBarTargets) {
        guard let home = targets.home else { return }
        let editor = targets.editor
        home.create(kind)
        editor?.close()
    }
}
