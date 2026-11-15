import SwiftUI
import UIKit

/// Read-first opening (plan S2). Most phone opens are for reading: a Word document or a PDF opened from Recent, Browse,
/// Open-in or Share opens calm and full height - no tab row, no status bar, no keyboard coming up at a tap, no
/// accidental edit - and the top bar's trailing text button "Edit" / "تحرير" switches to editing ("Done" / "تم" goes
/// back). New documents and templates open straight into editing (DocumentOpener passes the mode in).
///
/// What reading state is lives in the editor (web/xr-host.js "reading view"): the engine's own view restriction
/// (asc_setRestriction, no reload - undo, selection and zoom stay), its keyboard input field read-only and the edit chrome
/// hidden by CSS. The app's side: the Edit / Done button (EditorTopBar), Undo / Aa / the PDF tool bar hidden while
/// reading, and a floating page capsule ("3 / 12") that fades 1.5 s after scrolling; a tap on it opens Go to Page.
///
/// The mode is remembered per file (ReadingMemory): a file last left in editing reopens in editing. The setting
/// "Open Files in Reading View" (Home ⋯ menu, UserDefaults "xr.readingView", default on) turns read-first opening off.
/// Spreadsheets and presentations keep opening for editing (their phone chrome, plans S3 / S4, is editing-first).
final class ReadingModel: ObservableObject {
    static let settingKey = "xr.readingView"
    /// Unset = on. object(forKey:) is nil when unset; bool(forKey:) also reads the launch-argument form ("NO").
    static var settingOn: Bool { UserDefaults.standard.object(forKey: settingKey) == nil || UserDefaults.standard.bool(forKey: settingKey) }
    /// The kinds that have a reading view.
    static func supports(_ kind: OfficeKind) -> Bool { kind == .word || kind == .pdf }
    /// No reading view (other kinds, CI screens): no Edit / Done, never reading. Never toggled, so it can be shared.
    static let off = ReadingModel(available: false, reading: false)

    /// The document has a reading view (the bar shows Edit / Done).
    let available: Bool
    /// Reading (true) or editing. Changes only on the Edit / Done tap: the top bar observes this object, and a redraw of
    /// the bar while its ⋯ menu is open would leave that menu dead (EditorScreen) - the button is outside the menu.
    @Published private(set) var reading: Bool
    /// The editor's answers (log, CI probe): its own object, so an answer never redraws the top bar.
    let engine = ReadingEngine()

    init(available: Bool, reading: Bool) {
        self.available = available
        self.reading = available && reading
    }

    /// How a file opens: new documents and templates for editing; any other Word document / PDF in reading state, unless
    /// the setting is off or the file was last left in editing.
    static func forOpening(_ url: URL, kind: OfficeKind, isNew: Bool) -> ReadingModel {
        guard supports(kind) else { return off }
        let read = !isNew && settingOn && (ReadingMemory.reading(url) ?? true)
        NSLog("XR reading view: %@ opens %@ (new=%ld setting=%ld remembered=%@)", url.lastPathComponent,
              read ? "reading" : "editing", isNew ? 1 : 0, settingOn ? 1 : 0,
              ReadingMemory.reading(url).map { $0 ? "reading" : "editing" } ?? "-")
        return ReadingModel(available: true, reading: read)
    }

    /// Edit / Done: flips the mode (the bar's items fade over 200 ms, at once with Reduce Motion), remembers it for the
    /// file and tells the editor.
    func toggle(_ controller: EditorController, file: URL?, reduceMotion: Bool) {
        guard available else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { reading.toggle() }
        remember(file)
        apply(controller)
    }

    /// Tells the editor the current mode: on each Edit / Done and whenever the editor page is (re)loaded ("ready": the
    /// first open, a language switch, the reopen after a web-process crash). Idempotent in the editor.
    func apply(_ controller: EditorController) {
        guard available else { return }
        let engine = self.engine
        controller.setReading(reading) { answer in engine.answered(answer) }
    }

    /// The mode is kept for the file (a toggle, the editor closing).
    func remember(_ file: URL?) {
        guard available, let file else { return }
        ReadingMemory.set(reading, for: file)
    }
}

/// The editor's answers to the reading switches (CI probe, Autotest build): a count and the last answer.
final class ReadingEngine: ObservableObject {
    @Published private(set) var applied = 0
    @Published private(set) var answer = ""
    func answered(_ s: String) { applied += 1; answer = s }
}

/// The reading / editing mode each file was last left in (plan S2: "remembered per file"): UserDefaults
/// "xr.readingModes", most recent first, at most 200 files. Keyed by the file's resolved path, so /var and /private/var
/// forms of the same file match; a renamed file is recorded again under its new name when the editor closes.
enum ReadingMemory {
    private static let key = "xr.readingModes"
    private static let limit = 200

    static func id(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }

    static func reading(_ url: URL) -> Bool? {
        let p = id(url)
        let list = UserDefaults.standard.array(forKey: key) as? [[String: Any]] ?? []
        return list.first { ($0["p"] as? String) == p }?["r"] as? Bool
    }

    static func set(_ reading: Bool, for url: URL) {
        let p = id(url)
        var list = (UserDefaults.standard.array(forKey: key) as? [[String: Any]] ?? []).filter { ($0["p"] as? String) != p }
        list.insert(["p": p, "r": reading], at: 0)
        UserDefaults.standard.set(Array(list.prefix(limit)), forKey: key)
    }
}

/// The top bar's Edit / Done (a text button, as in Pages / Files): 44 pt target, semibold, never wrapped.
struct ReadingButton: View {
    @ObservedObject var model: ReadingModel
    var ar: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(model.reading ? BarText.edit(ar) : BarText.done(ar))
                .font(.body.weight(.semibold))
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(model.reading ? BarText.edit(ar) : BarText.done(ar))
        .accessibilityHint(model.reading ? BarText.editHint(ar) : BarText.doneHint(ar))
        .accessibilityIdentifier("xr-bar-edit")
    }
}

/// Shows `content` only while editing (the PDF tool bar, plan S7, is edit chrome).
struct HiddenWhileReading<Content: View>: View {
    @ObservedObject var model: ReadingModel
    @ViewBuilder var content: () -> Content

    var body: some View {
        if !model.reading { content() }
    }
}

/// The reading state's own chrome over the editor: the floating page capsule, its Go to Page alert and (Autotest build
/// only) the CI probe.
struct ReadingChrome: ViewModifier {
    @ObservedObject var model: ReadingModel
    let state: EditorState
    let controller: EditorController
    var ar: Bool
    @State private var goTo = false
    @State private var pageText = ""

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if model.reading {
                    PageCapsule(state: state, ar: ar) { pageText = ""; goTo = true }
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .topLeading) { ReadingProbe(model: model, engine: model.engine, controller: controller) }
            .alert(BarText.goToPage(ar), isPresented: $goTo) {
                TextField(BarText.pageNumber(ar), text: $pageText)
                    .keyboardType(.numberPad)
                    .accessibilityIdentifier("xr-read-page-field")
                Button(BarText.go(ar)) {
                    // any digits the keyboard typed (Arabic-Indic ones too: wholeNumberValue reads them), at most 6
                    let n = pageText.compactMap(\.wholeNumberValue).prefix(6).reduce(0) { $0 * 10 + $1 }
                    if n >= 1 { controller.goToPage(min(n, max(state.pages, 1)) - 1) }
                }
                .accessibilityIdentifier("xr-read-page-go")
                Button(BarText.cancel(ar), role: .cancel) {}
            } message: {
                Text(BarText.pageRange(max(state.pages, 1), ar))
            }
    }
}

/// "3 / 12" (13 pt, .regularMaterial - solid under Reduce Transparency), at the bottom of the page while reading. It
/// shows on opening, while a finger moves the page and when the page changes, and fades 1.5 s after (at once with Reduce
/// Motion; never with VoiceOver on, so it stays reachable). A tap opens Go to Page. Digits are never mirrored.
private struct PageCapsule: View {
    @ObservedObject var state: EditorState
    var ar: Bool
    var tap: () -> Void
    @State private var visible = true
    @State private var fade: DispatchWorkItem?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    var body: some View {
        let n = max(state.pages, 1), p = min(max(state.page + 1, 1), n)
        Button(action: tap) {
            Text(verbatim: "\(p) / \(n)")                    // the same digits as its spoken label
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .frame(minHeight: 28)
                .background(.regularMaterial, in: Capsule())
                .environment(\.layoutDirection, .leftToRight)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .accessibilityHidden(!visible)
        .accessibilityLabel(BarText.page(p, n, ar))
        .accessibilityHint(BarText.goToPage(ar))
        .accessibilityIdentifier("xr-read-page")
        .padding(.bottom, 12)
        .onAppear(perform: show)
        .onChange(of: state.page) { _, _ in show() }
        .onChange(of: state.pages) { _, _ in show() }
        .onChange(of: state.moving) { _, _ in show() }
    }

    /// Visible now; fades 1.5 s after the last movement (not while a finger still moves the page).
    private func show() {
        fade?.cancel()
        if !visible { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { visible = true } }
        guard !state.moving, !voiceOver else { return }
        let work = DispatchWorkItem { [reduceMotion] in
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { visible = false }
        }
        fade = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }
}

/// CI only (Autotest build): "read<n>:<the editor's own reading state> app=<0|1>", n = how many switches the editor
/// answered. The state is read from the editor itself (__xrReadState: restriction, input field, chrome, page) every
/// 0.5 s. Any other build: nothing.
#if XR_AUTOTEST
private struct ReadingProbe: View {
    @ObservedObject var model: ReadingModel
    @ObservedObject var engine: ReadingEngine
    let controller: EditorController
    @State private var page = "-"
    private static let tick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Text("read\(engine.applied):\(page) app=\(model.reading ? 1 : 0)")
            .font(.system(size: 6))
            .lineLimit(1)
            .frame(maxWidth: 40, alignment: .leading)
            .opacity(model.available ? 0.02 : 0)
            .allowsHitTesting(false)
            .accessibilityIdentifier("xr-read-probe")
            .onReceive(Self.tick) { _ in
                guard model.available else { return }
                controller.call("return window.__xrReadState ? __xrReadState() : 'none';") { r, e in
                    page = (r as? String) ?? (e ?? "none")
                }
            }
    }
}
#else
private struct ReadingProbe: View {
    let model: ReadingModel
    let engine: ReadingEngine
    let controller: EditorController
    var body: some View { EmptyView() }
}
#endif

extension View {
    /// The page capsule + Go to Page while reading (plan S2); `.off` = nothing.
    func readingChrome(_ model: ReadingModel, state: EditorState, controller: EditorController, ar: Bool) -> some View {
        modifier(ReadingChrome(model: model, state: state, controller: controller, ar: ar))
    }
}
