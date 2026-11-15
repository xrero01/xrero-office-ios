import SwiftUI

/// The template gallery (plan S8): UAE templates in English and Arabic, bundled with the app (works offline).
/// The files and web/templates/gallery.json are written by scripts/make_gallery_templates.py; assemble_web.sh copies
/// them to web/templates in the app bundle. A tap on a Home create tile still makes a blank file at once - the gallery
/// is the "Templates" row under the tiles (and the tiles' long-press menu).
struct TemplateManifest: Decodable {
    struct Words: Decodable, Hashable {
        let en: String
        let ar: String
        func text(_ lang: String) -> String { lang == "ar" ? ar : en }
    }
    struct Category: Decodable, Identifiable, Hashable {
        let id: String
        let name: Words
    }
    struct Template: Decodable, Identifiable, Hashable {
        let id: String
        let category: String
        let kind: String
        let thumbnail: String
        let name: Words
        let file: Words

        var officeKind: OfficeKind { OfficeKind(rawValue: kind) ?? .word }

        /// the bundled file of this template in one language
        func url(_ lang: String) -> URL {
            Bundle.main.resourceURL!.appendingPathComponent("web/templates").appendingPathComponent(file.text(lang))
        }
    }

    let categories: [Category]
    let templates: [Template]

    static let shared: TemplateManifest = {
        let url = Bundle.main.resourceURL!.appendingPathComponent("web/templates/gallery.json")
        guard let data = try? Data(contentsOf: url), let m = try? JSONDecoder().decode(TemplateManifest.self, from: data)
        else { NSLog("XR templates: gallery.json missing or unreadable"); return TemplateManifest(categories: [], templates: []) }
        return m
    }()
}

/// The gallery sheet (.large): category chips, an EN / ع switch for the template language (Arabic first when the app
/// is in Arabic), and a grid of 3:4 previews - 2 columns on iPhone, 4 on iPad. Choosing one hands the template and
/// the chosen language back; the caller makes the file and opens it.
struct TemplateGallerySheet: View {
    let ar: Bool
    let onPick: (TemplateManifest.Template, String) -> Void
    @State private var category: String
    @State private var lang: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    private let manifest = TemplateManifest.shared

    init(ar: Bool, category: String? = nil, onPick: @escaping (TemplateManifest.Template, String) -> Void) {
        self.ar = ar
        self.onPick = onPick
        _category = State(initialValue: category ?? "all")
        _lang = State(initialValue: ar ? "ar" : "en")
    }

    private var shown: [TemplateManifest.Template] {
        category == "all" ? manifest.templates : manifest.templates.filter { $0.category == category }
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top), count: sizeClass == .regular ? 4 : 2)
    }

    var body: some View {
        NavigationStack {
            ScrollView { content }
                .background(Color(.systemGroupedBackground))
                .navigationTitle(ar ? "القوالب" : "Templates")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L.cancel) { dismiss() }
                            .accessibilityIdentifier("xr-templates-close")
                    }
                }
        }
        .tint(Color.xrTeal)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("xr-templates")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            languagePicker
            chips
            grid
            note
        }
        .padding(.top, 8)
    }

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: 20) {
            ForEach(shown) { t in card(t) }
        }
        .padding(.horizontal, 16)
        .animation(.default, value: category)
    }

    private func card(_ t: TemplateManifest.Template) -> some View {
        let label: String = t.name.text(lang) + " (." + t.officeKind.fileExtension + ")"
        let hint: String = ar ? "ينشئ ملفاً جديداً من هذا القالب" : "Creates a new file from this template"
        return Button { onPick(t, lang) } label: { TemplateCard(template: t, lang: lang) }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
            .accessibilityHint(hint)
            .accessibilityIdentifier("xr-template-" + t.id)
    }

    private var note: some View {
        let words: String = ar ? "القوالب أمثلة جاهزة للتعديل. قالب الفاتورة الضريبية قالب فقط وليس استشارة ضريبية."
                               : "Templates are examples for you to edit. The tax invoice is a template, not tax advice."
        return Text(words)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
            .accessibilityIdentifier("xr-templates-note")
    }

    /// The template's language, not the app's: an English user can still start an Arabic letter.
    private var languagePicker: some View {
        let caption: String = ar ? "لغة القالب" : "Template language"
        let order: [String] = ar ? ["ar", "en"] : ["en", "ar"]
        return HStack(spacing: 12) {
            Text(caption)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Picker(caption, selection: $lang) {
                ForEach(order, id: \.self) { code in langSegment(code) }
            }
            .pickerStyle(.segmented)
            .frame(width: 132)
            .accessibilityIdentifier("xr-templates-lang")
        }
        .padding(.horizontal, 16)
    }

    private func langSegment(_ code: String) -> some View {
        let short: String = code == "ar" ? "ع" : "EN"
        let long: String = code == "ar" ? "العربية" : "English"
        return Text(verbatim: short).accessibilityLabel(long).tag(code)
    }

    private var chips: some View {
        let all: String = ar ? "الكل" : "All"
        let code: String = ar ? "ar" : "en"
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("all", all)
                ForEach(manifest.categories) { c in chip(c.id, c.name.text(code)) }
            }
            .padding(.horizontal, 16)
        }
    }

    private func chip(_ id: String, _ title: String) -> some View {
        let on: Bool = category == id
        let fill: Color = on ? Color.xrTeal : Color(.secondarySystemGroupedBackground)
        let ink: Color = on ? Color.xrOnTeal : Color.primary
        let weight: Font.Weight = on ? .semibold : .regular
        let border: CGFloat = on ? 0 : 0.5
        let traits: AccessibilityTraits = on ? .isSelected : []
        return Button { category = id } label: {
            Text(title)
                .font(.subheadline.weight(weight))
                .foregroundStyle(ink)
                .padding(.horizontal, 16)
                .frame(minHeight: 36)
                .background(fill, in: Capsule())
                .overlay(Capsule().strokeBorder(Color(.separator), lineWidth: border))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .accessibilityAddTraits(traits)
        .accessibilityIdentifier("xr-template-cat-" + id)
    }
}

/// One gallery card: the 3:4 preview (12 pt radius, 0.5 pt border), the name at 15 pt and the format.
struct TemplateCard: View {
    let template: TemplateManifest.Template
    let lang: String

    var body: some View {
        let name: String = template.name.text(lang)
        let dir: LayoutDirection = lang == "ar" ? .rightToLeft : .leftToRight
        let tile: HomeTile = HomeTile.of(template.officeKind)
        let ext: String = "." + template.officeKind.fileExtension
        return VStack(alignment: .leading, spacing: 8) {
            TemplateThumbnail(layout: template.thumbnail, lang: lang, title: name)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(.separator), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
            Text(name)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.layoutDirection, dir)
            HStack(spacing: 4) {
                Image(systemName: tile.symbol)
                    .foregroundStyle(tile.color)
                Text(verbatim: ext)
                    .environment(\.layoutDirection, .leftToRight)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}

/// A drawn preview of each template's first page (its real layout in miniature, not a photo): always a white page,
/// as the document itself is, and mirrored for Arabic. All sizes are in units of a 150 x 200 page.
struct TemplateThumbnail: View {
    let layout: String
    let lang: String
    let title: String

    private static let accent = Color(red: 11.0 / 255, green: 110.0 / 255, blue: 127.0 / 255)
    private static let ink = Color(red: 0.12, green: 0.16, blue: 0.19)
    private static let grey = Color(red: 0.80, green: 0.83, blue: 0.85)
    private static let light = Color(red: 0.91, green: 0.945, blue: 0.953)
    private static let input = Color(red: 1, green: 0.984, blue: 0.918)
    private static let line = Color(red: 0.72, green: 0.77, blue: 0.79)

    var body: some View {
        let dir: LayoutDirection = lang == "ar" ? .rightToLeft : .leftToRight
        return GeometryReader { g in
            let u: CGFloat = g.size.width / 150
            page(u)
                .padding(12 * u)
                .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
        }
        .aspectRatio(3 / 4, contentMode: .fit)
        .background(Color.white)
        .environment(\.layoutDirection, dir)
        .environment(\.colorScheme, .light)
        .accessibilityHidden(true)
    }

    @ViewBuilder private func page(_ u: CGFloat) -> some View {
        switch layout {
        case "invoice": invoice(u)
        case "cv": cv(u)
        case "minutes": minutes(u)
        case "budget": budget(u)
        default: letter(u)
        }
    }

    // MARK: pieces

    private func bar(_ w: CGFloat, _ u: CGFloat, h: CGFloat = 2.6, _ c: Color = TemplateThumbnail.grey) -> some View {
        RoundedRectangle(cornerRadius: h * u / 2).fill(c).frame(width: w * u, height: h * u)
    }

    private func rule(_ u: CGFloat, _ c: Color = TemplateThumbnail.accent, h: CGFloat = 1) -> some View {
        Rectangle().fill(c).frame(width: 126 * u, height: h * u)
    }

    private func heading(_ text: String, _ u: CGFloat, size: CGFloat = 11) -> some View {
        Text(verbatim: text)
            .font(.system(size: size * u, weight: .bold))
            .foregroundStyle(Self.accent)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
    }

    private func lines(_ widths: [CGFloat], _ u: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 3 * u) { ForEach(widths.indices, id: \.self) { bar(widths[$0], u) } }
    }

    private func section(_ u: CGFloat, _ w: CGFloat = 34) -> some View {
        VStack(alignment: .leading, spacing: 1.5 * u) {
            bar(w, u, h: 3.2, Self.accent)
            rule(u, Self.line, h: 0.5)
        }
        .padding(.top, 3 * u)
    }

    enum Row { case header, section, total, plain, input }

    /// a table row: widths in page units; the first column carries a label bar, the rest numbers at the end side
    private func row(_ kind: Row, _ widths: [CGFloat], _ u: CGFloat, labelFill: Bool = false) -> some View {
        HStack(spacing: 0) {
            ForEach(widths.indices, id: \.self) { i in cell(kind, widths, i, u, labelFill) }
        }
    }

    private func cell(_ kind: Row, _ widths: [CGFloat], _ i: Int, _ u: CGFloat, _ labelFill: Bool) -> some View {
        let align: Alignment = i == 0 ? .leading : .trailing
        let share: CGFloat = i == 0 ? 0.6 : 0.45
        let w: CGFloat = min(widths[i] * share, 40)
        let showBar: Bool = i == 0 || kind != .section
        return ZStack(alignment: align) {
            Rectangle().fill(cellFill(kind, i, widths.count, labelFill))
            Rectangle().strokeBorder(Self.line, lineWidth: 0.4 * u)
            if showBar {
                bar(w, u, h: 1.8, cellInk(kind)).padding(.horizontal, 2 * u)
            }
        }
        .frame(width: widths[i] * u, height: 7 * u)
    }

    private func cellFill(_ kind: Row, _ i: Int, _ count: Int, _ labelFill: Bool) -> Color {
        switch kind {
        case .header: return Self.accent
        case .section, .total: return Self.light
        case .input:
            if i > 0 && i < count - 1 { return Self.input }
            return labelFill && i == 0 ? Self.light : Color.white
        case .plain:
            return labelFill && i == 0 ? Self.light : Color.white
        }
    }

    private func cellInk(_ kind: Row) -> Color {
        switch kind {
        case .header: return Color.white.opacity(0.85)
        case .section, .total: return Self.ink.opacity(0.55)
        default: return Self.grey
        }
    }

    private func dot(_ u: CGFloat) -> some View {
        Circle().fill(Self.accent).frame(width: 2 * u, height: 2 * u)
    }

    // MARK: layouts

    private func letter(_ u: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 3 * u) {
            Group {
                bar(52, u, h: 5, Self.accent)
                bar(100, u, h: 1.8)
                rule(u).padding(.vertical, 2 * u)
                lines([36, 70], u)
                lines([44, 34, 40], u).padding(.top, 5 * u)
                bar(66, u, h: 3, Self.ink.opacity(0.7)).padding(.top, 5 * u)
            }
            Group {
                lines([126, 126, 126, 92], u).padding(.top, 4 * u)
                lines([126, 126, 70], u).padding(.top, 3 * u)
                bar(40, u).padding(.top, 5 * u)
                bar(46, u, h: 3, Self.ink.opacity(0.7)).padding(.top, 12 * u)
                lines([34, 44], u)
            }
            Circle().strokeBorder(Self.accent.opacity(0.45), style: StrokeStyle(lineWidth: 0.8 * u, dash: [2 * u, 1.5 * u]))
                .frame(width: 18 * u, height: 18 * u)
                .padding(.top, 3 * u)
        }
    }

    private func invoice(_ u: CGFloat) -> some View {
        let w: [CGFloat] = [8, 50, 14, 18, 18, 18]
        return VStack(alignment: .leading, spacing: 3 * u) {
            heading(title, u, size: 12)
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 3 * u) {
                    bar(44, u, h: 3, Self.ink.opacity(0.7))
                    lines([56, 50], u)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 3 * u) { bar(34, u); bar(30, u); bar(30, u) }
            }
            .padding(.top, 2 * u)
            bar(24, u, h: 3, Self.ink.opacity(0.7)).padding(.top, 4 * u)
            lines([46, 54], u)
            VStack(spacing: 0) {
                row(.header, w, u)
                ForEach(0..<6, id: \.self) { i in row(i == 0 ? .input : .plain, w, u) }
            }
            .padding(.top, 5 * u)
            VStack(alignment: .trailing, spacing: 0) {
                row(.plain, [36, 20], u, labelFill: true)
                row(.plain, [36, 20], u, labelFill: true)
                row(.total, [36, 20], u)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.top, 3 * u)
            bar(110, u, h: 1.6, Self.grey.opacity(0.8)).padding(.top, 8 * u)
        }
    }

    private func cv(_ u: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 3 * u) {
            Group {
                bar(78, u, h: 7, Self.accent)
                bar(54, u, h: 3)
                rule(u).padding(.vertical, 1 * u)
                bar(110, u, h: 1.8)
                section(u)
                lines([126, 126, 84], u)
            }
            Group {
                section(u, 46)
                bar(80, u, h: 2.8, Self.ink.opacity(0.7))
                bar(36, u, h: 1.8)
                HStack(spacing: 3 * u) { dot(u); bar(100, u) }
                HStack(spacing: 3 * u) { dot(u); bar(80, u) }
            }
            Group {
                bar(70, u, h: 2.8, Self.ink.opacity(0.7)).padding(.top, 2 * u)
                bar(36, u, h: 1.8)
                section(u, 28)
            }
            VStack(spacing: 0) { ForEach(0..<3, id: \.self) { _ in row(.plain, [40, 86], u, labelFill: true) } }
        }
    }

    private func minutes(_ u: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 3 * u) {
            Group {
                heading(title, u, size: 12)
                bar(60, u, h: 2.6)
                rule(u).padding(.vertical, 1 * u)
                VStack(spacing: 0) { ForEach(0..<4, id: \.self) { _ in row(.plain, [38, 88], u, labelFill: true) } }
                lines([90, 60], u).padding(.top, 3 * u)
                section(u)
            }
            ForEach(1...3, id: \.self) { n in
                HStack(spacing: 3 * u) {
                    Text(verbatim: "\(n).").font(.system(size: 4.5 * u, weight: .semibold)).foregroundStyle(Self.ink.opacity(0.6))
                    bar(70, u)
                }
            }
            section(u, 40)
            lines([126, 96], u)
            section(u, 30)
            VStack(spacing: 0) {
                row(.header, [10, 62, 28, 26], u)
                ForEach(0..<3, id: \.self) { _ in row(.plain, [10, 62, 28, 26], u) }
            }
        }
    }

    private func budget(_ u: CGFloat) -> some View {
        let w: [CGFloat] = [54, 24, 24, 24]
        return VStack(alignment: .leading, spacing: 3 * u) {
            heading(title, u, size: 12)
            bar(84, u, h: 2.4)
            VStack(spacing: 0) {
                row(.header, w, u)
                row(.section, w, u)
                row(.input, w, u); row(.input, w, u)
                row(.total, w, u)
                row(.section, w, u)
                ForEach(0..<9, id: \.self) { _ in row(.input, w, u) }
                row(.total, w, u)
            }
            .padding(.top, 5 * u)
            VStack(spacing: 0) { row(.total, w, u); row(.input, w, u) }.padding(.top, 4 * u)
        }
    }
}

#if XR_AUTOTEST
/// CI only (build configuration "Autotest", XR_GALLERY=1): the gallery sheet over an empty screen; the chosen
/// template is made with NewDocuments.create(from:lang:) - the app's own path - and opened in the test editor
/// (AutotestScreen), with the new file's name in a label ("xr-template-file") for the test.
struct TemplateAutotestRoot: View {
    @State private var showGallery = true
    @State private var picked: (TemplateManifest.Template, String)?
    @State private var created: String?
    @State private var failure = ""
    private let ar = (ProcessInfo.processInfo.environment["XR_LANG"] ?? AppLanguage.current) == "ar"

    var body: some View {
        if let created {
            AutotestScreen(open: created)
                .overlay(alignment: .bottomLeading) {
                    Text(created).font(.system(size: 6)).opacity(0.02).accessibilityIdentifier("xr-template-file")
                }
        } else {
            Text(failure).font(.system(size: 6)).accessibilityIdentifier("xr-template-error")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemGroupedBackground))
                .environment(\.layoutDirection, ar ? .rightToLeft : .leftToRight)
                .sheet(isPresented: $showGallery, onDismiss: make) {
                    TemplateGallerySheet(ar: ar) { t, lang in
                        picked = (t, lang)
                        showGallery = false
                    }
                    .environment(\.layoutDirection, ar ? .rightToLeft : .leftToRight)
                    .interactiveDismissDisabled()
                }
        }
    }

    private func make() {
        guard let p = picked else { failure = "template: none picked"; return }
        let (t, lang) = p
        do {
            let url = try NewDocuments.create(from: t, lang: lang)
            NSLog("XR template %@ (%@) -> %@", t.id, lang, url.lastPathComponent)
            created = url.lastPathComponent
        } catch {
            failure = "template: " + error.localizedDescription
        }
    }
}
#endif
