import SwiftUI
import UIKit

/// Presentations (plan S4): the slide gets the screen, adding a slide takes one tap, and presenting is native.
///
/// - iPhone portrait: a native slide strip under the editor (84 pt: 96 x 54 pt thumbnails, 8 pt gaps, the current
///   slide outlined 2.5 pt in the slides accent, 11 pt numbers, a trailing dashed '+' that opens a native layout
///   picker). Long-press a thumbnail: Duplicate, Hide / Show, Move earlier / later, Delete. The strip hides while the
///   keyboard is up and during Present. The editor's own strip stays collapsed on phones (xr-host.js).
/// - Present (play.fill in the nav bar, every device): the editor's own slide show from the current slide, with the
///   nav bar, status bar and home indicator hidden. A tap or a swipe advances, a swipe back goes back, a double tap
///   or ✕ ends. Orientation is never forced: in portrait the slide is letterboxed and a one-time hint says to rotate.
///
/// Engine side: web/xr-host.js __xrSlideThumbs / __xrSlideLayouts / __xrSlideDo / __xrPresent, and the state keys
/// slides / slide / presenting / showSlide (EditorState). Every call runs on a tap, or once after a slide change -
/// never on the keystroke path. This modifier observes only its own model (present on / off, keyboard up / down), so
/// a caret move never redraws the screen or the top bar around it; the strip and the overlay observe the editor
/// state themselves.
struct SlidesChrome: ViewModifier {
    var enabled: Bool
    var controller: EditorController
    var ar: Bool
    @StateObject private var model = SlidesModel()
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var phone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            slides(content)
        } else {
            content
        }
    }

    private func slides(_ content: Content) -> some View {
        let strip = phone && verticalSizeClass != .compact && !model.presenting && !model.keyboardUp
        return VStack(spacing: 0) {
            content
            if strip {
                SlideStrip(state: controller.state, model: model, ar: ar)
            }
        }
        .overlay {
            if model.presenting {
                PresentOverlay(state: controller.state, model: model, ar: ar)
            }
        }
        .background { SlidesStateBridge(state: controller.state, model: model) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                PresentButton(model: model, ar: ar)
            }
        }
        .toolbar(model.presenting ? .hidden : .automatic, for: .navigationBar)
        .statusBarHidden(model.presenting)
        .persistentSystemOverlays(model.presenting ? .hidden : .automatic)
        .sheet(isPresented: $model.showLayouts) {
            LayoutPicker(model: model, ar: ar)
        }
        .onAppear {
            model.controller = controller
            model.stripOn = phone
        }
    }
}

extension View {
    /// The presentation chrome (plan S4) when `enabled` (a presentation is open); otherwise the view is unchanged.
    func slidesChrome(enabled: Bool, controller: EditorController, ar: Bool) -> some View {
        modifier(SlidesChrome(enabled: enabled, controller: controller, ar: ar))
    }
}

/// Words, EN + AR.
enum SlideText {
    static func present(_ ar: Bool) -> String { ar ? "عرض الشرائح" : "Present" }
    static func endShow(_ ar: Bool) -> String { ar ? "إنهاء العرض" : "End Show" }
    static func slideShow(_ ar: Bool) -> String { ar ? "عرض الشرائح" : "Slide show" }
    static func slide(_ n: Int, _ ar: Bool) -> String { ar ? "الشريحة \(n)" : "Slide \(n)" }
    static func slides(_ ar: Bool) -> String { ar ? "الشرائح" : "Slides" }
    static func newSlide(_ ar: Bool) -> String { ar ? "شريحة جديدة" : "New Slide" }
    static func chooseLayout(_ ar: Bool) -> String { ar ? "اختر تخطيطًا" : "Choose a Layout" }
    static func cancel(_ ar: Bool) -> String { ar ? "إلغاء" : "Cancel" }
    static func duplicate(_ ar: Bool) -> String { ar ? "تكرار" : "Duplicate" }
    static func delete(_ ar: Bool) -> String { ar ? "حذف" : "Delete" }
    static func hide(_ ar: Bool) -> String { ar ? "إخفاء في العرض" : "Hide in Show" }
    static func show(_ ar: Bool) -> String { ar ? "إظهار في العرض" : "Show in Show" }
    static func hidden(_ ar: Bool) -> String { ar ? "مخفية" : "hidden" }
    static func moveEarlier(_ ar: Bool) -> String { ar ? "نقل إلى السابق" : "Move Earlier" }
    static func moveLater(_ ar: Bool) -> String { ar ? "نقل إلى التالي" : "Move Later" }
    static func rotateHint(_ ar: Bool) -> String { ar ? "دوِّر الجهاز لشريحة أكبر" : "Rotate for a larger slide" }
}

/// One layout of the '+' picker (the editor's own "Add slide" list).
struct SlideLayoutItem: Identifiable {
    let id: Int
    let index: Int?
    let title: String
    let image: UIImage?
}

/// The presentation chrome's own state: present on / off, keyboard up / down, the strip's thumbnails and the layout
/// picker. Talks to the editor only through EditorController.call.
final class SlidesModel: ObservableObject {
    @Published var presenting = false
    @Published var keyboardUp = false
    @Published var thumbs: [Int: UIImage] = [:]
    @Published var hidden: Set<Int> = []
    @Published var layouts: [SlideLayoutItem] = []
    @Published var showLayouts = false
    weak var controller: EditorController?
    /// The native strip is shown on this device (iPhone): only then are thumbnails drawn.
    var stripOn = false
    /// The editor's current slide (0-based), kept by SlidesStateBridge.
    var current = 0
    private var observers: [NSObjectProtocol] = []
    private var running = false
    private var queued = Set<Int>()
    private var queuedAll = false
    private var soon: DispatchWorkItem?
    /// Thumbnail width in pixels: 96 pt at 3x.
    private let px = 288

    init() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setKeyboard(true)
        })
        observers.append(nc.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setKeyboard(false)
        })
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    private func setKeyboard(_ up: Bool) {
        if keyboardUp != up { keyboardUp = up }
        if !up { refresh([current]) }          // what was typed shows in the strip once it is back
    }

    private func log(_ text: String) {
        controller?.coordinator?.parent.onCommand("log", text)
    }

    // MARK: thumbnails

    /// Draws thumbnails again: all slides, or the given ones. Runs are serial (one engine call at a time).
    func refresh(all: Bool = false, _ indices: [Int] = []) {
        guard stripOn else { return }
        if all { queuedAll = true } else { queued.formUnion(indices.filter { $0 >= 0 }) }
        pump()
    }

    /// The current slide again a moment after the document changed (debounced; never while typing or presenting).
    func refreshSoon(_ delay: Double = 1.5, all: Bool = false) {
        guard stripOn else { return }
        soon?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.keyboardUp, !self.presenting else { return }
            if all { self.refresh(all: true) } else { self.refresh([self.current]) }
        }
        soon = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func pump() {
        guard !running, controller != nil else { return }
        if queuedAll {
            queuedAll = false
            queued.removeAll()
            runAll(from: 0)
            return
        }
        guard let i = queued.min() else { return }
        queued.remove(i)
        run(i, i) { [weak self] _ in self?.pump() }
    }

    private func runAll(from: Int) {
        run(from, from + 7) { [weak self] n in
            guard let self else { return }
            if from + 8 < min(n, 400) && !self.queuedAll { self.runAll(from: from + 8) } else { self.pump() }
        }
    }

    private func run(_ a: Int, _ b: Int, done: @escaping (Int) -> Void) {
        guard let controller else { return }
        running = true
        controller.call("return window.__xrSlideThumbs ? __xrSlideThumbs(\(a), \(b), \(px)) : 'no slides';") { [weak self] r, e in
            guard let self else { return }
            self.running = false
            var n = 0
            if let s = r as? String, let d = s.data(using: .utf8),
               let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
                n = (o["n"] as? NSNumber)?.intValue ?? 0
                var thumbs = self.thumbs, hidden = self.hidden
                for item in (o["slides"] as? [[String: Any]]) ?? [] {
                    guard let i = (item["i"] as? NSNumber)?.intValue else { continue }
                    if let img = item["img"] as? String, let image = SlidesModel.image(dataURL: img) { thumbs[i] = image }
                    if (item["hidden"] as? Bool) == true { hidden.insert(i) } else { hidden.remove(i) }
                }
                thumbs = thumbs.filter { $0.key < n }
                hidden = hidden.filter { $0 < n }
                self.thumbs = thumbs
                self.hidden = hidden
            } else {
                self.log("slide thumbs: " + ((r as? String) ?? e ?? "?"))
            }
            done(n)
        }
    }

    static func image(dataURL: String) -> UIImage? {
        guard dataURL.hasPrefix("data:image"), let comma = dataURL.firstIndex(of: ",") else { return nil }
        guard let d = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])) else { return nil }
        return UIImage(data: d)
    }

    // MARK: strip actions

    /// A strip action on slide `index` (xr-host.js __xrSlideDo): go, add (arg = layout index), duplicate, delete,
    /// hide (arg true / false), earlier, later. `arg` is built by this file only (a number, true / false, undefined).
    func act(_ op: String, _ index: Int, _ arg: String = "undefined") {
        let safe = op.filter { $0.isLetter }
        controller?.call("return window.__xrSlideDo ? __xrSlideDo('\(safe)', \(index), \(arg)) : 'no slides';") { [weak self] r, e in
            guard let self else { return }
            self.log("slide \(safe) \(index): " + ((r as? String) ?? e ?? "?"))
            if safe != "go" { self.refresh(all: true) }
        }
    }

    func loadLayouts() {
        controller?.call("return window.__xrSlideLayouts ? __xrSlideLayouts() : '[]';") { [weak self] r, _ in
            guard let self, let s = r as? String, let d = s.data(using: .utf8),
                  let a = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] else { return }
            self.layouts = a.enumerated().map { n, o in
                SlideLayoutItem(id: n, index: (o["idx"] as? NSNumber)?.intValue, title: (o["title"] as? String) ?? "",
                                image: (o["img"] as? String).flatMap { SlidesModel.image(dataURL: $0) })
            }
        }
    }

    // MARK: Present

    func startPresent() {
        controller?.hideKeyboard()
        controller?.call("return window.__xrPresent ? __xrPresent('start') : 'no present';") { [weak self] r, e in
            guard let self else { return }
            let res = (r as? String) ?? e ?? "?"
            self.log("present start: " + res)
            if res == "ok" && !self.presenting { self.presenting = true }
        }
    }

    /// next | prev | end
    func present(_ op: String) {
        let safe = op.filter { $0.isLetter }
        if safe == "end" && presenting { presenting = false }
        controller?.call("return window.__xrPresent ? __xrPresent('\(safe)') : 'no present';") { [weak self] r, e in
            self?.log("present \(safe): " + ((r as? String) ?? e ?? "?"))
        }
        if safe == "end" { refreshSoon(0.8) }
    }
}

/// Follows the editor state for the model (in its own small view, so the screen around it never redraws on a change).
private struct SlidesStateBridge: View {
    @ObservedObject var state: EditorState
    var model: SlidesModel

    var body: some View {
        Color.clear
            .onChange(of: state.presenting) { _, p in if model.presenting != p { model.presenting = p } }
            .onChange(of: state.slides) { old, _ in
                model.refresh(all: true)
                if old == 0 { model.refreshSoon(3, all: true) }      // the first draw can come before the fonts
            }
            .onChange(of: state.slide) { old, new in
                model.current = new
                model.refresh([old, new])
            }
            .onChange(of: state.updates) { _, _ in model.refreshSoon() }
            .accessibilityHidden(true)
    }
}

/// The nav bar's Present button (play.fill: a play glyph is never mirrored).
private struct PresentButton: View {
    var model: SlidesModel
    var ar: Bool

    var body: some View {
        Button { model.startPresent() } label: {
            Image(systemName: "play.fill")
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(SlideText.present(ar))
        .accessibilityIdentifier("xr-bar-present")
    }
}

/// The bar colour of the editor's own status bar just above (xr-host.js neutralChrome): #F9F9F9 / #1C1C1E.
private let stripBar = Color(uiColor: UIColor { t in
    t.userInterfaceStyle == .dark ? UIColor(red: 28 / 255, green: 28 / 255, blue: 30 / 255, alpha: 1)
                                  : UIColor(red: 249 / 255, green: 249 / 255, blue: 249 / 255, alpha: 1)
})

/// The phone's slide strip: thumbnails of every slide and the '+' tile at the end. Mirrored in Arabic as one piece
/// (the stack follows the layout direction; numbers are never mirrored).
private struct SlideStrip: View {
    @ObservedObject var state: EditorState
    @ObservedObject var model: SlidesModel
    var ar: Bool

    var body: some View {
        let count = max(state.slides, 0)
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 8) {
                    ForEach(0..<count, id: \.self) { i in
                        SlideThumb(index: i, count: count, image: model.thumbs[i], hidden: model.hidden.contains(i),
                                   current: i == state.slide, ar: ar, model: model)
                            .id(i)
                    }
                    AddSlideTile(ar: ar) { model.showLayouts = true }
                }
                .padding(.horizontal, 12)
                .padding(.top, 7)
                .frame(height: 84, alignment: .top)
            }
            .onChange(of: state.slide) { _, i in proxy.scrollTo(i, anchor: .center) }
            .onAppear { if count > 0 { proxy.scrollTo(min(state.slide, count - 1), anchor: .center) } }
        }
        .frame(height: 84)
        .background(stripBar.ignoresSafeArea(.container, edges: .bottom))
        .overlay(alignment: .top) { Divider() }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(SlideText.slides(ar))
        .accessibilityIdentifier("xr-slide-strip")
    }
}

private struct SlideThumb: View {
    var index: Int
    var count: Int
    var image: UIImage?
    var hidden: Bool
    var current: Bool
    var ar: Bool
    var model: SlidesModel

    var body: some View {
        Button { model.act("go", index) } label: {
            VStack(spacing: 3) {
                ZStack {
                    Color.white
                    if let image {
                        Image(uiImage: image).resizable().scaledToFit()
                    }
                }
                .frame(width: 96, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .opacity(hidden ? 0.45 : 1)
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(current ? Color.xrPresentation : Color(uiColor: .separator),
                                      lineWidth: current ? 2.5 : 0.5)
                }
                .overlay(alignment: .topTrailing) {
                    if hidden {
                        Image(systemName: "eye.slash")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(3)
                            .background(.thinMaterial, in: Circle())
                            .padding(3)
                    }
                }
                Text(verbatim: String(index + 1))
                    .font(.system(size: 11, weight: current ? .semibold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(current ? Color.primary : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { model.act("duplicate", index) } label: {
                Label(SlideText.duplicate(ar), systemImage: "plus.square.on.square")
            }
            .accessibilityIdentifier("xr-slide-duplicate")
            Button { model.act("hide", index, hidden ? "false" : "true") } label: {
                Label(hidden ? SlideText.show(ar) : SlideText.hide(ar), systemImage: hidden ? "eye" : "eye.slash")
            }
            .accessibilityIdentifier("xr-slide-hide")
            if index > 0 {
                Button { model.act("earlier", index) } label: {
                    Label(SlideText.moveEarlier(ar), systemImage: "arrow.backward")
                }
                .accessibilityIdentifier("xr-slide-earlier")
            }
            if index < count - 1 {
                Button { model.act("later", index) } label: {
                    Label(SlideText.moveLater(ar), systemImage: "arrow.forward")
                }
                .accessibilityIdentifier("xr-slide-later")
            }
            if count > 1 {
                Button(role: .destructive) { model.act("delete", index) } label: {
                    Label(SlideText.delete(ar), systemImage: "trash")
                }
                .accessibilityIdentifier("xr-slide-delete")
            }
        }
        .accessibilityLabel(SlideText.slide(index + 1, ar) + (hidden ? ", " + SlideText.hidden(ar) : ""))
        .accessibilityAddTraits(current ? .isSelected : [])
        .accessibilityIdentifier("xr-slide-thumb-\(index)")
    }
}

/// The dashed '+' at the end of the strip: opens the layout picker.
private struct AddSlideTile: View {
    var ar: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .frame(width: 54, height: 54)
                .overlay {
                    Image(systemName: "plus")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.xrTeal)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(SlideText.newSlide(ar))
        .accessibilityIdentifier("xr-slide-add")
    }
}

/// The native layout picker of the '+' tile: the editor's own layouts with their pictures; a tap adds a slide with
/// that layout after the current one. While the layouts load (or when the editor has none) one big "New Slide"
/// button adds a slide with the editor's own choice.
private struct LayoutPicker: View {
    @ObservedObject var model: SlidesModel
    var ar: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                if model.layouts.isEmpty {
                    Button {
                        model.act("add", model.current)
                        dismiss()
                    } label: {
                        Label(SlideText.newSlide(ar), systemImage: "plus")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(16)
                    .accessibilityIdentifier("xr-slide-layout-default")
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 16) {
                        ForEach(model.layouts) { l in
                            Button {
                                model.act("add", model.current, l.index.map { String($0) } ?? "undefined")
                                dismiss()
                            } label: {
                                VStack(spacing: 6) {
                                    ZStack {
                                        Color.white
                                        if let image = l.image { Image(uiImage: image).resizable().scaledToFit() }
                                    }
                                    .frame(height: 84)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .strokeBorder(Color(uiColor: .separator), lineWidth: 0.5)
                                    }
                                    Text(l.title.isEmpty ? SlideText.newSlide(ar) : l.title)
                                        .font(.footnote)
                                        .foregroundStyle(Color.primary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.center)
                                }
                                .frame(maxWidth: .infinity)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(l.title.isEmpty ? SlideText.newSlide(ar) : l.title)
                            .accessibilityIdentifier("xr-slide-layout-\(l.id)")
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle(SlideText.chooseLayout(ar))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(SlideText.cancel(ar)) { dismiss() }
                        .accessibilityIdentifier("xr-slide-layouts-cancel")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .environment(\.layoutDirection, ar ? .rightToLeft : .leftToRight)
        .onAppear { model.loadLayouts() }
    }
}

/// Present: full-screen over the editor's slide show. Tap or swipe forward = next, swipe back = previous, double tap
/// or ✕ = end. VoiceOver: swipe up / down on the show (adjustable) steps through the slides.
private struct PresentOverlay: View {
    @ObservedObject var state: EditorState
    @ObservedObject var model: SlidesModel
    var ar: Bool
    @AppStorage("xr.present.rotateHintShown") private var hintShown = false
    @State private var showHint = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topTrailing) {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { model.present("end") }
                    .onTapGesture { model.present("next") }
                    .gesture(DragGesture(minimumDistance: 24).onEnded { v in
                        let dx = v.translation.width
                        guard abs(dx) > abs(v.translation.height) else { return }
                        // forward = against the reading direction (left in English, right in Arabic)
                        let forward = ar ? dx > 0 : dx < 0
                        model.present(forward ? "next" : "prev")
                    })
                    .accessibilityElement()
                    .accessibilityLabel(SlideText.slideShow(ar))
                    .accessibilityValue(SlideText.slide(state.showSlide + 1, ar))
                    .accessibilityAdjustableAction { d in
                        switch d {
                        case .increment: model.present("next")
                        case .decrement: model.present("prev")
                        @unknown default: break
                        }
                    }
                    .accessibilityIdentifier("xr-present-overlay")
                Button { model.present("end") } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                }
                .padding(.top, max(geo.safeAreaInsets.top, 12))
                .padding(.horizontal, 16)
                .accessibilityLabel(SlideText.endShow(ar))
                .accessibilityIdentifier("xr-present-end")
                if showHint {
                    Text(SlideText.rotateHint(ar))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 18)
                        .frame(height: 36)
                        .background(Capsule().fill(Color.black.opacity(0.65)))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, max(geo.safeAreaInsets.bottom, 12) + 28)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("xr-present-rotate-hint")
                }
            }
            .onAppear {
                // once ever, and only in portrait: the slide is letterboxed there, the device is never rotated for them
                guard geo.size.height > geo.size.width, !hintShown else { return }
                hintShown = true
                showHint = true
                UIAccessibility.post(notification: .announcement, argument: SlideText.rotateHint(ar))
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { showHint = false }
            }
        }
        .ignoresSafeArea()
    }
}
