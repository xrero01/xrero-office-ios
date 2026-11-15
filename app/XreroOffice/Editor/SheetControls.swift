import SwiftUI
import UIKit

// Spreadsheets on the phone (plan S3): "what's the total?" with no typing, and the symbols a formula needs next to
// the keyboard.
//  - SumCapsule: selecting more than one cell with a number in it shows "Sum 1,288" / "المجموع 1,288" over the
//    sheet's bottom bar; a tap opens SumSheet (Sum, Average, Min, Max, Count, each with "Insert below").
//  - SheetKeyBar: the M5 keyboard row for spreadsheets: = Σ ( ) : , ⇥, then ✕ ✓ and "hide keyboard" pinned at the
//    trailing end. Behind the same flag as the Word bar (KeyboardBar.flagKey, default OFF until its gate).
//  - The A1 chip (the name box) and the 44 pt formula bar are the editor's own fields, restyled in web/xr-host.js
//    (sheetTouch), so the address typed into the chip and the formula bar keep the editor's own behaviour.
// Typing safety: everything here only READS EditorState (diffed in xr-host.js, one post per frame at most) and sends
// one EditorController.call per tap. Nothing runs per keystroke.

/// The capsule over the sheet, plus its sheet. Applied to the editor in EditorScreen (and the CI screen) for
/// spreadsheets only. The modifier itself observes nothing: only SumCapsuleSlot follows the state, so a selection
/// change redraws the capsule and never the editor screen or its top bar (a redraw there kills an open ⋯ menu).
struct SheetSumOverlay: ViewModifier {
    let kind: OfficeKind
    let state: EditorState
    let controller: EditorController
    let ar: Bool

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottomTrailing) {
            if kind == .cell { SumCapsuleSlot(state: state, controller: controller, ar: ar) }
        }
    }
}

private struct SumCapsuleSlot: View {
    @ObservedObject var state: EditorState
    let controller: EditorController
    let ar: Bool
    @State private var showSheet = false

    var body: some View {
        ZStack {
            if state.math.showsSum {
                SumCapsule(math: state.math, ar: ar) { showSheet = true }
                    // above the editor's 50 pt bottom bar (sheet tabs), clear of the toast's place in the centre
                    .padding(.trailing, 12)
                    .padding(.bottom, 58)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: state.math.showsSum)
        .sheet(isPresented: $showSheet) {
            SumSheet(state: state, ar: ar) { fn in
                showSheet = false
                controller.call("return window.__xrCellFunc ? __xrCellFunc('\(fn)') : 'no cell function';") { r, e in
                    if (r as? String) != "ok" { NSLog("XR sum insert %@: %@", fn, (r as? String) ?? e ?? "?") }
                }
            }
            .presentationDetents([.height(380), .large])
            .presentationDragIndicator(.visible)
            .environment(\.layoutDirection, ar ? .rightToLeft : .leftToRight)
        }
    }
}

extension View {
    /// The spreadsheet's Sum capsule and sheet (plan S3); nothing for the other kinds.
    func sheetSum(kind: OfficeKind, state: EditorState, controller: EditorController, ar: Bool) -> some View {
        modifier(SheetSumOverlay(kind: kind, state: state, controller: controller, ar: ar))
    }
}

/// Figures for people: a plain number from the engine ("1288", "429.3333333") gets digit grouping and at most two
/// decimals, with Western digits in both languages (plan: Western digits by default). Anything else - a date, a
/// currency, a percentage in the cells' own format - is shown exactly as the engine wrote it.
enum SheetNumber {
    static func format(_ s: String, ar: Bool) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, let v = Double(t), v.isFinite else { return s }
        let f = NumberFormatter()
        f.locale = Locale(identifier: ar ? "ar@numbers=latn" : "en_US")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.maximumFractionDigits = 2
        f.minimumFractionDigits = 0
        return f.string(from: NSNumber(value: v)) ?? s
    }
}

/// "Sum 1,288": 36 pt high, material capsule with a hairline (solid under Reduce Transparency).
struct SumCapsule: View {
    let math: SelectionMath
    let ar: Bool
    let open: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let label = ar ? "المجموع" : "Sum"
        let value = SheetNumber.format(math.sum, ar: ar)
        Button(action: open) {
            HStack(spacing: 6) {
                Text(label).foregroundStyle(.secondary)
                Text(value).foregroundStyle(.primary).monospacedDigit()
                    .environment(\.layoutDirection, .leftToRight)       // digits are never mirrored
                Image(systemName: "chevron.up").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            }
            .font(.system(size: 15, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background {
                if reduceTransparency { Capsule().fill(Color(uiColor: .secondarySystemBackground)) }
                else { Capsule().fill(.regularMaterial) }
            }
            .overlay(Capsule().strokeBorder(Color(uiColor: .separator), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            .frame(minHeight: 44)                                       // 44 pt touch target
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .accessibilityLabel("\(label) \(value)")
        .accessibilityHint(ar ? "يعرض المتوسط والأصغر والأكبر والعدد" : "Shows average, minimum, maximum and count")
        .accessibilityIdentifier("xr-sum")
    }
}

/// The selection's figures, each with "Insert below": the formula goes into the cell under the selected range (the
/// engine's AutoSum path), so the answer can stay in the sheet.
struct SumSheet: View {
    @ObservedObject var state: EditorState
    let ar: Bool
    let insert: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    private struct Row: Identifiable {
        let id: String          // also the accessibility identifier's end
        let fn: String          // the function "Insert below" writes
        let en: String, ar: String
        let value: String
    }

    private var rows: [Row] {
        let m = state.math
        var r: [Row] = []
        if !m.sum.isEmpty { r.append(Row(id: "sum", fn: "SUM", en: "Sum", ar: "المجموع", value: m.sum)) }
        if !m.average.isEmpty { r.append(Row(id: "average", fn: "AVERAGE", en: "Average", ar: "المتوسط", value: m.average)) }
        if !m.min.isEmpty { r.append(Row(id: "min", fn: "MIN", en: "Min", ar: "الأصغر", value: m.min)) }
        if !m.max.isEmpty { r.append(Row(id: "max", fn: "MAX", en: "Max", ar: "الأكبر", value: m.max)) }
        // the engine's Count is every filled cell, which COUNTA gives back
        r.append(Row(id: "count", fn: "COUNTA", en: "Count", ar: "العدد", value: String(m.count)))
        return r
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(rows) { row in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ar ? row.ar : row.en).font(.subheadline).foregroundStyle(.secondary)
                                Text(SheetNumber.format(row.value, ar: ar))
                                    .font(.title3.weight(.semibold)).monospacedDigit()
                                    .environment(\.layoutDirection, .leftToRight)
                                    .accessibilityIdentifier("xr-sum-value-" + row.id)
                            }
                            Spacer(minLength: 8)
                            Button { insert(row.fn) } label: {
                                Text(ar ? "إدراج أسفل" : "Insert below")
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 12)
                                    .frame(minHeight: 36)
                            }
                            .buttonStyle(.bordered)
                            .frame(minHeight: 44)
                            .accessibilityLabel(ar ? "إدراج \(row.ar) أسفل التحديد" : "Insert \(row.en.lowercased()) below the selection")
                            .accessibilityIdentifier("xr-sum-insert-" + row.id)
                        }
                        .padding(.vertical, 2)
                    }
                } footer: {
                    Text(ar ? "\(state.math.count) خلايا محددة" : "\(state.math.count) cells selected")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(ar ? "التحديد" : "Selection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(ar ? "تم" : "Done") { dismiss() }.accessibilityIdentifier("xr-sum-done")
                }
            }
        }
        .accessibilityIdentifier("xr-sum-sheet")
    }
}

/// The spreadsheet's keyboard row (plan M5 "Excel" + S3): = Σ ( ) : , ⇥ scroll; ✕ ✓ and "hide keyboard" stay at the
/// trailing end so commit / cancel are always one tap away on a narrow phone. Same look as the Word bar (44 pt,
/// glass or solid, 0.5 pt hairline, 44 pt keys). The symbol keys go into the open cell editor at its cursor
/// (xr-host.js __xrCellKey); with no cell open they are typed through the keyboard path, which starts an edit like any
/// typed letter.
struct SheetKeyBar: View {
    @ObservedObject var state: EditorState
    let controller: EditorController
    let ar: Bool
    /// types text through the web view's own keyboard input (UIKeyInput), for a key pressed with no cell open
    let typeKey: (String) -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    key("=", id: "equals", en: "Equals", arLabel: "يساوي", send: "=")
                    symbolKey("sum", id: "sum", en: "AutoSum", arLabel: "جمع تلقائي", send: "sum")
                    key("(", id: "open", en: "Open parenthesis", arLabel: "قوس فتح", send: "(")
                    key(")", id: "close", en: "Close parenthesis", arLabel: "قوس إغلاق", send: ")")
                    key(":", id: "colon", en: "Range colon", arLabel: "نقطتان للنطاق", send: ":")
                    key(",", id: "sep", en: "Argument separator", arLabel: "فاصل الوسائط", send: "sep")
                    symbolKey("arrow.right.to.line", id: "tab", en: "Next cell", arLabel: "الخلية التالية", send: "tab",
                              mirrors: true)
                }
                .padding(.horizontal, 8)
            }
            // 8 pt edge fade: says "more this way" when the row overflows a narrow phone
            .mask {
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: 8)
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 8)
                }
            }
            Rectangle().fill(Color(uiColor: .separator)).frame(width: 0.5, height: 28)
            HStack(spacing: 4) {
                symbolKey("xmark", id: "cancel", en: "Cancel edit", arLabel: "إلغاء التعديل", send: "cancel")
                symbolKey("checkmark", id: "commit", en: "Enter", arLabel: "إدخال", send: "commit", accent: true)
                Button { controller.hideKeyboard() } label: { glyph(Image(systemName: "keyboard.chevron.compact.down")) }
                    .accessibilityLabel(ar ? "إخفاء لوحة المفاتيح" : "Hide keyboard")
                    .accessibilityIdentifier("xr-fk-hide")
            }
            .padding(.horizontal, 6)
        }
        .frame(height: KeyboardBar.height)
        .background {
            if reduceTransparency { Color(uiColor: .secondarySystemBackground) } else { Rectangle().fill(.bar) }
        }
        .overlay(alignment: .top) {
            Rectangle().fill(Color(uiColor: .separator)).frame(height: 0.5)
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        // Arabic: the order mirrors; the symbols themselves do not (a parenthesis keeps its meaning in a formula)
        .environment(\.layoutDirection, ar ? .rightToLeft : .leftToRight)
    }

    /// A key that shows the character it inserts.
    private func key(_ text: String, id: String, en: String, arLabel: String, send: String) -> some View {
        Button { press(send) } label: {
            glyph(Text(text).font(.system(size: 22, weight: .medium, design: .monospaced)))
        }
        .accessibilityLabel(ar ? arLabel : en)
        .accessibilityIdentifier("xr-fk-" + id)
    }

    private func symbolKey(_ name: String, id: String, en: String, arLabel: String, send: String, mirrors: Bool = false,
                           accent: Bool = false) -> some View {
        Button { press(send) } label: {
            glyph(Image(systemName: name).font(.system(size: 20, weight: accent ? .semibold : .regular))
                .flipsForRightToLeftLayoutDirection(true)
                .environment(\.layoutDirection, mirrors && ar ? .rightToLeft : .leftToRight), accent: accent)
        }
        .accessibilityLabel(ar ? arLabel : en)
        .accessibilityIdentifier("xr-fk-" + id)
    }

    /// 32 pt key face (a light fill, so the row reads as keys) inside a 44 pt touch target; the commit key carries
    /// the spreadsheet accent, the editor's single primary action here.
    private func glyph<V: View>(_ v: V, accent: Bool = false) -> some View {
        v.foregroundStyle(accent ? Color.xrSpreadsheet : Color.primary)
            .environment(\.layoutDirection, .leftToRight)
            .frame(width: 36, height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(accent ? Color.xrSpreadsheet.opacity(0.15) : Color(uiColor: .tertiarySystemFill)))
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    /// One bridge call per tap; a symbol pressed with no cell open is typed instead (it opens the cell as a typed
    /// letter would). One log line per tap (CI reads it), never anything per keystroke.
    private func press(_ k: String) {
        let arg = k.replacingOccurrences(of: "'", with: "")
        controller.call("var r=window.__xrCellKey?__xrCellKey('\(arg)'):'no cell keys';" +
                        "if(window.XreroHost)XreroHost.log('sheet keys: \(arg) -> '+r);return r;") { r, e in
            let res = (r as? String) ?? e ?? "?"
            if res.hasPrefix("not editing:") {
                typeKey(String(res.dropFirst("not editing:".count)))
            } else if res != "ok" {
                NSLog("XR sheet key %@: %@", k, res)
            }
        }
    }
}

/// The keyboard accessory's UIKit container for SheetKeyBar (as KeyboardBarHost is for the Word bar).
final class SheetKeyBarHost: UIView {
    private let hosting: UIHostingController<SheetKeyBar>

    init(_ bar: SheetKeyBar) {
        hosting = UIHostingController(rootView: bar)
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: KeyboardBar.height))
        autoresizingMask = [.flexibleWidth]
        backgroundColor = .clear
        hosting.safeAreaRegions = []
        let v: UIView = hosting.view
        v.backgroundColor = .clear
        v.frame = bounds
        v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(v)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: KeyboardBar.height) }

    var bar: SheetKeyBar {
        get { hosting.rootView }
        set { hosting.rootView = newValue }
    }
}

extension XRWebView {
    /// Types `text` the way the keyboard does: into the first responder inside the web view (WebKit's content view,
    /// found through the public subview tree) through the public UIKeyInput protocol. On a tap only.
    func typeAsKeyboard(_ text: String) {
        func find(_ v: UIView) -> UIView? {
            if v.isFirstResponder { return v }
            for s in v.subviews { if let r = find(s) { return r } }
            return nil
        }
        (find(self) as? UIKeyInput)?.insertText(text)
    }
}
