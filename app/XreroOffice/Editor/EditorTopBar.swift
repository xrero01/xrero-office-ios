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
/// The ⋯ menu (plan M7b) starts with Find, Redo (compact width) and Save; the screen adds the rest of the document
/// menu (`more` = DocumentMenuItems: Share, Export, Document info, Language, Account, About, All tools).
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
                    BarTitle(title: title, state: state, status: status, ar: ar)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    UndoButton(state: state, redo: false, ar: ar) { undo(false) }
                    if wide { UndoButton(state: state, redo: true, ar: ar) { undo(true) } }
                    Menu {
                        // section 1 of the document menu (plan M7b): Find, Redo on iPhone, Save; `more` adds the rest
                        Section {
                            if let find {
                                Button(action: find) { Label(BarText.find(ar), systemImage: "magnifyingglass") }
                                    .accessibilityIdentifier("xr-menu-find")
                            }
                            if !wide {
                                RedoMenuItem(state: state, ar: ar) { undo(true) }
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
    }

    private func undo(_ redo: Bool) {
        controller.call("return window.__xrUndo ? __xrUndo(\(redo)) : 'no editor';")
    }
}

extension View {
    func editorTopBar<More: View>(title: String, state: EditorState, status: EditorBarStatus, controller: EditorController,
                                  ar: Bool, back: @escaping () -> Void, save: @escaping () -> Void,
                                  find: (() -> Void)? = nil,
                                  @ViewBuilder more: @escaping () -> More) -> some View {
        modifier(EditorTopBar(title: title, state: state, status: status, controller: controller, ar: ar,
                              back: back, save: save, find: find, more: more))
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
}

/// The file name (17 pt semibold, neutral, cut in the middle so the start and the end stay readable) over a 12 pt
/// secondary line: Opening… while the page loads, Saving… during a save, Edited after changes, Saved only after a
/// completed save; nothing for a document just opened and unchanged.
private struct BarTitle: View {
    var title: String
    @ObservedObject var state: EditorState
    @ObservedObject var status: EditorBarStatus
    var ar: Bool

    private var line: String? {
        if !status.ready { return BarText.opening(ar) }
        if status.saving { return BarText.saving(ar) }
        if !state.saved { return BarText.edited(ar) }
        if status.didSave { return BarText.saved(ar) }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityIdentifier("xr-bar-title")
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
