import SwiftUI
import UIKit
import CoreText

/// The Aa format sheet for Word text (plan S1): style, font, size, Bold / Italic / Underline / Strikethrough, text
/// colour and highlight (Text); direction, alignment, lists, indent and line spacing (Paragraph); table, photo and page
/// break (Insert); and "All tools" for everything else. It replaces the ribbon's desktop comboboxes with large rows
/// at thumb height while the text stays visible above it. Spreadsheets and slides keep their ribbon for now.
///
/// iPhone: a sheet with detents [320 pt, large], a drag indicator, and the page above it still usable (background
/// interaction up to 320 pt). iPad: the same content as a 375 pt popover under the top bar's Aa.
///
/// Reads EditorState (the state channel, plan F0) and writes through EditorController.format, one bridge call per tap
/// (never per keystroke). Opening and closing go through EditorController.showFormat / formatClosed: the sheet never
/// opens over a word still being composed, it opens with the keyboard down, and closing gives the keyboard and the
/// caret back (M14 rule, checked by the touch gate).
final class FormatSheetModel: ObservableObject {
    @Published var shown = false
    /// false when the sheet closes for something that takes the screen next (photo picker, All tools) or inserts a
    /// table / page break: the keyboard then stays down instead of flashing up behind the next screen.
    var restoreKeyboard = true
    /// Opened while the keyboard was up: the sheet is then modal (dimmed, no background interaction), so UIKit hides
    /// the keyboard for it and gives it back on dismissal - its own input-view preservation, the path the About sheet
    /// takes (CI: kb=true after it). A responder resigned by hand and taken back later is first responder again but
    /// WebKit starts no input session for it: no keyboard (CI rounds 1-2: fr=true kb=false). Set before `shown`.
    var modal = false
    /// The software keyboard is on screen (keyboardWillShow / WillHide), for the check after the sheet came up.
    var keyboardVisible = false
}

/// Format sheet words, EN + AR.
enum FormatText {
    static func format(_ ar: Bool) -> String { ar ? "تنسيق" : "Format" }
    static func done(_ ar: Bool) -> String { ar ? "تم" : "Done" }
    static func text(_ ar: Bool) -> String { ar ? "النص" : "Text" }
    static func paragraph(_ ar: Bool) -> String { ar ? "الفقرة" : "Paragraph" }
    static func insert(_ ar: Bool) -> String { ar ? "إدراج" : "Insert" }
    static func allTools(_ ar: Bool) -> String { ar ? "كل الأدوات" : "All tools" }
}

/// "Aa" as a glyph: SF Symbols' textformat (drawn the same in both languages, never mirrored).
struct FormatGlyph: View {
    var body: some View {
        Image(systemName: "textformat")
            .font(.system(size: 20, weight: .regular))
            .environment(\.layoutDirection, .leftToRight)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }
}

/// Presents the format sheet for the screen it is applied to (EditorScreen, AutotestScreen). Observes only the
/// sheet's model, so opening / closing never redraws the editor screen (a redraw rebuilds its toolbar: the M7b dead
/// ⋯ menu lesson).
struct FormatSheetPresenter: ViewModifier {
    @ObservedObject var model: FormatSheetModel
    var controller: EditorController
    var ar: Bool

    func body(content: Content) -> some View {
        content
            // anchored under the top bar's trailing edge, where Aa sits. UnitPoint is not mirrored by the layout
            // direction (CI, iPad in Arabic: the popover hung on the right while Aa was on the left), so Arabic
            // anchors on the left itself
            .popover(isPresented: $model.shown, attachmentAnchor: .point(ar ? .topLeading : .topTrailing), arrowEdge: .top) {
                FormatSheet(state: controller.state, controller: controller, ar: ar) { keyboard in
                    model.restoreKeyboard = keyboard
                    model.shown = false
                }
                    .frame(idealWidth: 375, idealHeight: 560)
                    .presentationCompactAdaptation(.sheet)          // iPhone: a real sheet...
                    .presentationDetents([.height(320), .large])     // ...at thumb height, or full
                    .presentationDragIndicator(.visible)
                    // typing (keyboard was up): modal, see FormatSheetModel.modal; otherwise the page stays usable above
                    .presentationBackgroundInteraction(model.modal ? .disabled : .enabled(upThrough: .height(320)))
                    .onAppear { controller.formatShown() }
            }
            .onChange(of: model.shown) { _, shown in
                if !shown { controller.formatClosed(restore: model.restoreKeyboard) }
                model.restoreKeyboard = true
            }
            // the page stays usable beside the 320 pt sheet: a tap there that brings the keyboard up means the user
            // wants to type - the sheet steps aside instead of sitting under the keyboard
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                model.keyboardVisible = true
                if model.shown && !model.modal { model.shown = false }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                model.keyboardVisible = false
            }
    }
}

extension View {
    /// The Aa format sheet over this editor (Word).
    func formatSheet(_ controller: EditorController, ar: Bool) -> some View {
        modifier(FormatSheetPresenter(model: controller.formatSheet, controller: controller, ar: ar))
    }
}

struct FormatSheet: View {
    @ObservedObject var state: EditorState
    let controller: EditorController
    let ar: Bool
    /// Closes the sheet; `true` gives the keyboard back (Done), `false` keeps it down (the next screen takes over).
    var close: (_ keyboard: Bool) -> Void
    @State private var tab = Tab.text
    @State private var showFonts = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Tab: Hashable { case text, paragraph, insert }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker(FormatText.format(ar), selection: $tab) {
                    Text(FormatText.text(ar)).tag(Tab.text)
                    Text(FormatText.paragraph(ar)).tag(Tab.paragraph)
                    Text(FormatText.insert(ar)).tag(Tab.insert)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("xr-fmt-tabs")
                Button(FormatText.done(ar)) { close(true) }
                    .font(.body.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityIdentifier("xr-fmt-done")
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 6)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch tab {
                    case .text: textTab
                    case .paragraph: paragraphTab
                    case .insert: insertTab
                    }
                    Divider()
                    Button {
                        close(false)
                        controller.allTools()
                    } label: {
                        Label(FormatText.allTools(ar), systemImage: "slider.horizontal.3")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("xr-fmt-all-tools")
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .environment(\.layoutDirection, ar ? .rightToLeft : .leftToRight)
        .onAppear { FormatFonts.registerOnce() }
    }

    // MARK: Text

    /// Style names as the engine stores them (put_Style / asc_onParaStyleName), with EN / AR labels and a preview size.
    private struct StyleChoice { let name, en, ar: String; let size: CGFloat; let weight: Font.Weight }
    private static let styles: [StyleChoice] = [
        StyleChoice(name: "Title", en: "Title", ar: "عنوان رئيسي", size: 24, weight: .regular),
        StyleChoice(name: "Heading 1", en: "Heading 1", ar: "عنوان 1", size: 20, weight: .semibold),
        StyleChoice(name: "Heading 2", en: "Heading 2", ar: "عنوان 2", size: 17, weight: .semibold),
        StyleChoice(name: "Heading 3", en: "Heading 3", ar: "عنوان 3", size: 15, weight: .semibold),
        StyleChoice(name: "Normal", en: "Normal", ar: "عادي", size: 15, weight: .regular),
    ]

    /// Font sizes the stepper walks through (the ribbon's own list).
    private static let sizes: [Double] = [8, 9, 10, 11, 12, 14, 16, 18, 20, 22, 24, 26, 28, 36, 48, 72]

    private var textTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            // styles with live previews (Cairo in Arabic)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Self.styles, id: \.name) { s in
                        let on = state.style.lowercased() == s.name.lowercased()     // a file may store "heading 1"
                        // a tap on the chip that is already on does nothing: the engine's SetParagraphStyle CLEARS the
                        // paragraph's formatting when the style is applied a second time, a surprise for a highlighted chip
                        Button {
                            if !on { apply("style", "if(window.__xrStyle)__xrStyle(\(js(s.name)));else a.put_Style(\(js(s.name)))") }
                        } label: {
                            Text(ar ? s.ar : s.en)
                                .font(ar ? .custom("Cairo", size: s.size).weight(s.weight) : .system(size: s.size, weight: s.weight))
                                .lineLimit(1)
                                .padding(.horizontal, 12)
                                .frame(minHeight: 52)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(on ? Color.xrDocument.opacity(0.15) : Color(uiColor: .secondarySystemGroupedBackground)))
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(on ? Color.xrDocument : .clear, lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                        .accessibilityIdentifier("xr-fmt-style-" + s.name.lowercased().replacingOccurrences(of: " ", with: ""))
                    }
                }
            }
            card {
                // font: the current one; a tap unfolds the list, each family drawn in itself
                Button { withAnimation(reduceMotion ? nil : Animation.easeInOut(duration: 0.2)) { showFonts.toggle() } } label: {
                    HStack {
                        Text(ar ? "الخط" : "Font").foregroundStyle(.primary)
                        Spacer()
                        Text(state.fontName.isEmpty ? "—" : state.fontName).foregroundStyle(.secondary).lineLimit(1)
                        Image(systemName: showFonts ? "chevron.up" : "chevron.down").foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("xr-fmt-font")
                if showFonts {
                    ForEach(FormatFonts.families(arabicFirst: ar), id: \.self) { f in
                        Divider()
                        Button { apply("font", "a.put_TextPrFontName(\(js(f)))") } label: {
                            HStack {
                                Text(FormatFonts.sample(f)).font(.custom(f, size: 17)).lineLimit(1)
                                Spacer()
                                if state.fontName == f { Image(systemName: "checkmark").foregroundStyle(Color.xrDocument) }
                            }
                            .environment(\.layoutDirection, ar ? .rightToLeft : .leftToRight)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(f)
                        .accessibilityAddTraits(state.fontName == f ? .isSelected : [])
                    }
                }
                Divider()
                sizeRow
            }
            // B / I / U / S
            HStack(spacing: 8) {
                toggle("bold", on: state.bold, en: "Bold", arLabel: "غامق", id: "xr-fmt-bold") { "a.put_TextPrBold(\(!state.bold))" }
                toggle("italic", on: state.italic, en: "Italic", arLabel: "مائل", id: "xr-fmt-italic") { "a.put_TextPrItalic(\(!state.italic))" }
                toggle("underline", on: state.underline, en: "Underline", arLabel: "تسطير", id: "xr-fmt-underline") { "a.put_TextPrUnderline(\(!state.underline))" }
                toggle("strikethrough", on: state.strikeout, en: "Strikethrough", arLabel: "يتوسطه خط", id: "xr-fmt-strike") { "a.put_TextPrStrikeout(\(!state.strikeout))" }
            }
            .environment(\.layoutDirection, .leftToRight)       // B I U S read the same in both languages
            colorRow
            highlightRow
        }
    }

    private var sizeRow: some View {
        let size = state.fontSize
        let down = Self.sizes.last { $0 < size } ?? Self.sizes[0]
        let up = Self.sizes.first { $0 > size } ?? Self.sizes[Self.sizes.count - 1]
        return HStack {
            Text(ar ? "الحجم" : "Size")
            Spacer()
            Button { apply("size \(fmt(down))", "a.put_TextPrFontSize(\(fmt(down)))") } label: {
                Image(systemName: "minus").frame(width: 44, height: 44).contentShape(Rectangle())
            }
            // mixed or not known yet (0): no step at all - "one step down / up" from nothing would jump to 8 pt
            .disabled(size <= 0 || size <= Self.sizes[0])
            .accessibilityLabel(ar ? "تصغير الخط" : "Smaller")
            .accessibilityIdentifier("xr-fmt-size-down")
            Text(size > 0 ? fmt(size) : "—")
                .font(.body.monospacedDigit())
                .frame(minWidth: 44)
                .accessibilityIdentifier("xr-fmt-size")
            Button { apply("size \(fmt(up))", "a.put_TextPrFontSize(\(fmt(up)))") } label: {
                Image(systemName: "plus").frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .disabled(size <= 0 || size >= Self.sizes[Self.sizes.count - 1])
            .accessibilityLabel(ar ? "تكبير الخط" : "Larger")
            .accessibilityIdentifier("xr-fmt-size-up")
        }
        .buttonStyle(.borderless)
        .accessibilityElement(children: .contain)
    }

    /// Eight text colours (Xrero's own set, not an office suite's palette) after Automatic.
    private struct ColorChoice { let hex, en, ar: String }
    private static let colors: [ColorChoice] = [
        ColorChoice(hex: "000000", en: "Black", ar: "أسود"), ColorChoice(hex: "595959", en: "Grey", ar: "رمادي"),
        ColorChoice(hex: "C0392B", en: "Red", ar: "أحمر"), ColorChoice(hex: "E67E22", en: "Orange", ar: "برتقالي"),
        ColorChoice(hex: "1E8449", en: "Green", ar: "أخضر"), ColorChoice(hex: "1F7A8C", en: "Teal", ar: "أزرق مخضر"),
        ColorChoice(hex: "2E5AAC", en: "Blue", ar: "أزرق"), ColorChoice(hex: "7D3C98", en: "Purple", ar: "بنفسجي"),
    ]
    private static let highlights: [ColorChoice] = [
        ColorChoice(hex: "FFFF00", en: "Yellow", ar: "أصفر"), ColorChoice(hex: "00FF00", en: "Green", ar: "أخضر"),
        ColorChoice(hex: "00FFFF", en: "Cyan", ar: "سماوي"), ColorChoice(hex: "FF00FF", en: "Pink", ar: "وردي"),
        ColorChoice(hex: "D3D3D3", en: "Grey", ar: "رمادي"),
    ]

    private var colorRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(ar ? "لون النص" : "Text colour").font(.subheadline).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    swatch(nil, on: state.textColor == "auto", label: ar ? "تلقائي" : "Automatic", id: "xr-fmt-color-auto") {
                        apply("color auto", "var c=new Asc.asc_CColor();c.put_auto(true);a.put_TextColor(c)")
                    }
                    ForEach(Self.colors, id: \.hex) { c in
                        swatch(c.hex, on: state.textColor == c.hex, label: ar ? c.ar : c.en, id: "xr-fmt-color-" + c.hex) {
                            apply("color " + c.hex, "a.put_TextColor(new Asc.asc_CColor(\(rgb(c.hex))))")
                        }
                    }
                }
            }
        }
    }

    /// Highlight paints the SELECTED text (the engine's marker: on with a colour, applied, off again at once so no
    /// highlighter mode is left running). With nothing selected it changes nothing - the label says so, and the bridge
    /// call stops before the engine (SetMarkerFormat would still overwrite the format painter's copied format).
    private var highlightRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(ar ? "تظليل النص المحدد" : "Highlight selected text").font(.subheadline).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    swatch(nil, on: false, label: ar ? "بلا تظليل" : "No highlight", id: "xr-fmt-highlight-none") {
                        apply("highlight none", Self.ifSelected + "a.SetMarkerFormat(true,false);a.SetMarkerFormat(false)")
                    }
                    ForEach(Self.highlights, id: \.hex) { c in
                        swatch(c.hex, on: false, label: ar ? c.ar : c.en, id: "xr-fmt-highlight-" + c.hex) {
                            apply("highlight " + c.hex, Self.ifSelected + "a.SetMarkerFormat(true,true,\(rgb(c.hex)));a.SetMarkerFormat(false)")
                        }
                    }
                }
            }
        }
    }

    /// Ends the bridge call when no text is selected (can_CopyCut = a non-empty selection).
    private static let ifSelected = "if(!a.can_CopyCut()){if(window.XreroHost)XreroHost.log('format sheet: highlight - nothing selected');return 'ok';}"

    // MARK: Paragraph

    private var paragraphTab: some View {
        let rtl = state.direction == .rtl
        // the visual edge the paragraph is aligned to (see KeyboardBar.alignButton: the state is logical, put_PrAlign
        // takes the visual edge; AscCommon.align_Left = 1, align_Center = 2, align_Right = 0, align_Justify = 3)
        let edge: String
        switch state.alignment {
        case .center: edge = "center"
        case .justify, .distributed: edge = "justify"
        case .right: edge = rtl ? "left" : "right"
        case .left: edge = rtl ? "right" : "left"
        case .none: edge = ""
        }
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                pill(on: !rtl, id: "xr-fmt-ltr", label: ar ? "من اليسار إلى اليمين" : "Left to right") {
                    apply("direction ltr", "a.asc_setRtlTextDirection(false)")
                } content: {
                    HStack(spacing: 2) { Image(systemName: "paragraphsign"); Image(systemName: "arrow.right") }
                }
                pill(on: rtl, id: "xr-fmt-rtl", label: ar ? "من اليمين إلى اليسار" : "Right to left") {
                    apply("direction rtl", "a.asc_setRtlTextDirection(true)")
                } content: {
                    HStack(spacing: 2) { Image(systemName: "arrow.left"); Image(systemName: "paragraphsign") }
                }
            }
            .environment(\.layoutDirection, .leftToRight)       // direction glyphs are never mirrored
            HStack(spacing: 8) {
                alignPill("left", 1, edge, ar ? "إلى اليسار" : "Left")
                alignPill("center", 2, edge, ar ? "توسيط" : "Centre")
                alignPill("right", 0, edge, ar ? "إلى اليمين" : "Right")
                alignPill("justify", 3, edge, ar ? "ضبط" : "Justified")
            }
            .environment(\.layoutDirection, .leftToRight)       // visual edges: left stays left
            HStack(spacing: 8) {
                toggle("list.bullet", on: state.list == .bullet, en: "Bulleted list", arLabel: "قائمة نقطية", id: "xr-fmt-bullets", mirrors: true) {
                    "a.put_ListTypeCustom('{\"Type\":\"\(state.list == .bullet ? "remove" : "bullet")\"}')"
                }
                toggle("list.number", on: state.list == .number, en: "Numbered list", arLabel: "قائمة رقمية", id: "xr-fmt-numbering", mirrors: true) {
                    "a.put_ListTypeCustom('{\"Type\":\"\(state.list == .number ? "remove" : "number")\"}')"
                }
                toggle("decrease.indent", on: false, en: "Decrease indent", arLabel: "إنقاص المسافة البادئة", id: "xr-fmt-outdent", mirrors: true) {
                    "a.DecreaseIndent()"
                }
                toggle("increase.indent", on: false, en: "Increase indent", arLabel: "زيادة المسافة البادئة", id: "xr-fmt-indent", mirrors: true) {
                    "a.IncreaseIndent()"
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(ar ? "تباعد الأسطر" : "Line spacing").font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach([1.0, 1.15, 1.5, 2.0], id: \.self) { v in
                        let label = v == 1.15 ? "1.15" : String(format: "%.1f", v)
                        pill(on: abs(state.lineSpacing - v) < 0.001, id: "xr-fmt-spacing-" + label.replacingOccurrences(of: ".", with: ""),
                             label: (ar ? "تباعد " : "Spacing ") + label) {
                            apply("spacing " + label, "a.put_PrLineSpacing(Asc.linerule_Auto,\(label))")
                        } content: {
                            Text(label).font(.body.monospacedDigit())
                        }
                    }
                }
                .environment(\.layoutDirection, .leftToRight)
            }
        }
    }

    private func alignPill(_ name: String, _ value: Int, _ edge: String, _ label: String) -> some View {
        pill(on: edge == name, id: "xr-fmt-align-" + name, label: label) {
            apply("align " + name, "a.put_PrAlign(\(value))")
        } content: {
            Image(systemName: name == "justify" ? "text.justify" : "text.align" + name)
        }
    }

    // MARK: Insert

    private var insertTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(ar ? "جدول: اختر الحجم" : "Table: tap a size").font(.subheadline).foregroundStyle(.secondary)
                // a 6 x 6 grid: the tapped cell gives columns x rows (columns run with the reading direction)
                VStack(spacing: 4) {
                    ForEach(1...6, id: \.self) { r in
                        HStack(spacing: 4) {
                            ForEach(1...6, id: \.self) { c in
                                Button {
                                    apply("table \(c)x\(r)", "a.put_Table(\(c),\(r))")
                                    close(false)
                                } label: {
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(Color(uiColor: .secondarySystemGroupedBackground))
                                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .stroke(Color(uiColor: .separator), lineWidth: 0.5))
                                        .frame(width: 44, height: 32)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(ar ? "جدول \(c) × \(r)" : "Table \(c) by \(r)")
                                .accessibilityIdentifier("xr-fmt-table-\(c)x\(r)")
                            }
                        }
                    }
                }
            }
            card {
                Button {
                    // the photo picker comes up over the editor once the sheet is gone (the engine's own picture
                    // path: OpenFilenameDialog -> the app's photo picker -> document media)
                    close(false)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { apply("photo", "a.asc_addImage()") }
                } label: { row(ar ? "صورة" : "Photo", "photo") }
                .buttonStyle(.plain)
                .accessibilityIdentifier("xr-fmt-photo")
                Divider()
                Button {
                    apply("page break", "a.put_AddPageBreak()")
                    close(false)
                } label: { row(ar ? "فاصل صفحة" : "Page break", "doc.badge.plus") }
                .buttonStyle(.plain)
                .accessibilityIdentifier("xr-fmt-page-break")
            }
        }
    }

    // MARK: pieces

    private func row(_ title: String, _ symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground)))
    }

    /// A toggle in the keyboard bar's look (accent at 15 % when on), 44 pt tall, filling its share of the row.
    private func toggle(_ name: String, on: Bool, en: String, arLabel: String, id: String, mirrors: Bool = false,
                        _ js: @escaping () -> String) -> some View {
        Button { apply(id.replacingOccurrences(of: "xr-fmt-", with: ""), js()) } label: {
            Image(systemName: name)
                .font(.system(size: 20, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Color.xrDocument : Color.primary)
                .environment(\.layoutDirection, mirrors && ar ? .rightToLeft : .leftToRight)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(on ? Color.xrDocument.opacity(0.15) : Color(uiColor: .secondarySystemGroupedBackground)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(ar ? arLabel : en)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier(id)
    }

    private func pill<C: View>(on: Bool, id: String, label: String, _ action: @escaping () -> Void,
                               @ViewBuilder content: () -> C) -> some View {
        Button(action: action) {
            content()
                .font(.system(size: 18, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Color.xrDocument : Color.primary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(on ? Color.xrDocument.opacity(0.15) : Color(uiColor: .secondarySystemGroupedBackground)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier(id)
    }

    /// A colour circle (nil = Automatic / none: a slashed circle), 44 pt target.
    private func swatch(_ hex: String?, on: Bool, label: String, id: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                if let hex {
                    Circle().fill(Color(hexRGB: hex))
                } else {
                    Circle().fill(Color(uiColor: .secondarySystemGroupedBackground))
                    Image(systemName: "circle.slash").foregroundStyle(.secondary)
                }
                Circle().stroke(on ? Color.xrDocument : Color(uiColor: .separator), lineWidth: on ? 3 : 0.5)
            }
            .frame(width: 32, height: 32)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier(id)
    }

    private func apply(_ name: String, _ js: String) { controller.format("format sheet", name, js) }

    /// A JavaScript string literal (JSON-escaped), for names passed to the engine.
    private func js(_ s: String) -> String {
        let d = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
        let a = String(data: d, encoding: .utf8) ?? "[\"\"]"
        return String(a.dropFirst().dropLast())
    }

    private func fmt(_ v: Double) -> String { String(format: "%g", v) }

    /// "RRGGBB" -> "r,g,b" for the engine.
    private func rgb(_ hex: String) -> String {
        let v = Int(hex, radix: 16) ?? 0
        return "\((v >> 16) & 255),\((v >> 8) & 255),\(v & 255)"
    }
}

extension Color {
    /// "RRGGBB" (sRGB).
    init(hexRGB hex: String) {
        let v = Int(hex, radix: 16) ?? 0
        self.init(.sRGB, red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255,
                  blue: Double(v & 255) / 255, opacity: 1)
    }
}

/// The document fonts the app ships (web/fonts-gen, see fonts-src/LICENSES.md), registered for this process once so
/// the font list can draw each family in itself. Registration reads the bundled files in the background the first
/// time the sheet opens; until then (or if a file cannot be read) a row falls back to the system font.
enum FormatFonts {
    static let latin = ["Carlito", "Caladea", "Liberation Sans", "Liberation Serif", "Liberation Mono",
                        "Open Sans", "Roboto", "Montserrat", "DejaVu Sans"]
    static let arabic = ["Cairo", "Tajawal", "Amiri", "Noto Naskh Arabic"]

    /// Arabic-capable fonts first in Arabic.
    static func families(arabicFirst: Bool) -> [String] { arabicFirst ? arabic + latin : latin + arabic }

    static func sample(_ family: String) -> String { arabic.contains(family) ? family + "  عربي" : family }

    private static var started = false

    static func registerOnce() {
        guard !started else { return }
        started = true
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("web/fonts-gen/fonts") else { return }
        DispatchQueue.global(qos: .utility).async {
            var want = Set(latin + arabic)
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where !want.isEmpty {
                guard let data = try? Data(contentsOf: url),
                      let descs = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor],
                      let d = descs.first,
                      let family = CTFontDescriptorCopyAttribute(d, kCTFontFamilyNameAttribute) as? String,
                      want.contains(family) else { continue }
                let style = (CTFontDescriptorCopyAttribute(d, kCTFontStyleNameAttribute) as? String) ?? ""
                guard style == "Regular" || style == "Book" else { continue }      // the upright face draws the row
                if let provider = CGDataProvider(data: data as CFData), let font = CGFont(provider),
                   CTFontManagerRegisterGraphicsFont(font, nil) {
                    want.remove(family)
                }
            }
        }
    }
}
