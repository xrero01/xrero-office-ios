import SwiftUI
import UIKit
import WebKit

/// The formatting bar above the software keyboard in the Word editor (plan M5, phase 1): paragraph direction, Bold,
/// Italic, Underline, bullets, numbering, alignment and "hide keyboard", one thumb-tap away while typing. It replaces
/// WebKit's form bar (^ v Done), which does nothing useful for the editors' hidden input field.
///
/// How it is attached: XRWebView (below) overrides the public UIResponder.inputAccessoryView, which WebKit's content
/// view asks for before it falls back to its own form bar. Public API only: no WKContentView subclassing or
/// swizzling (App Review 2.5.1).
///
/// Typing safety: the bar only READS EditorState (the state channel posts at most one diff per frame, and only when a
/// value changed, so typing in one paragraph re-renders nothing), and a tap sends ONE EditorController.call into the
/// editor frame. A SwiftUI button in the keyboard's accessory never becomes first responder, so the web view keeps
/// the keyboard and the engine keeps its input field focused: the next letter goes where the caret was, with the
/// new format.
///
/// Flag: UserDefaults "xr.keyboardBar" (default OFF). The plan turns it on by default only after its gate: a green CI
/// run plus the real-device checks the simulator cannot do (Arabic predictive text, Japanese marked text, latency
/// with the bar shown). Until then it is switched on per run (`defaults write` / launch argument
/// `-xr.keyboardBar YES`, as the touch gate does). Off = WebKit's own bar, exactly as before.
struct KeyboardBar: View {
    static let height: CGFloat = 44
    static let flagKey = "xr.keyboardBar"
    /// Unset = off (see "Flag" above). bool(forKey:) also reads the launch-argument form ("-xr.keyboardBar YES"
    /// arrives as the STRING "YES", which `as? Bool` does not convert: seen on CI with "NO").
    static var enabled: Bool { UserDefaults.standard.bool(forKey: flagKey) }

    @ObservedObject var state: EditorState
    let controller: EditorController
    let ar: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                directionButton
                toggle("bold", on: state.bold, en: "Bold", arLabel: "غامق", id: "xr-kb-bold") {
                    "a.put_TextPrBold(\(!state.bold))"
                }
                toggle("italic", on: state.italic, en: "Italic", arLabel: "مائل", id: "xr-kb-italic") {
                    "a.put_TextPrItalic(\(!state.italic))"
                }
                toggle("underline", on: state.underline, en: "Underline", arLabel: "تسطير", id: "xr-kb-underline") {
                    "a.put_TextPrUnderline(\(!state.underline))"
                }
                // the same numbering info the editor's own Bullets / Numbering buttons send (Toolbar.onMarkers)
                toggle("list.bullet", on: state.list == .bullet, en: "Bulleted list", arLabel: "قائمة نقطية",
                       id: "xr-kb-bullets", mirrors: true) {
                    "a.put_ListTypeCustom('{\"Type\":\"\(state.list == .bullet ? "remove" : "bullet")\"}')"
                }
                toggle("list.number", on: state.list == .number, en: "Numbered list", arLabel: "قائمة رقمية",
                       id: "xr-kb-numbering", mirrors: true) {
                    "a.put_ListTypeCustom('{\"Type\":\"\(state.list == .number ? "remove" : "number")\"}')"
                }
                alignButton
                // Aa: everything else (font, size, style, colour, spacing, insert) in the format sheet (plan S1)
                Button { controller.showFormat() } label: { FormatGlyph() }
                    .accessibilityLabel(FormatText.format(ar))
                    .accessibilityHint(A11yText.formatHint(ar))
                    .accessibilityShowsLargeContentViewer()
                    .accessibilityIdentifier("xr-kb-format")
                Button { controller.hideKeyboard() } label: {
                    symbol("keyboard.chevron.compact.down", on: false)
                }
                .accessibilityLabel(ar ? "إخفاء لوحة المفاتيح" : "Hide keyboard")
                .accessibilityHint(A11yText.hideKeyboardHint(ar))
                .accessibilityShowsLargeContentViewer()
                .accessibilityIdentifier("xr-kb-hide")
            }
            .padding(.horizontal, 8)
        }
        .frame(height: Self.height)
        // 8 pt edge fade: says "more this way" when the bar overflows a narrow phone
        .mask {
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: 8)
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 8)
            }
        }
        .background {
            // glass over the keyboard; a solid surface when the user asked for less transparency
            if reduceTransparency { Color(uiColor: .secondarySystemBackground) } else { Rectangle().fill(.bar) }
        }
        .overlay(alignment: .top) {
            // 0.5 pt hairline; Increase Contrast: a 1 pt stronger line (S12)
            Rectangle().fill(contrast == .increased ? Color.primary.opacity(0.6) : Color(uiColor: .separator))
                .frame(height: contrast == .increased ? 1 : 0.5)
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        // Arabic: the whole order mirrors (the direction toggle stays in the leading slot = the right edge)
        .environment(\.layoutDirection, ar ? .rightToLeft : .leftToRight)
    }

    // MARK: buttons

    /// Paragraph direction: always the leading slot, showing the CURRENT direction (pilcrow + arrow, drawn the same
    /// in both languages: a direction glyph must never be mirrored).
    private var directionButton: some View {
        let rtl = state.direction == .rtl
        return Button { run("direction", "a.asc_setRtlTextDirection(\(!rtl))") } label: {
            HStack(spacing: 1) {
                if rtl { Image(systemName: "arrow.left").font(.system(size: 12, weight: .bold)) }
                Image(systemName: "paragraphsign").font(.system(size: 22, weight: .regular))
                if !rtl { Image(systemName: "arrow.right").font(.system(size: 12, weight: .bold)) }
            }
            .environment(\.layoutDirection, .leftToRight)
            .foregroundStyle(Color.primary)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(ar ? "اتجاه الفقرة" : "Paragraph direction")
        .accessibilityShowsLargeContentViewer()
        .accessibilityValue(rtl ? (ar ? "من اليمين إلى اليسار" : "Right to left")
                                : (ar ? "من اليسار إلى اليمين" : "Left to right"))
        .accessibilityIdentifier("xr-kb-direction")
    }

    /// Alignment cycles start -> centre -> end -> start, where start is the paragraph's own reading edge (right in a
    /// right-to-left paragraph). The engine is asymmetric here, so both directions are read from its source:
    ///  - put_PrAlign takes the VISUAL edge: Paragraph.SetParagraphAlign swaps align_Left / align_Right for a
    ///    right-to-left paragraph before storing it (the ribbon's Align Right always sends align_Right);
    ///  - asc_onPrAlign (EditorState.alignment) reports the STORED, logical edge: "left" = start, "right" = end, also
    ///    in a right-to-left paragraph (Toolbar.onApiParagraphAlign presses Align Right for align_Left there).
    /// So the cycle reads the logical state, sends the visual edge, and the glyph shows the visual edge unmirrored
    /// (both seen on CI in Arabic: a right-aligned paragraph reported "left"; sending the logical value went back).
    private var alignButton: some View {
        let rtl = state.direction == .rtl
        // AscCommon.align_Left = 1, align_Center = 2, align_Right = 0, as visual edges for put_PrAlign
        let center = 2, start = rtl ? 0 : 1, end = rtl ? 1 : 0
        let next: Int
        switch state.alignment {
        case .center: next = end
        case .right: next = start                               // at the end: back to the start
        default: next = center                                  // start / justify / none: centre comes next
        }
        // the visual edge: in a right-to-left paragraph the start is on the right
        enum Edge { case left, right, center, justify }
        let edge: Edge
        switch state.alignment {
        case .center: edge = .center
        case .justify, .distributed: edge = .justify
        case .right: edge = rtl ? .left : .right
        case .left, .none: edge = rtl ? .right : .left
        }
        let glyph: String
        let value: String
        switch edge {
        case .center: glyph = "text.aligncenter"; value = ar ? "توسيط" : "Centre"
        case .justify: glyph = "text.justify"; value = ar ? "ضبط" : "Justified"
        case .right: glyph = "text.alignright"; value = ar ? "إلى اليمين" : "Right"
        case .left: glyph = "text.alignleft"; value = ar ? "إلى اليسار" : "Left"
        }
        return Button { run("align", "a.put_PrAlign(\(next))") } label: {
            symbol(glyph, on: false).environment(\.layoutDirection, .leftToRight)
        }
        .accessibilityLabel(ar ? "المحاذاة" : "Alignment")
        .accessibilityShowsLargeContentViewer()
        .accessibilityValue(value)
        .accessibilityHint(ar ? "يبدّل بين البداية والوسط والنهاية" : "Cycles start, centre and end")
        .accessibilityIdentifier("xr-kb-align")
    }

    /// A format toggle (B / I / U / lists): the active state is a 32 pt rounded square in the document accent at 15 %
    /// with the symbol in the accent. `mirrors`: list glyphs follow the reading direction; B / I / U never do.
    private func toggle(_ name: String, on: Bool, en: String, arLabel: String, id: String, mirrors: Bool = false,
                        _ js: @escaping () -> String) -> some View {
        Button { run(id, js()) } label: {
            symbol(name, on: on)
                .environment(\.layoutDirection, mirrors && ar ? .rightToLeft : .leftToRight)
        }
        .accessibilityLabel(ar ? arLabel : en)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityShowsLargeContentViewer()
        .accessibilityIdentifier(id)
    }

    private func symbol(_ name: String, on: Bool) -> some View {
        Image(systemName: name)
            .font(.system(size: 22, weight: on ? .semibold : .regular))      // plan: 22 pt symbols
            .foregroundStyle(on ? Color.xrDocument : Color.primary)
            .frame(width: 32, height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(on ? Color.xrDocument.opacity(0.15) : .clear))
            .frame(width: 44, height: 44)                       // 44 pt touch target
            .contentShape(Rectangle())
    }

    /// One bridge call per tap, through EditorController.call (the editor frame, where __xrApi lives). The editor
    /// log gets one line per tap (CI reads it); never anything per keystroke.
    private func run(_ name: String, _ js: String) {
        controller.format("keyboard bar", name, js)
    }
}

/// The keyboard accessory's UIKit container: a fixed 44 pt row the width of the keyboard, hosting KeyboardBar.
final class KeyboardBarHost: UIView {
    private let hosting: UIHostingController<KeyboardBar>

    init(_ bar: KeyboardBar) {
        hosting = UIHostingController(rootView: bar)
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: KeyboardBar.height))
        autoresizingMask = [.flexibleWidth]
        backgroundColor = .clear
        hosting.safeAreaRegions = []                            // the keyboard window's insets are not the bar's
        let v: UIView = hosting.view
        v.backgroundColor = .clear
        v.frame = bounds
        v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(v)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: KeyboardBar.height) }

    var bar: KeyboardBar {
        get { hosting.rootView }
        set { hosting.rootView = newValue }
    }
}

/// The editor's web view. Its only addition: the keyboard accessory is the app's KeyboardBar when one is set (Word,
/// flag on). WebKit's content view - the real first responder - asks the web view's inputAccessoryView first and
/// shows its own form bar only when that is nil, so `nil` here (no bar set, or iPhone landscape) is WebKit's
/// behaviour unchanged.
final class XRWebView: WKWebView {
    /// KeyboardBarHost (Word) or SheetKeyBarHost (spreadsheets, plan S3)
    var keyboardBar: UIView?

    /// The native edit menu's anchor (plan S5, EditMenu.swift): a transparent, touch-transparent view over the whole
    /// web view, added on first use so a document that never shows the menu has no extra view.
    var editMenuAnchor: EditMenuAnchor {
        if let a = anchor { return a }
        let a = EditMenuAnchor(frame: bounds)
        a.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(a)
        anchor = a
        return a
    }
    private var anchor: EditMenuAnchor?

    /// Called each time the view enters a window: EditorWebView loads the editor page only then, because the page's
    /// layout (compact / regular, plan S6) is chosen from the window's width.
    var onWindow: (() -> Void)?

    /// The menu bar's view of this editor (plan S6, MenuBarTargets; EditorWebView sets these): registered while this
    /// view is in a window, so File > Close / Edit > Find / Format > Bold act on the window's open editor - and on
    /// nothing once it has closed.
    weak var menuController: EditorController?
    var menuKind: OfficeKind?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let c = menuController, let k = menuKind {
            if window != nil { MenuBarTargets.shared.editorShown(self, controller: c, kind: k) }
            else { MenuBarTargets.shared.editorHidden(self) }
        }
        if window != nil { onWindow?() }
    }

    /// ⌘B / ⌘I / ⌘U while the editor holds the keyboard (plan S6; Word - EditorWebView sets this). The editor page does
    /// not reliably get these chords on iOS: CI runs 142 and 152 (a key spy in the page) saw no ⌘B arrive on the
    /// iPhone at all and only every other one on the iPad - UIKit's text system takes them first. So the editor view
    /// owns them as key commands: each press runs the engine's Bold / Italic / Underline once (the keyboard bar's own
    /// call), and a matched key command is not delivered on to the page, so there is no second toggle. While the focus
    /// is in one of the editor's own text boxes (Find & Replace, a comment, the font size) the press does nothing
    /// (xr-host.js __xrToggle): it must not format the document behind the box. The menu bar's Format items carry no
    /// key equivalent: nothing else claims these keys. Only on a key press - typing never reaches this (UIKit asks for
    /// the list on a key event; it is built once).
    var formatKey: ((String) -> Void)? { didSet { formatKeyCommands = nil } }
    /// The commands' names in the ⌘-hold shortcut list (the editor's language).
    var formatKeyTitles: [String: String] = [:] { didSet { formatKeyCommands = nil } }
    private var formatKeyCommands: [UIKeyCommand]?

    override var keyCommands: [UIKeyCommand]? {
        guard formatKey != nil else { return super.keyCommands }
        if formatKeyCommands == nil {
            formatKeyCommands = [("b", "bold"), ("i", "italic"), ("u", "underline")].map { key, name in
                let c = UIKeyCommand(title: formatKeyTitles[name] ?? name, action: #selector(formatKeyPressed(_:)),
                                     input: key, modifierFlags: .command, propertyList: name)
                c.wantsPriorityOverSystemBehavior = true      // ahead of the text system's own handling of the chord
                return c
            }
        }
        return (super.keyCommands ?? []) + (formatKeyCommands ?? [])
    }

    @objc private func formatKeyPressed(_ sender: UIKeyCommand) {
        if let name = sender.propertyList as? String { formatKey?(name) }
    }

    override var inputAccessoryView: UIView? {
        guard let bar = keyboardBar else { return super.inputAccessoryView }
        // iPhone landscape (under 400 pt tall): the document needs every point; WebKit's slim bar keeps its Done
        if isShort { return super.inputAccessoryView }
        return bar
    }

    private var isShort: Bool { (window?.bounds.height ?? .greatestFiniteMagnitude) < 400 }
    private var lastShort: Bool?

    /// The accessory is only asked for when the keyboard comes up, so a rotation with the keyboard up would keep the
    /// wrong bar until the next focus. When the <400 pt answer flips while the editor holds the keyboard, ask the
    /// current first responder (WebKit's content view, our subview) to reload its input views. Public API only.
    override func layoutSubviews() {
        super.layoutSubviews()
        guard keyboardBar != nil, window != nil else { return }
        let short = isShort
        defer { lastShort = short }
        guard let was = lastShort, was != short else { return }
        if let responder = XRWebView.firstResponder(in: self) { responder.reloadInputViews() }
    }

    /// The first responder inside `view` (WebKit's content view while the editor holds the keyboard), or nil.
    static func firstResponder(in view: UIView) -> UIView? {
        if view.isFirstResponder { return view }
        for sub in view.subviews { if let r = firstResponder(in: sub) { return r } }
        return nil
    }
}
