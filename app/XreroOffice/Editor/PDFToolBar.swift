import SwiftUI
import UIKit
import PencilKit
import PhotosUI
import CoreText

/// The PDF editor's own tool bar (plan S7): what people do with a PDF on a phone - highlight, underline, strike out,
/// write with the pen, add a note; fill in text, a check mark, a cross, the date and a visual signature - two taps
/// away instead of inside the web ribbon. A 50 pt bar at the bottom (.bar material) with a segmented switch
/// Annotate | Fill & Sign. While a tool is on, Done takes the switch's place and ends it.
///
/// Every tap is ONE EditorController.call into the editor frame (xr-host.js __xrPdfTool / __xrPdfAdd /
/// __xrPdfPlace), the same engine calls as the editor's own Comment tab. Pictures (signature, check mark, cross,
/// date) are drawn here and handed to the editor through its own Insert > Image path (PDFStagedPick below), so the
/// document keeps them as its own media and saving writes them into the file.
///
/// Flag: UserDefaults "xr.pdfToolBar" (default ON; `-xr.pdfToolBar NO` or `defaults write` rolls it back to the web
/// ribbon alone, which stays one tap away under ⋯ > All tools either way).
struct PDFToolBar: View {
    static let height: CGFloat = 50
    static let flagKey = "xr.pdfToolBar"
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: flagKey) == nil ? true : UserDefaults.standard.bool(forKey: flagKey)
    }

    let controller: EditorController
    let ar: Bool
    @StateObject private var model = PDFToolModel()
    @State private var signing = false
    @State private var placing: String?                     // a picture on its way into the page
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// iPhone (compact width): the switch shows its two symbols (labels stay for VoiceOver), the Eraser shows only
    /// while the pen is on and the Note only while no tool is on, so every tool fits on a 6.3" phone without scrolling
    /// (the signature and the colour dot stay one tap away). iPad: words and every tool.
    private var compact: Bool { sizeClass == .compact }

    var body: some View {
        HStack(spacing: 6) {
            if model.tool != .none {
                Button { model.select(.none, controller) } label: {
                    Text(ar ? "تم" : "Done")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.xrOnTeal)
                        .padding(.horizontal, 16)
                        .frame(minWidth: 64, minHeight: 34)
                        .background(Capsule().fill(Color.xrTeal))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(ar ? "إنهاء الأداة" : "Done")
                .accessibilityIdentifier("xr-pdf-done")
            } else {
                Picker("", selection: Binding(get: { model.mode }, set: { model.setMode($0) })) {
                    if compact {
                        Image(systemName: "pencil.and.outline")
                            .accessibilityLabel(Text(ar ? "تعليق" : "Annotate")).tag(PDFToolModel.Mode.annotate)
                        Image(systemName: "signature")
                            .accessibilityLabel(Text(ar ? "تعبئة وتوقيع" : "Fill & Sign")).tag(PDFToolModel.Mode.fill)
                    } else {
                        Text(ar ? "تعليق" : "Annotate").tag(PDFToolModel.Mode.annotate)
                        Text(ar ? "تعبئة وتوقيع" : "Fill & Sign").tag(PDFToolModel.Mode.fill)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: compact ? 88 : (ar ? 170 : 176))
                .accessibilityLabel(ar ? "مجموعة الأدوات" : "Tool set")
                .accessibilityIdentifier("xr-pdf-mode")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    if model.mode == .annotate { annotateTools } else { fillTools }
                }
                .padding(.horizontal, 4)
            }
            // 8 pt edge fade: "more this way" when the tools overflow a narrow phone
            .mask {
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: 8)
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 8)
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        // direction and the accessibility container on the 50 pt bar itself, before the material that runs on under
        // the home indicator: the bar's frame is the bar (in Arabic the container took in the safe-area background)
        .environment(\.layoutDirection, ar ? .rightToLeft : .leftToRight)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("xr-pdf-bar")
        .background {
            if reduceTransparency { Color(uiColor: .secondarySystemBackground).ignoresSafeArea(edges: .bottom) }
            else { Rectangle().fill(.bar).ignoresSafeArea(edges: .bottom) }
        }
        .overlay(alignment: .top) { Rectangle().fill(Color(uiColor: .separator)).frame(height: 0.5) }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .sheet(isPresented: $signing) {
            SignatureSheet(ar: ar) { png, aspect in
                signing = false
                model.refreshSignature()            // "My signature" was just kept: the button becomes the 2-tap menu
                place("signature", png, widthMM: 45, aspect: aspect)
            } cancel: { signing = false }
        }
    }

    // MARK: the two tool sets

    @ViewBuilder private var annotateTools: some View {
        toolButton(.highlight, "highlighter", en: "Highlight", arLabel: "تمييز")
        toolButton(.underline, "underline", en: "Underline", arLabel: "تسطير")
        toolButton(.strike, "strikethrough", en: "Strike out", arLabel: "يتوسطه خط")
        toolButton(.pen, "pencil.tip", en: "Pen", arLabel: "قلم")
        if !compact || model.tool == .pen || model.tool == .eraser {
            toolButton(.eraser, "eraser", en: "Eraser", arLabel: "ممحاة")
        }
        if !compact || model.tool == .none {
            action("text.bubble", en: "Note", arLabel: "ملاحظة", id: "xr-pdf-note") {
                model.select(.none, controller)
                run("note", "return window.__xrPdfAdd ? __xrPdfAdd('note') : 'no pdf bar';")
            }
        }
        colorMenu
    }

    @ViewBuilder private var fillTools: some View {
        action("character.cursor.ibeam", en: "Text", arLabel: "نص", id: "xr-pdf-text") {
            run("text", "return window.__xrPdfAdd ? __xrPdfAdd('text') : 'no pdf bar';")
        }
        action("checkmark", en: "Check mark", arLabel: "علامة صح", id: "xr-pdf-check") {
            if let png = PDFPicture.symbol("checkmark", color: model.inkColor) { place("check", png, widthMM: 6, aspect: 1) }
        }
        action("xmark", en: "Cross", arLabel: "علامة خطأ", id: "xr-pdf-cross") {
            if let png = PDFPicture.symbol("xmark", color: model.inkColor) { place("cross", png, widthMM: 6, aspect: 1) }
        }
        action("calendar", en: "Date", arLabel: "التاريخ", id: "xr-pdf-date") {
            if let d = PDFPicture.date(ar: ar, color: model.inkColor) { place("date", d.0, widthMM: 5 * d.1, aspect: d.1) }
        }
        signatureButton
    }

    /// Signature: with a saved "My signature" a menu (insert it = 2 taps, or make a new one); without, the sheet.
    @ViewBuilder private var signatureButton: some View {
        if model.hasMySignature {
            Menu {
                Button { insertMine() } label: { Label(ar ? "إدراج توقيعي" : "Insert My Signature", systemImage: "signature") }
                    .accessibilityIdentifier("xr-pdf-sig-mine")
                Button { signing = true } label: { Label(ar ? "توقيع جديد…" : "New Signature…", systemImage: "plus") }
                    .accessibilityIdentifier("xr-pdf-sig-new")
                Button(role: .destructive) { SignatureStore.delete(); model.refreshSignature() } label: {
                    Label(ar ? "حذف توقيعي من الجهاز" : "Delete My Signature", systemImage: "trash")
                }
                .accessibilityIdentifier("xr-pdf-sig-delete")
            } label: { symbol("signature", on: false) }
            .accessibilityLabel(ar ? "توقيع" : "Signature")
            .accessibilityIdentifier("xr-pdf-signature")
        } else {
            action("signature", en: "Signature", arLabel: "توقيع", id: "xr-pdf-signature") { signing = true }
        }
    }

    /// The colour dot: 6 swatches and the opacity, used by the next highlight / line / pen stroke / mark (remembered).
    private var colorMenu: some View {
        Menu {
            Picker(ar ? "اللون" : "Colour", selection: Binding(get: { model.color }, set: { model.setColor($0, controller) })) {
                ForEach(PDFToolModel.swatches, id: \.hex) { s in
                    Label(ar ? s.ar : s.en, systemImage: "circle.fill").tag(s.hex)
                }
            }
            Picker(ar ? "الشفافية" : "Opacity", selection: Binding(get: { model.opacity }, set: { model.setOpacity($0, controller) })) {
                ForEach([100, 75, 50, 25], id: \.self) { v in Text(verbatim: "\(v)%").tag(v) }
            }
        } label: {
            Circle()
                .fill(Color(hex: model.color).opacity(Double(model.opacity) / 100))
                .overlay(Circle().strokeBorder(Color(uiColor: .separator), lineWidth: 1))
                .frame(width: 24, height: 24)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(ar ? "اللون" : "Colour")
        .accessibilityValue(Text(verbatim: PDFToolModel.name(model.color, ar) + " " + String(model.opacity) + "%"))
        .accessibilityIdentifier("xr-pdf-color")
    }

    // MARK: buttons

    private func toolButton(_ t: PDFToolModel.Tool, _ glyph: String, en: String, arLabel: String) -> some View {
        let on = model.tool == t
        return Button { model.select(on ? .none : t, controller) } label: { symbol(glyph, on: on) }
            .accessibilityLabel(ar ? arLabel : en)
            .accessibilityAddTraits(on ? .isSelected : [])
            .accessibilityIdentifier("xr-pdf-" + t.rawValue)
    }

    private func action(_ glyph: String, en: String, arLabel: String, id: String, _ go: @escaping () -> Void) -> some View {
        Button(action: go) { symbol(glyph, on: placing == id) }
            .accessibilityLabel(ar ? arLabel : en)
            .accessibilityIdentifier(id)
    }

    /// 22 pt symbol in a 44 pt target; the active tool sits in a 32 pt rounded square in the PDF accent at 15 %.
    /// Pen and text glyphs are drawn as they are in both languages (never mirrored).
    private func symbol(_ name: String, on: Bool) -> some View {
        Image(systemName: name)
            .font(.system(size: 22, weight: on ? .semibold : .regular))
            .foregroundStyle(on ? Color.xrPDF : Color.primary)
            .frame(width: 34, height: 34)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(on ? Color.xrPDF.opacity(0.15) : .clear))
            .environment(\.layoutDirection, .leftToRight)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    // MARK: actions

    private func insertMine() {
        guard let png = SignatureStore.load(), let img = UIImage(data: png), img.size.height > 0 else {
            model.refreshSignature(); signing = true; return
        }
        place("signature", png, widthMM: 45, aspect: img.size.width / img.size.height)
    }

    /// A picture into the page: staged as the editor's next picker answer, then the editor's own Insert > Image.
    private func place(_ what: String, _ png: Data, widthMM: Double, aspect: Double) {
        model.select(.none, controller)
        let w = max(4, min(120, widthMM)), h = max(3, w / max(aspect, 0.05))
        PDFStagedPick.stage(name: what + ".png", data: png)
        placing = "xr-pdf-" + (what == "signature" ? "signature" : what)
        let wTxt = String(format: "%.1f", w), hTxt = String(format: "%.1f", h)
        run("place " + what, "return window.__xrPdfPlace ? __xrPdfPlace('\(what)',\(wTxt),\(hTxt)) : 'no pdf bar';") { ok in
            if !ok { PDFStagedPick.clear() }
            placing = nil
        }
    }

    private func run(_ name: String, _ js: String, _ done: ((Bool) -> Void)? = nil) {
        controller.call(js) { r, e in
            let res = (r as? String) ?? e ?? "?"
            if res != "ok" { NSLog("XR pdf bar %@: %@", name, res) }
            controller.call("if(window.XreroHost)XreroHost.log('pdf bar tap: \(name) -> '+\(PDFToolModel.jsString(res)));return 1;")
            done?(res == "ok")
        }
    }
}

/// The bar's state: Annotate / Fill & Sign, the tool that is on, the last colour and opacity (remembered).
final class PDFToolModel: ObservableObject {
    enum Mode: String { case annotate, fill }
    enum Tool: String { case none, highlight, underline, strike, pen, eraser }
    struct Swatch { let hex: String; let en: String; let ar: String }
    static let swatches = [Swatch(hex: "FFD60A", en: "Yellow", ar: "أصفر"), Swatch(hex: "34C759", en: "Green", ar: "أخضر"),
                           Swatch(hex: "0A84FF", en: "Blue", ar: "أزرق"), Swatch(hex: "FF375F", en: "Pink", ar: "وردي"),
                           Swatch(hex: "FF3B30", en: "Red", ar: "أحمر"), Swatch(hex: "1C1C1E", en: "Black", ar: "أسود")]
    static func name(_ hex: String, _ ar: Bool) -> String {
        guard let s = swatches.first(where: { $0.hex == hex }) else { return hex }
        return ar ? s.ar : s.en
    }

    @Published private(set) var mode: Mode
    @Published private(set) var tool = Tool.none
    @Published private(set) var color: String
    @Published private(set) var opacity: Int
    @Published private(set) var hasMySignature = SignatureStore.exists

    private let d = UserDefaults.standard
    init() {
        let d = UserDefaults.standard
        mode = Mode(rawValue: d.string(forKey: "xr.pdf.mode") ?? "") ?? .annotate
        let c = d.string(forKey: "xr.pdf.color") ?? ""
        color = PDFToolModel.swatches.contains { $0.hex == c } ? c : "FFD60A"
        let o = d.integer(forKey: "xr.pdf.opacity")
        opacity = [25, 50, 75, 100].contains(o) ? o : 100
        // kept or deleted anywhere (the sheet, the menu, the test hook): the signature button follows at once
        signatureObserver = NotificationCenter.default.addObserver(forName: SignatureStore.changed, object: nil, queue: .main) { [weak self] _ in
            self?.refreshSignature()
        }
    }
    private var signatureObserver: NSObjectProtocol?
    deinit { if let o = signatureObserver { NotificationCenter.default.removeObserver(o) } }

    /// Marks (check, cross, date) in the chosen colour, except yellow, which is unreadable on paper: black then.
    var inkColor: UIColor { color == "FFD60A" ? .black : UIColor(Color(hex: color)) }

    func setMode(_ m: Mode) { mode = m; d.set(m.rawValue, forKey: "xr.pdf.mode") }
    func refreshSignature() { hasMySignature = SignatureStore.exists }

    func setColor(_ hex: String, _ c: EditorController) {
        color = hex; d.set(hex, forKey: "xr.pdf.color")
        if tool != .none && tool != .eraser { select(tool, c) }       // the tool that is on takes the new colour
    }
    func setOpacity(_ v: Int, _ c: EditorController) {
        opacity = v; d.set(v, forKey: "xr.pdf.opacity")
        if tool != .none && tool != .eraser { select(tool, c) }
    }

    /// One call: the engine switches the tool (and everything else off).
    func select(_ t: Tool, _ c: EditorController) {
        let name = t.rawValue
        c.call("return window.__xrPdfTool ? __xrPdfTool('\(name)','\(color)',\(opacity)) : 'no pdf bar';") { [weak self] r, e in
            let res = (r as? String) ?? e ?? "?"
            if res != "ok" { NSLog("XR pdf bar tool %@: %@", name, res) }
            DispatchQueue.main.async { self?.tool = res == "ok" ? t : .none }
        }
        if t == .none { tool = .none }
    }

    /// A Swift string as a JS string literal.
    static func jsString(_ s: String) -> String {
        String(data: (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8), encoding: .utf8)
            .map { String($0.dropFirst().dropLast()) } ?? "''"
    }
}

/// The picture the editor gets on its next picker request ("pick" in EditorWebView) instead of the photo picker:
/// the PDF bar stages its signature / mark here just before it asks the editor to insert an image. Taken once;
/// cleared after 10 s so a later Insert > Image of the user's own always shows the photo picker.
enum PDFStagedPick {
    private static var next: (name: String, data: Data, at: Date)?
    static func stage(name: String, data: Data) { next = (name, data, Date()) }
    static func clear() { next = nil }
    static func take() -> (name: String, data: Data)? {
        defer { next = nil }
        guard let n = next, Date().timeIntervalSince(n.at) < 10 else { return nil }
        return (n.name, n.data)
    }
}

/// "My signature": one PNG on this device only - Application Support, complete file protection (unreadable while the
/// phone is locked), excluded from backups. Never sent anywhere.
enum SignatureStore {
    private static var url: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("Signatures", isDirectory: true).appendingPathComponent("my-signature.png")
    }
    static var exists: Bool { url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
    static func load() -> Data? { url.flatMap { try? Data(contentsOf: $0) } }
    static func save(_ png: Data) {
        guard var u = url else { return }
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? png.write(to: u, options: [.atomic, .completeFileProtection])
        var v = URLResourceValues(); v.isExcludedFromBackup = true
        try? u.setResourceValues(v)
        NotificationCenter.default.post(name: changed, object: nil)
    }
    static func delete() {
        if let u = url { try? FileManager.default.removeItem(at: u) }
        NotificationCenter.default.post(name: changed, object: nil)
    }
    /// Posted after a save or a delete.
    static let changed = Notification.Name("xr.mySignatureChanged")
}

/// Pictures for the page, as PNG with a transparent background.
enum PDFPicture {
    static func symbol(_ name: String, color: UIColor) -> Data? {
        let cfg = UIImage.SymbolConfiguration(pointSize: 200, weight: .bold)
        guard let sym = UIImage(systemName: name, withConfiguration: cfg)?.withTintColor(color, renderingMode: .alwaysOriginal) else { return nil }
        let side: CGFloat = 256
        let f = UIGraphicsImageRendererFormat(); f.scale = 1; f.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: f).pngData { _ in
            let s = sym.size, k = min(side / s.width, side / s.height) * 0.9
            let w = s.width * k, h = s.height * k
            sym.draw(in: CGRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h))
        }
    }

    /// Today's date, written the way the app's language writes it (digits stay Western: never mirrored digits).
    static func date(ar: Bool, color: UIColor) -> (Data, Double)? {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: ar ? "ar-u-nu-latn" : "en_GB")
        fmt.dateStyle = .medium
        fmt.timeStyle = .none
        return text(fmt.string(from: Date()), font: UIFont.systemFont(ofSize: 96, weight: .medium), color: color)
    }

    static func text(_ s: String, font: UIFont, color: UIColor) -> (Data, Double)? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let str = NSAttributedString(string: t, attributes: attrs)
        let b = str.boundingRect(with: CGSize(width: 4000, height: 1000), options: [.usesLineFragmentOrigin], context: nil)
        let pad: CGFloat = font.pointSize * 0.15
        let size = CGSize(width: ceil(b.width + pad * 2), height: ceil(b.height + pad * 2))
        let f = UIGraphicsImageRendererFormat(); f.scale = 1; f.opaque = false
        let png = UIGraphicsImageRenderer(size: size, format: f).pngData { _ in
            str.draw(with: CGRect(x: pad, y: pad, width: b.width + 1, height: b.height + 1), options: [.usesLineFragmentOrigin], context: nil)
        }
        return (png, Double(size.width / max(size.height, 1)))
    }

    /// The signature trimmed to what was drawn, at most 900 px wide, as PNG; nil when nothing is there.
    static func trimmed(_ img: UIImage) -> (Data, Double)? {
        guard let cg = img.cgImage else { return nil }
        let w = cg.width, h = cg.height
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                                space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let px = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in stride(from: 0, to: h, by: 2) {
            for x in stride(from: 0, to: w, by: 2) where px[(y * w + x) * 4 + 3] > 8 {
                if x < minX { minX = x }; if x > maxX { maxX = x }
                if y < minY { minY = y }; if y > maxY { maxY = y }
            }
        }
        guard maxX > minX, maxY > minY else { return nil }
        let pad = 6
        let r = CGRect(x: max(0, minX - pad), y: max(0, minY - pad),
                       width: min(w, maxX + pad) - max(0, minX - pad), height: min(h, maxY + pad) - max(0, minY - pad))
        guard let cut = cg.cropping(to: r) else { return nil }
        let k = min(1, 900 / CGFloat(cut.width))
        let size = CGSize(width: CGFloat(cut.width) * k, height: CGFloat(cut.height) * k)
        let f = UIGraphicsImageRendererFormat(); f.scale = 1; f.opaque = false
        let png = UIGraphicsImageRenderer(size: size, format: f).pngData { _ in
            UIImage(cgImage: cut).draw(in: CGRect(origin: .zero, size: size))
        }
        return (png, Double(size.width / max(size.height, 1)))
    }

    /// The typed-signature fonts: a Latin script face (iOS's own) and Amiri, the app's bundled Arabic OFL font
    /// (web/fonts-gen, the editors' font folder: its file found through AllFonts.js).
    static func scriptFont(arabic: Bool, size: CGFloat) -> UIFont {
        if arabic, let name = amiri, let f = UIFont(name: name, size: size) { return f }
        if !arabic, let f = UIFont(name: "SnellRoundhand-Bold", size: size) { return f }
        return UIFont.italicSystemFont(ofSize: size)
    }

    private static let amiri: String? = {
        let root = Bundle.main.resourceURL?.appendingPathComponent("web/fonts-gen", isDirectory: true)
        guard let root, let js = try? String(contentsOf: root.appendingPathComponent("AllFonts.js"), encoding: .utf8),
              let m = js.range(of: #"\["Amiri",(\d+),"#, options: .regularExpression) else { return nil }
        let idx = Int(js[m].filter(\.isNumber)) ?? -1
        // window["__fonts_files"] = ["000", "001", ...]: the idx-th entry is the file
        guard idx >= 0, let a = js.range(of: "__fonts_files"), let open = js[a.upperBound...].firstIndex(of: "["),
              let close = js[open...].firstIndex(of: "]") else { return nil }
        let files = js[js.index(after: open)..<close].split(separator: ",")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \n\r\t\"")) }
        guard idx < files.count else { return nil }
        let url = root.appendingPathComponent("fonts").appendingPathComponent(files[idx])
        guard let descs = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let d = descs.first,
              let name = CTFontDescriptorCopyAttribute(d, kCTFontNameAttribute) as? String else { return nil }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        return name
    }()
}

/// Draw / Type / Image a signature, then insert it as "My signature" (kept on this device) or once for someone else.
/// Labelled honestly: a picture of a signature, not a certified electronic signature.
struct SignatureSheet: View {
    enum Source: String { case draw, type, image }
    let ar: Bool
    var insert: (Data, Double) -> Void
    var cancel: () -> Void
    @State private var source = Source.draw
    @State private var drawing = PKDrawing()
    @State private var name = ""
    @State private var arabicFont = false
    @State private var photo: PhotosPickerItem?
    @State private var picked: UIImage?
    @State private var mine = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Text(ar ? "توقيع مرئي (ليس توقيعاً إلكترونياً معتمداً)" : "Visual signature (not a certified e-signature)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("xr-sig-label")
                Picker("", selection: $source) {
                    Text(ar ? "رسم" : "Draw").tag(Source.draw)
                    Text(ar ? "كتابة" : "Type").tag(Source.type)
                    Text(ar ? "صورة" : "Image").tag(Source.image)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("xr-sig-source")
                pad
                Picker("", selection: $mine) {
                    Text(ar ? "توقيعي" : "My signature").tag(true)
                    Text(ar ? "شخص آخر (مرة واحدة)" : "Someone else (once)").tag(false)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("xr-sig-owner")
                Text(mine ? (ar ? "يُحفظ توقيعك على هذا الجهاز فقط، ولا يُرسل إلى أي مكان." : "Kept on this device only. Never sent anywhere.")
                          : (ar ? "يُستخدم مرة واحدة ولا يُحفظ." : "Used once, not kept."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button { done() } label: {
                    Text(ar ? "إدراج التوقيع" : "Insert Signature")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.xrTeal)
                .disabled(!canInsert)
                .accessibilityIdentifier("xr-sig-insert")
                Spacer(minLength: 0)
            }
            .padding(16)
            .navigationTitle(ar ? "توقيع" : "Signature")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(ar ? "إلغاء" : "Cancel") { cancel() }.accessibilityIdentifier("xr-sig-cancel")
                }
                if source == .draw {
                    ToolbarItem(placement: .primaryAction) {
                        Button(ar ? "مسح" : "Clear") { drawing = PKDrawing() }.accessibilityIdentifier("xr-sig-clear")
                    }
                }
            }
        }
        .environment(\.layoutDirection, ar ? .rightToLeft : .leftToRight)
        .presentationDetents([.large])          // the keyboard (Type) never covers Insert
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                if let d = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: d) {
                    await MainActor.run { picked = img }
                }
            }
        }
    }

    @ViewBuilder private var pad: some View {
        switch source {
        case .draw:
            SignatureCanvas(drawing: $drawing)
                .frame(maxWidth: .infinity)
                .frame(height: 200)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Color.gray.opacity(0.5)).frame(height: 1).padding(.horizontal, 24).padding(.bottom, 44)
                        .allowsHitTesting(false)
                }
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(uiColor: .separator)))
                .environment(\.layoutDirection, .leftToRight)
                .accessibilityLabel(ar ? "ارسم توقيعك هنا" : "Draw your signature here")
                .accessibilityIdentifier("xr-sig-canvas")
        case .type:
            VStack(spacing: 10) {
                TextField(ar ? "اسمك" : "Your name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("xr-sig-name")
                Picker("", selection: $arabicFont) {
                    Text(ar ? "خط لاتيني" : "Script").tag(false)
                    Text(ar ? "خط عربي" : "Arabic").tag(true)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("xr-sig-font")
                Text(name.isEmpty ? " " : name)
                    .font(.custom(PDFPicture.scriptFont(arabic: arabicFont, size: 40).fontName, size: 40))
                    .foregroundStyle(Color.black)
                    .frame(maxWidth: .infinity, minHeight: 110)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
                    .accessibilityIdentifier("xr-sig-preview")
            }
        case .image:
            VStack(spacing: 10) {
                PhotosPicker(selection: $photo, matching: .images) {
                    Label(ar ? "اختيار صورة التوقيع" : "Choose a Signature Photo", systemImage: "photo")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("xr-sig-photo")
                if let picked {
                    Image(uiImage: picked).resizable().scaledToFit().frame(maxHeight: 120)
                }
            }
            .frame(minHeight: 200)
        }
    }

    private var canInsert: Bool {
        switch source {
        case .draw: return !drawing.strokes.isEmpty
        case .type: return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .image: return picked != nil
        }
    }

    /// The signature as PNG + its width / height, or nil while there is nothing to insert.
    private var output: (Data, Double)? {
        switch source {
        case .draw:
            guard !drawing.strokes.isEmpty else { return nil }
            // the strokes' own bounds (plus the pen's width), not the canvas size read at onAppear: on the iPhone the
            // sheet was still animating in then, the size came back empty and Insert did nothing
            let r = drawing.bounds.insetBy(dx: -8, dy: -8)
            guard r.width > 1, r.height > 1 else { return nil }
            let img = drawing.image(from: r, scale: 3)
            if let t = PDFPicture.trimmed(img) { return t }
            guard let png = img.pngData() else { return nil }
            return (png, Double(r.width / r.height))
        case .type:
            return PDFPicture.text(name, font: PDFPicture.scriptFont(arabic: arabicFont, size: 120), color: .black)
        case .image:
            guard let picked, let png = picked.pngData() else { return nil }
            return (png, Double(picked.size.width / max(picked.size.height, 1)))
        }
    }

    private func done() {
        guard let o = output else { return }
        if mine { SignatureStore.save(o.0) }
        insert(o.0, o.1)
    }
}

/// PencilKit canvas: finger or Apple Pencil, black ink on white (a signature is written on paper colour in both looks).
struct SignatureCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PKCanvasView {
        let v = PKCanvasView()
        v.drawingPolicy = .anyInput
        v.tool = PKInkingTool(.pen, color: .black, width: 5)
        v.backgroundColor = .clear
        v.isOpaque = false
        v.overrideUserInterfaceStyle = .light            // black ink stays black (no dark-mode ink inversion)
        v.isScrollEnabled = false
        v.drawing = drawing
        v.delegate = context.coordinator
        return v
    }

    func updateUIView(_ v: PKCanvasView, context: Context) {
        context.coordinator.parent = self
        if drawing.strokes.isEmpty && !v.drawing.strokes.isEmpty { v.drawing = drawing }   // Clear
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: SignatureCanvas
        init(_ p: SignatureCanvas) { parent = p }
        func canvasViewDrawingDidChange(_ v: PKCanvasView) {
            let d = v.drawing
            DispatchQueue.main.async { self.parent.drawing = d }
        }
    }
}

extension Color {
    /// "RRGGBB" -> Color (the PDF bar's swatches).
    init(hex: String) {
        let v = UInt32(hex, radix: 16) ?? 0xFFD60A
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

extension View {
    /// The PDF bar under a PDF editor (plan S7); any other kind, or the flag off: the view as it is.
    @ViewBuilder func pdfToolBar(kind: OfficeKind, controller: EditorController, ar: Bool) -> some View {
        if kind == .pdf && PDFToolBar.enabled {
            VStack(spacing: 0) {
                self
                PDFToolBar(controller: controller, ar: ar)
            }
        } else {
            self
        }
    }
}
