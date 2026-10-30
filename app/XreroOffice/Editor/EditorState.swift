import Foundation

/// The open editor's state for the app's own controls (top bar, keyboard bar, menus): what can be undone, whether the
/// document changed, what is selected and how the text there is formatted.
///
/// Fed by the state channel in web/xr-host.js ("hub"): engine callbacks there are diffed and coalesced, and at most
/// one JSON object of CHANGED keys per animation frame arrives as the "state" message (EditorWebView.Coordinator),
/// which calls apply(_:). Owned by EditorController (controller.state); a view that shows it observes it directly:
///
///     struct UndoButton: View {
///         @ObservedObject var state: EditorState
///         var controller: EditorController
///         var body: some View {
///             Button { controller.call("__xrApi.Undo()") } label: { Image(systemName: "arrow.uturn.backward") }
///                 .disabled(!state.canUndo)
///         }
///     }
///
/// Values are the engine's at the caret; an editor that has no such notion (spreadsheets have no list or direction)
/// leaves the default. Keys here and in xr-host.js must stay the same.
final class EditorState: ObservableObject {
    enum Selection: String { case none, text, table, image, shape, chart, equation, header, slide, cells }
    /// The engine's paragraph alignment as stored (not mirrored for right-to-left: read it with `direction`).
    enum Alignment: String { case none, left, center, right, justify, distributed }
    enum ListKind: String { case none, bullet, number }
    enum Direction: String { case ltr, rtl }

    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    /// The engine's "document modified" mark.
    @Published private(set) var modified = false
    /// The file holds the document as it is on screen (true after open and after each completed save).
    @Published private(set) var saved = true
    @Published private(set) var selection = Selection.none
    @Published private(set) var bold = false
    @Published private(set) var italic = false
    @Published private(set) var underline = false
    @Published private(set) var alignment = Alignment.none
    @Published private(set) var direction = Direction.ltr
    @Published private(set) var list = ListKind.none
    @Published private(set) var title = ""
    /// How many state messages have arrived since the editor page loaded (tests, diagnostics).
    @Published private(set) var updates = 0

    /// Applies one diff from the state channel: a JSON object of changed keys. Unknown keys and values are ignored
    /// (an older app with a newer xr-host.js keeps working). O(keys in the diff).
    func apply(_ json: String) {
        guard let d = json.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return }
        for (k, v) in o {
            switch k {
            case "canUndo": put(\.canUndo, v as? Bool)
            case "canRedo": put(\.canRedo, v as? Bool)
            case "modified": put(\.modified, v as? Bool)
            case "saved": put(\.saved, v as? Bool)
            case "bold": put(\.bold, v as? Bool)
            case "italic": put(\.italic, v as? Bool)
            case "underline": put(\.underline, v as? Bool)
            case "selection": put(\.selection, (v as? String).flatMap(Selection.init(rawValue:)))
            case "align": put(\.alignment, (v as? String).flatMap(Alignment.init(rawValue:)))
            case "direction": put(\.direction, (v as? String).flatMap(Direction.init(rawValue:)))
            case "list": put(\.list, (v as? String).flatMap(ListKind.init(rawValue:)))
            case "title": put(\.title, v as? String)
            default: break
            }
        }
        updates += 1
    }

    /// Back to the defaults (the editor page is being loaded again).
    func reset() {
        put(\.canUndo, false); put(\.canRedo, false); put(\.modified, false); put(\.saved, true)
        put(\.selection, Selection.none); put(\.bold, false); put(\.italic, false); put(\.underline, false)
        put(\.alignment, Alignment.none); put(\.direction, Direction.ltr); put(\.list, ListKind.none)
        put(\.title, ""); put(\.updates, 0)
    }

    /// One line for logs and the CI probe, e.g. "undo:1 redo:0 mod:1 saved:0 sel:text b:0 i:0 u:0 al:left dir:rtl list:none n:4".
    var summary: String {
        func f(_ b: Bool) -> String { b ? "1" : "0" }
        return "undo:\(f(canUndo)) redo:\(f(canRedo)) mod:\(f(modified)) saved:\(f(saved)) sel:\(selection.rawValue) " +
            "b:\(f(bold)) i:\(f(italic)) u:\(f(underline)) al:\(alignment.rawValue) dir:\(direction.rawValue) " +
            "list:\(list.rawValue) n:\(updates)"
    }

    /// Sets a property only when the value really changed (an equal assignment would still notify every observer).
    private func put<T: Equatable>(_ key: ReferenceWritableKeyPath<EditorState, T>, _ value: T?) {
        guard let value, self[keyPath: key] != value else { return }
        self[keyPath: key] = value
    }
}
