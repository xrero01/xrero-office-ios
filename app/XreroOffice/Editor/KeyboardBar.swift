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
/// Flag: UserDefaults "xr.keyboardBar" (default on). Off = WebKit's own bar comes back exactly as before (rollback
/// without a new build: `defaults write` / launch argument `-xr.keyboardBar NO`).
struct KeyboardBar: View {
    static let height: CGFloat = 44
    static let flagKey = "xr.keyboardBar"
    static var enabled: Bool { UserDefaults.standard.object(forKey: flagKey) as? Bool ?? true }

    @ObservedObject var state: EditorState
    let controller: EditorController
    let ar: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

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
                // "Aa" (the text-format sheet, plan S1) joins here once that sheet exists: no button without a binding
                Button { controller.hideKeyboard() } label: {
                    symbol("keyboard.chevron.compact.down", on: false)
                }
                .accessibilityLabel(ar ? "إخفاء لوحة المفاتيح" : "Hide keyboard")
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
            Rectangle().fill(Color(uiColor: .separator)).frame(height: 0.5)     // 0.5 pt hairline
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
                Image(systemName: "paragraphsign").font(.system(size: 20, weight: .regular))
                if !rtl { Image(systemName: "arrow.right").font(.system(size: 12, weight: .bold)) }
            }
            .environment(\.layoutDirection, .leftToRight)
            .foregroundStyle(Color.primary)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(ar ? "اتجاه الفقرة" : "Paragraph direction")
        .accessibilityValue(rtl ? (ar ? "من اليمين إلى اليسار" : "Right to left")
                                : (ar ? "من اليسار إلى اليمين" : "Left to right"))
        .accessibilityIdentifier("xr-kb-direction")
    }

    /// Alignment cycles start -> centre -> end -> start, where start is the paragraph's own reading edge (right in a
    /// right-to-left paragraph). The engine stores the LOGICAL edge: AscCommon.align_Left (1) is the start and
    /// align_Right (0) the end, also in a right-to-left paragraph (the editor's own ribbon reads it that way:
    /// Toolbar.onApiParagraphAlign shows Align Right pressed for 1 when the paragraph is right-to-left). So the cycle
    /// sends the logical values and the glyph shows the VISUAL edge, unmirrored (seen on CI: a right-aligned Arabic
    /// paragraph reported "left").
    private var alignButton: some View {
        let rtl = state.direction == .rtl
        let start = 1, center = 2, end = 0                      // AscCommon.align_Left / align_Center / align_Right
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
        .accessibilityIdentifier(id)
    }

    private func symbol(_ name: String, on: Bool) -> some View {
        Image(systemName: name)
            .font(.system(size: 20, weight: on ? .semibold : .regular))
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
        controller.call("var a=window.__xrApi;if(!a)return 'no editor api';" + js +
                        ";if(window.XreroHost)XreroHost.log('keyboard bar: \(name)');return 'ok';") { r, e in
            if (r as? String) != "ok" { NSLog("XR keyboard bar %@: %@", name, (r as? String) ?? e ?? "?") }
        }
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
    var keyboardBar: KeyboardBarHost?

    override var inputAccessoryView: UIView? {
        guard let bar = keyboardBar else { return super.inputAccessoryView }
        // iPhone landscape (under 400 pt tall): the document needs every point; WebKit's slim bar keeps its Done
        if let h = window?.bounds.height, h < 400 { return super.inputAccessoryView }
        return bar
    }
}
