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
    // Word only, for the Aa format sheet (plan S1): the font, size, strikethrough, paragraph style, line spacing and
    // text colour at the caret. "" / 0 / -1 = mixed or not known yet.
    @Published private(set) var fontName = ""
    @Published private(set) var fontSize = 0.0
    @Published private(set) var strikeout = false
    @Published private(set) var style = ""
    /// The line spacing as a multiple (1, 1.15, 1.5, 2 ...); -1 for exact / at-least spacing.
    @Published private(set) var lineSpacing = -1.0
    /// "auto" or "RRGGBB".
    @Published private(set) var textColor = ""
    /// Spreadsheets (plan S3): the selection's address as the name box shows it ("A1"), the selection's figures for
    /// the Sum capsule, and whether a cell is open for editing (the formula keys act on it).
    @Published private(set) var cell = ""
    @Published private(set) var math = SelectionMath.none
    @Published private(set) var cellEdit = false
    /// Presentations (plan S4): the slide count, the current slide (0-based), whether the slide show runs and the
    /// slide it shows. Other editors leave the defaults.
    @Published private(set) var slides = 0
    @Published private(set) var slide = 0
    @Published private(set) var presenting = false
    @Published private(set) var showSlide = 0
    /// Reading view (plan S2, Word / PDF): the page count, the page on screen (0-based) and whether a finger is moving
    /// the page - read by the editor only while reading, for the floating page capsule.
    @Published private(set) var pages = 0
    @Published private(set) var page = 0
    @Published private(set) var moving = false
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
            case "font": put(\.fontName, v as? String)
            case "size": put(\.fontSize, (v as? NSNumber)?.doubleValue)
            case "strike": put(\.strikeout, v as? Bool)
            case "style": put(\.style, v as? String)
            case "spacing": put(\.lineSpacing, (v as? NSNumber)?.doubleValue)
            case "color": put(\.textColor, v as? String)
            case "cell": put(\.cell, v as? String)
            case "math": put(\.math, (v as? String).map(SelectionMath.init(wire:)))
            case "cellEdit": put(\.cellEdit, v as? Bool)
            case "slides": put(\.slides, (v as? NSNumber)?.intValue)
            case "slide": put(\.slide, (v as? NSNumber)?.intValue)
            case "presenting": put(\.presenting, v as? Bool)
            case "showSlide": put(\.showSlide, (v as? NSNumber)?.intValue)
            case "pages": put(\.pages, (v as? NSNumber)?.intValue)
            case "page": put(\.page, (v as? NSNumber)?.intValue)
            case "moving": put(\.moving, v as? Bool)
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
        put(\.title, ""); put(\.fontName, ""); put(\.fontSize, 0); put(\.strikeout, false); put(\.style, "")
        put(\.lineSpacing, -1); put(\.textColor, ""); put(\.cell, ""); put(\.math, SelectionMath.none)
        put(\.cellEdit, false); put(\.updates, 0)
        put(\.slides, 0); put(\.slide, 0); put(\.presenting, false); put(\.showSlide, 0)
        put(\.pages, 0); put(\.page, 0); put(\.moving, false)
    }

    /// One line for logs and the CI probe, e.g. "undo:1 redo:0 mod:1 saved:0 sel:text b:0 i:0 u:0 al:left dir:rtl list:none
    /// sz:11 st:Heading_1 cell:- edit:0 cnt:0 n:4" (spaces in the style name become "_", so every value stays one word).
    var summary: String {
        func f(_ b: Bool) -> String { b ? "1" : "0" }
        return "undo:\(f(canUndo)) redo:\(f(canRedo)) mod:\(f(modified)) saved:\(f(saved)) sel:\(selection.rawValue) " +
            "b:\(f(bold)) i:\(f(italic)) u:\(f(underline)) al:\(alignment.rawValue) dir:\(direction.rawValue) " +
            "list:\(list.rawValue) sz:\(String(format: "%g", fontSize)) st:\(style.replacingOccurrences(of: " ", with: "_")) " +
            "cell:\(cell.isEmpty ? "-" : cell) edit:\(f(cellEdit)) cnt:\(math.count) n:\(updates)"
    }

    /// Sets a property only when the value really changed (an equal assignment would still notify every observer).
    private func put<T: Equatable>(_ key: ReferenceWritableKeyPath<EditorState, T>, _ value: T?) {
        guard let value, self[keyPath: key] != value else { return }
        self[keyPath: key] = value
    }
}

/// A spreadsheet selection's figures (plan S3), as the engine reports them for its status bar: the counts, and Sum,
/// Average, Min and Max as text in the cells' own number format (empty when the selection holds no numbers).
struct SelectionMath: Equatable {
    var count = 0          // non-empty cells
    var numbers = 0        // cells holding a number
    var sum = "", average = "", min = "", max = ""

    static let none = SelectionMath()

    /// The state channel's form: "count|numbers|sum|average|min|max".
    init(wire: String) {
        let p = wire.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        func at(_ i: Int) -> String { i < p.count ? p[i] : "" }
        count = Int(at(0)) ?? 0
        numbers = Int(at(1)) ?? 0
        sum = at(2); average = at(3); min = at(4); max = at(5)
    }

    init() {}

    /// The capsule shows for a selection of more than one cell with at least one number in it.
    var showsSum: Bool { count > 1 && numbers > 0 && !sum.isEmpty }
}
