import SwiftUI

/// The editor's one native top bar (plan M4a): Back, the file name with its Edited / Saving / Saved line, Undo (and
/// Redo on iPad / wide windows) and the ⋯ menu. It replaces the editors' own title row (hidden in web/xr-host.js), so
/// the page gets about 44 pt more room and there is one header instead of two. Mirrored as one piece in Arabic (the
/// layout direction comes from the screen that applies it; SF "backward" symbols flip by themselves).
///
/// Undo / Redo go through the bridge (EditorController.call -> __xrUndo in xr-host.js, which first commits a word
/// still being composed). No keyboard shortcut is attached on purpose: the engine handles a hardware ⌘Z / ⇧⌘Z itself,
/// and a second binding here would undo twice.
///
/// A tap on the file name opens the title menu (plan M4b): Rename, Duplicate, Move… (the screen passes `titleMenu`).
/// Aa (Word) opens the format sheet (plan S1, FormatSheet.swift); the iPad popover hangs under it.
///
/// The ⋯ menu (plan M7b) starts with Find, Redo (compact width) and Save; the screen adds the rest of the document
/// menu (`more` = DocumentMenuItems: Share, Export, Document info, Language, Account, About, All tools).
///
/// Reading view (plan S2, ReadingView.swift): Word documents and PDFs get a trailing text button, Edit while reading and
/// Done while editing, just before ⋯. While reading, Undo / Redo and Aa are not shown (nothing can be edited).
struct EditorTopBar<More: View>: ViewModifier {
    var title: String
    var state: EditorState
    @ObservedObject var status: EditorBarStatus
    var controller: EditorController
    var ar: Bool
    var back: () -> Void
    var save: () -> Void
    /// ⋯ > Find (the editor's Find & Replace panel); nil leaves the entry out.
    var find: (() -> Void)?
    /// Everything the ⋯ menu's entries depend on besides `ar` and the width (language, account, file kind): the menu
    /// is rebuilt only when this changes (MoreMenu).
    var menuKey: String
    /// The title menu (plan M4b: Rename, Duplicate, Move…); nil = the title is not a button (CI screens without a file).
    var titleMenu: TitleMenuActions? = nil
    /// Aa (the format sheet, plan S1) in the bar: Word only for now.
    var format: Bool
    /// The reading view (plan S2): `.off` = no Edit / Done (spreadsheets, presentations, the CI test screens).
    @ObservedObject var reading: ReadingModel
    /// Edit / Done tapped.
    var toggleReading: () -> Void
    @ViewBuilder var more: () -> More
    @Environment(\.horizontalSizeClass) var sizeClass      // not private: that would hide the memberwise init

    func body(content: Content) -> some View {
        let wide = sizeClass == .regular
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .toolbarRole(.editor)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: back) {
                        // iPad: chevron + "Documents"; iPhone: the chevron alone (the room goes to the file name)
                        if wide {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.backward")
                                Text(BarText.documents(ar)).lineLimit(1)
                            }
                            .fixedSize()                   // its whole width (CI: a capsule cut to 44 pt showed "ocum")
                        } else {
                            Image(systemName: "chevron.backward")
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                    }
                    // a new item when the width class changes: the bar sizes an item once, and the class can still
                    // be compact when the bar is first laid out
                    .id(wide)
                    .accessibilityLabel(BarText.documents(ar))
                    .accessibilityIdentifier("xr-bar-back")
                }
                ToolbarItem(placement: .principal) {
                    // the title menu lies OVER the title rather than wrapping it: a Menu label is one button to
                    // accessibility, so the name and its Edited / Saved line would stop being readable texts (VoiceOver
                    // reads them on their own; the UI tests wait for them). A custom principal item replaces the
                    // system title, so iOS 26's toolbarTitleMenu would not show - this is the same menu on every iOS.
                    BarTitle(title: title, state: state, status: status, ar: ar, menu: titleMenu != nil)
                        .overlay {
                            if let titleMenu {
                                TitleMenu(title: title, ar: ar, actions: titleMenu).equatable()
                            }
                        }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !reading.reading {
                        UndoButton(state: state, redo: false, ar: ar) { undo(false) }
                        if wide { UndoButton(state: state, redo: true, ar: ar) { undo(true) } }
                        if format {
                            Button { controller.showFormat() } label: { FormatGlyph() }
                                .accessibilityLabel(FormatText.format(ar))
                                .accessibilityIdentifier("xr-bar-format")
                        }
                    }
                    if reading.available {
                        ReadingButton(model: reading, ar: ar, action: toggleReading)
                    }
                    // equatable: the menu is rebuilt only when what it shows changes (language, width, account,
                    // reading...), never because the screen redrew - a menu rebuilt while it is open stays on screen
                    // with every tap ignored (CI: the dead ⋯ menu after Document info / Language)
                    MoreMenu(key: menuKey, wide: wide, ar: ar, reading: reading.reading, state: state, find: find, save: save,
                             redo: { undo(true) }, more: more)
                        .equatable()
                }
            }
    }

    private func undo(_ redo: Bool) {
        controller.call("return window.__xrUndo ? __xrUndo(\(redo)) : 'no editor';")
    }
}

extension View {
    func editorTopBar<More: View>(title: String, state: EditorState, status: EditorBarStatus, controller: EditorController,
                                  ar: Bool, back: @escaping () -> Void, save: @escaping () -> Void,
                                  find: (() -> Void)? = nil, menuKey: String = "", titleMenu: TitleMenuActions? = nil, format: Bool = false,
                                  reading: ReadingModel = .off, toggleReading: @escaping () -> Void = {},
                                  @ViewBuilder more: @escaping () -> More) -> some View {
        modifier(EditorTopBar(title: title, state: state, status: status, controller: controller, ar: ar,
                              back: back, save: save, find: find, menuKey: menuKey, titleMenu: titleMenu, format: format,
                              reading: reading, toggleReading: toggleReading, more: more))
    }
}

/// What the bar's second line says, from the editor's own messages: "ready", "saved" (the file was really written)
/// and its log lines around a save. Kept apart from the screen so a change redraws only the title.
final class EditorBarStatus: ObservableObject {
    /// The document is on screen (false while the editor page opens or reopens).
    @Published private(set) var ready = false
    /// The engine is writing the file (its "save start" log line until the "saved" message or a failure).
    @Published private(set) var saving = false
    /// A save of THIS editor page completed: only then may the bar say "Saved" (no autosave exists yet, plan S9).
    @Published private(set) var didSave = false

    /// Every command the editor sends to the screen (O(1): log lines can arrive while typing).
    func note(_ cmd: String, _ param: String) {
        switch cmd {
        case "ready": put(\.ready, true); put(\.saving, false)
        case "too-large": put(\.ready, true); put(\.saving, false)       // nothing is opening any more
        case "saved": put(\.saving, false); put(\.didSave, true)
        case "log":
            if param.hasPrefix("save start") { put(\.saving, true) }
            else if param.hasPrefix("web process ended") { put(\.ready, false); put(\.saving, false) }
            // a save that ends without writing this file: a failure, or File > Save As (a copy, not this file)
            else if saving && (param.hasPrefix("save failed") || param.hasPrefix("save:") || param.hasPrefix("save as") ||
                               param.hasPrefix("exported copy")) { put(\.saving, false) }
        default: break
        }
    }

    /// The editor page is being loaded again (language switch).
    func reopening() { put(\.ready, false); put(\.saving, false) }

    private func put(_ key: ReferenceWritableKeyPath<EditorBarStatus, Bool>, _ value: Bool) {
        if self[keyPath: key] != value { self[keyPath: key] = value }
    }
}

/// Bar words, EN + AR.
enum BarText {
    static func documents(_ ar: Bool) -> String { ar ? "المستندات" : "Documents" }
    static func undo(_ ar: Bool) -> String { ar ? "تراجع" : "Undo" }
    static func redo(_ ar: Bool) -> String { ar ? "إعادة" : "Redo" }
    static func save(_ ar: Bool) -> String { ar ? "حفظ" : "Save" }
    static func find(_ ar: Bool) -> String { ar ? "بحث" : "Find" }
    static func more(_ ar: Bool) -> String { ar ? "المزيد" : "More" }
    static func opening(_ ar: Bool) -> String { ar ? "جارٍ الفتح…" : "Opening…" }
    static func saving(_ ar: Bool) -> String { ar ? "جارٍ الحفظ…" : "Saving…" }
    static func edited(_ ar: Bool) -> String { ar ? "معدَّل" : "Edited" }
    static func saved(_ ar: Bool) -> String { ar ? "محفوظ" : "Saved" }
    // the title menu (plan M4b)
    static func rename(_ ar: Bool) -> String { ar ? "إعادة التسمية" : "Rename" }
    static func duplicate(_ ar: Bool) -> String { ar ? "تكرار" : "Duplicate" }
    static func move(_ ar: Bool) -> String { ar ? "نقل…" : "Move…" }
    static func titleMenuHint(_ ar: Bool) -> String { ar ? "إعادة التسمية أو التكرار أو النقل" : "Rename, duplicate or move" }
    static func renameTitle(_ ar: Bool) -> String { ar ? "إعادة تسمية المستند" : "Rename Document" }
    static func name(_ ar: Bool) -> String { ar ? "الاسم" : "Name" }
    static func cancel(_ ar: Bool) -> String { ar ? "إلغاء" : "Cancel" }
    static func ok(_ ar: Bool) -> String { ar ? "حسناً" : "OK" }
    static func renameExists(_ ar: Bool) -> String {
        ar ? "تعذّر تغيير الاسم — يوجد ملف بالاسم نفسه" : "Couldn't rename — a file with that name exists"
    }
    static func renameFailed(_ ar: Bool) -> String { ar ? "تعذّر تغيير اسم الملف" : "Couldn't rename the file" }
    static func copyName(_ base: String, _ ar: Bool) -> String { ar ? base + " - نسخة" : base + " copy" }
    static func copySaved(_ name: String, _ ar: Bool) -> String { (ar ? "حُفظت نسخة: " : "Copy saved: ") + name }
    static func copyFailed(_ ar: Bool) -> String { ar ? "تعذّر إنشاء نسخة" : "Couldn't duplicate" }
    // the reading view (plan S2)
    static func edit(_ ar: Bool) -> String { ar ? "تحرير" : "Edit" }
    static func done(_ ar: Bool) -> String { ar ? "تم" : "Done" }
    static func editHint(_ ar: Bool) -> String { ar ? "تحرير هذا المستند" : "Edit this document" }
    static func doneHint(_ ar: Bool) -> String { ar ? "العودة إلى وضع القراءة" : "Back to reading view" }
    static func page(_ p: Int, _ n: Int, _ ar: Bool) -> String { ar ? "الصفحة \(p) من \(n)" : "Page \(p) of \(n)" }
    static func goToPage(_ ar: Bool) -> String { ar ? "الانتقال إلى صفحة" : "Go to Page" }
    static func pageNumber(_ ar: Bool) -> String { ar ? "رقم الصفحة" : "Page number" }
    static func go(_ ar: Bool) -> String { ar ? "انتقال" : "Go" }
    static func pageRange(_ n: Int, _ ar: Bool) -> String { ar ? "من 1 إلى \(n)" : "1 to \(n)" }
}

/// What the title menu does (the screen's own actions; plan M4b).
struct TitleMenuActions {
    var rename: () -> Void
    var duplicate: () -> Void
    var move: () -> Void
}

/// The title menu: Rename, Duplicate, Move…, opened by a tap on the file name (as in Pages). Equatable on what it
/// shows, like the ⋯ menu, so a redraw of the screen does not rebuild it while it is open.
private struct TitleMenu: View, Equatable {
    var title: String
    var ar: Bool
    var actions: TitleMenuActions

    static func == (a: Self, b: Self) -> Bool { a.title == b.title && a.ar == b.ar }

    var body: some View {
        Menu {
            Button(action: actions.rename) { Label(BarText.rename(ar), systemImage: "pencil") }
                .accessibilityIdentifier("xr-title-rename")
            Button(action: actions.duplicate) { Label(BarText.duplicate(ar), systemImage: "plus.square.on.square") }
                .accessibilityIdentifier("xr-title-duplicate")
            Button(action: actions.move) { Label(BarText.move(ar), systemImage: "folder") }
                .accessibilityIdentifier("xr-title-move")
        } label: {
            // the whole title area is the target (at least 44 pt tall); what it shows is the title under it
            Color.clear
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(title)
        .accessibilityHint(BarText.titleMenuHint(ar))
        .accessibilityIdentifier("xr-bar-title-menu")
    }
}

/// The file name (17 pt semibold, neutral, cut in the middle so the start and the end stay readable) over a 12 pt
/// secondary line: Opening… while the page loads, Saving… during a save, Edited after changes, Saved only after a
/// completed save; nothing for a document just opened and unchanged.
private struct BarTitle: View {
    var title: String
    @ObservedObject var state: EditorState
    @ObservedObject var status: EditorBarStatus
    var ar: Bool
    /// The title opens the title menu: a small chevron after the name says so (as in Pages / Files).
    var menu = false
    /// With VoiceOver on, the title menu button over the name already reads it: the name itself is then hidden so it
    /// is not read twice (with VoiceOver off - as in the UI tests - it stays a readable text).
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    private var line: String? {
        if !status.ready { return BarText.opening(ar) }
        if status.saving { return BarText.saving(ar) }
        if !state.saved { return BarText.edited(ar) }
        if status.didSave { return BarText.saved(ar) }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("xr-bar-title")
                    .accessibilityHidden(menu && voiceOver)
                if menu {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            if let line {
                Text(line)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("xr-bar-status")
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)      // bars stay one bar tall
        .frame(maxWidth: 260)
    }
}

/// Undo / Redo: 44 pt targets, dimmed while there is nothing to undo / redo. Observes the editor state itself, so a
/// caret move never redraws the screen around it.
private struct UndoButton: View {
    @ObservedObject var state: EditorState
    var redo: Bool
    var ar: Bool
    var action: () -> Void

    var body: some View {
        let can = redo ? state.canRedo : state.canUndo
        Button(action: action) {
            Image(systemName: redo ? "arrow.uturn.forward" : "arrow.uturn.backward")
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .disabled(!can)     // the bar's own disabled tint: an extra opacity would dim it twice
        .accessibilityLabel(redo ? BarText.redo(ar) : BarText.undo(ar))
        .accessibilityIdentifier(redo ? "xr-bar-redo" : "xr-bar-undo")
    }
}

/// The ⋯ menu: section 1 (Find, Redo on iPhone, Save) and the screen's document menu (`more`). Equatable on what it
/// shows, so a redraw of the screen around it does not rebuild an open menu (the closures are the screen's own and
/// keep working: they reach its state through its storage).
private struct MoreMenu<More: View>: View, Equatable {
    var key: String
    var wide: Bool
    var ar: Bool
    /// Reading view (plan S2): no Redo here while reading (nothing can be edited).
    var reading: Bool
    var state: EditorState
    var find: (() -> Void)?
    var save: () -> Void
    var redo: () -> Void
    var more: () -> More

    static func == (a: Self, b: Self) -> Bool {
        a.key == b.key && a.wide == b.wide && a.ar == b.ar && a.reading == b.reading && (a.find == nil) == (b.find == nil)
            && a.state === b.state
    }

    var body: some View {
        Menu {
            Section {
                if let find {
                    Button(action: find) { Label(BarText.find(ar), systemImage: "magnifyingglass") }
                        .accessibilityIdentifier("xr-menu-find")
                }
                if !wide && !reading {
                    RedoMenuItem(state: state, ar: ar, action: redo)
                }
                Button(action: save) { Label(BarText.save(ar), systemImage: "square.and.arrow.down") }
                    .accessibilityIdentifier("xr-bar-save")
            }
            more()
        } label: {
            Image(systemName: "ellipsis.circle")
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(BarText.more(ar))
        .accessibilityIdentifier("xr-bar-more")
    }
}

/// Redo inside the ⋯ menu on compact widths (iPhone): the bar keeps only Undo there.
private struct RedoMenuItem: View {
    @ObservedObject var state: EditorState
    var ar: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) { Label(BarText.redo(ar), systemImage: "arrow.uturn.forward") }
            .disabled(!state.canRedo)
            .accessibilityIdentifier("xr-bar-redo")
    }
}
