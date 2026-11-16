import SwiftUI

@main
struct XreroOfficeApp: App {
    var body: some Scene {
        #if XR_AUTOTEST
        // CI build only (configuration "Autotest"): opens a fresh document straight in the editor for the UI tests
        // (XR_GALLERY=1: the template gallery first - TemplateGallery.swift, TemplateGalleryUITests)
        WindowGroup {
            if ProcessInfo.processInfo.environment["XR_GALLERY"] == "1" { TemplateAutotestRoot() } else { AutotestScreen() }
        }
        .commands {
            XreroCommands(language: AppLanguage.shared)             // the same menu bar (EditorUITests window gate)
            AutotestMenuProbe()                                     // + a test-only probe (AutotestScreen.swift)
        }
        #else
        WindowGroup { HomeScene().appLanguageEnvironment() }   // start screen; documents open over it (HomeScene.swift, DocumentOpener.swift)
            .commands { XreroCommands(language: AppLanguage.shared) }
        #endif
    }
}

// MARK: the menu bar (plan S6)

/// The window's open editor as the menu bar sees it: EditorScreen (and the CI's AutotestScreen) publish it with
/// focusedSceneValue. Equal while it is the same editor, so a redraw of the screen does not rebuild the menu.
struct EditorMenuTarget: Equatable {
    let controller: EditorController
    let kind: OfficeKind

    static func == (a: EditorMenuTarget, b: EditorMenuTarget) -> Bool { a.controller === b.controller && a.kind == b.kind }

    /// Bold / Italic / Underline: Word documents, where the keyboard bar and the Aa sheet offer them too.
    var formats: Bool { kind == .word }

    // The keyboard bar's / format sheet's own engine calls, one log line per use ("menu: bold" - CI reads it).
    // Only on a menu pick, never per keystroke.
    func bold() { controller.format("menu", "bold", "a.put_TextPrBold(\(!controller.state.bold))") }
    func italic() { controller.format("menu", "italic", "a.put_TextPrItalic(\(!controller.state.italic))") }
    func underline() { controller.format("menu", "underline", "a.put_TextPrUnderline(\(!controller.state.underline))") }
    func find() { controller.find() }
    func close() { controller.close() }
}

private struct EditorMenuKey: FocusedValueKey { typealias Value = EditorMenuTarget }
private struct HomeMenuKey: FocusedValueKey { typealias Value = DocumentOpener }

extension FocusedValues {
    /// The open editor of the window in front (EditorScreen, AutotestScreen).
    var xrEditor: EditorMenuTarget? {
        get { self[EditorMenuKey.self] }
        set { self[EditorMenuKey.self] = newValue }
    }
    /// The home screen of the window in front (HomeScene): its opener makes new documents and shows the file browser.
    var xrHome: DocumentOpener? {
        get { self[HomeMenuKey.self] }
        set { self[HomeMenuKey.self] = newValue }
    }
}

/// The menu bar on iPad and the Mac, and the list iPadOS shows while ⌘ is held (plan S6): File, Edit and Format
/// commands for the window in front. Each reaches that window's home screen or open editor through focusedSceneValue
/// (HomeScene / EditorScreen) and is disabled when the window has none. Words in the app's own language (EN / AR).
///
/// Key equivalents only where the web editor has none of its own. Bold / Italic / Underline and Find are listed
/// WITHOUT one: ⌘B / ⌘I / ⌘U / ⌘F stay with the editor, which handles them itself - a menu key equivalent would take
/// the key first, and a toggle reached both ways could run twice. The system's own Format (Font / Text) and Find
/// entries are replaced for the same reason: they act only on system text views, so here they were always disabled,
/// and a second ⌘B / ⌘F binding is gone. CI gate: EditorUITests.testZZZZWindowLayoutAndKeyCommands (⌘B toggles Bold
/// exactly once, the menu's Bold once, ⌘W reaches the editor through this menu).
struct XreroCommands: Commands {
    @ObservedObject var language: AppLanguage
    @FocusedValue(\.xrHome) private var home: DocumentOpener?
    @FocusedValue(\.xrEditor) private var editor: EditorMenuTarget?

    private var ar: Bool { language.isArabic }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(ar ? "مستند جديد" : "New Document") { create(.word) }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(home == nil)
            Button(ar ? "جدول بيانات جديد" : "New Spreadsheet") { create(.cell) }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(home == nil)
            Button(ar ? "عرض تقديمي جديد" : "New Presentation") { create(.slide) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(home == nil)
            Divider()
            // files open from the home screen (one document at a time): not over an open editor
            Button(ar ? "فتح…" : "Open…") { home?.browse() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(home == nil || editor != nil)
            Divider()
            Button(ar ? "إغلاق" : "Close") { editor?.close() }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(editor == nil)
        }
        CommandGroup(replacing: .textEditing) {
            Button(ar ? "بحث…" : "Find…") { editor?.find() }
                .disabled(editor == nil)
        }
        CommandGroup(replacing: .textFormatting) {
            Button(ar ? "غامق" : "Bold") { editor?.bold() }
                .disabled(!(editor?.formats ?? false))
            Button(ar ? "مائل" : "Italic") { editor?.italic() }
                .disabled(!(editor?.formats ?? false))
            Button(ar ? "تسطير" : "Underline") { editor?.underline() }
                .disabled(!(editor?.formats ?? false))
        }
    }

    /// A new blank document. Over an open editor, that one saves and closes first and the new one opens after it
    /// (DocumentOpener.open holds a file asked for while an editor is still up).
    private func create(_ kind: OfficeKind) {
        guard let home else { return }
        home.create(kind)
        editor?.close()
    }
}
