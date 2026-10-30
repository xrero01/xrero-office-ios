import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The start screen, content first (plan M8): a large "Xrero Office" title that collapses on scroll, one row of
/// create tiles, Browse files / Open a PDF, then the Recent files with real first-page thumbnails, swipe and context
/// actions and search. A native inset-grouped List, so large titles, swipe actions, search, Dynamic Type, dark mode and
/// right-to-left mirroring all come from the system instead of being imitated.
struct HomeScene: View {
    @StateObject private var opener = DocumentOpener()
    @ObservedObject private var recents = RecentFiles.shared
    @ObservedObject private var account = XreroAccount.shared
    /// The one language source (OfficeDocument.swift): observed so a switch in the More menu re-words Home at once.
    @ObservedObject private var language = AppLanguage.shared
    /// The optional account has been offered and answered: "Not now" on the Home card, signing in, or (20.1) the
    /// first-launch sheet. The key is the 20.1 one, so an update does not offer the account a second time.
    @AppStorage("xr.welcomeShown") private var accountOffered = false
    @State private var showAccount = false
    @State private var showAbout = false
    @State private var missing: String?
    @State private var query = ""
    @State private var share: ShareFile?
    @State private var sharedScoped: URL?                 // security-scoped access held while the share sheet is up
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.openURL) private var openURL

    private var ar: Bool { language.isArabic }

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private var shownRecents: [RecentFiles.Item] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return recents.items }
        return recents.items.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                if searching {
                    searchResults
                } else {
                    if !accountOffered && !account.isSignedIn { accountCard }
                    createSection
                    openSection
                    recentSection
                }
            }
            .listStyle(.insetGrouped)
            .accessibilityIdentifier("xr-home-list")
            .navigationTitle("Xrero Office")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic),
                        prompt: ar ? "البحث في الملفات الأخيرة" : "Search recent files")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Image("Logo")
                        .resizable().scaledToFit()
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .accessibilityHidden(true)
                }
                ToolbarItem(placement: .topBarTrailing) { moreMenu }
            }
            .sheet(isPresented: $showAbout) { AboutSheet() }
            .sheet(item: $share, onDismiss: {
                sharedScoped?.stopAccessingSecurityScopedResource()
                sharedScoped = nil
            }) { ShareSheet(items: [$0.url]) }
        }
        .background(PresenterAnchor(opener: opener).frame(width: 0, height: 0))
        .sheet(isPresented: $showAccount) { AccountView() }
        .onChange(of: account.isSignedIn) { _, signedIn in if signedIn { accountOffered = true } }
        .alert(ar ? "تعذّر العثور على الملف" : "File not found", isPresented: Binding(
            get: { missing != nil }, set: { if !$0 { missing = nil } })) {
            Button(L.ok, role: .cancel) {}
        } message: { Text(missing ?? "") }
        .onOpenURL { url in
            if url.isFileURL { opener.openExternal(url) }        // "Open in Xrero Office" from Files / Share
        }
        .task {
            // no sign-in wall: the account is optional and never presented by itself (the Home card offers it)
            await XreroAccount.shared.refresh()
            NSLog("XR start accountOffered=%ld signedIn=%ld", accountOffered ? 1 : 0, XreroAccount.shared.isSignedIn ? 1 : 0)
        }
    }

    // MARK: header menu

    /// ⋯: the account, the interface language, About & Licences, privacy and feedback - one place, like iWork's menu.
    private var moreMenu: some View {
        Menu {
            Button { showAccount = true } label: {
                Label(account.isSignedIn ? (ar ? "الحساب" : "Account") : (ar ? "تسجيل الدخول" : "Sign in"),
                      systemImage: account.isSignedIn ? "person.crop.circle.fill" : "person.crop.circle")
            }
            .accessibilityIdentifier("xr-home-account")
            Menu {
                // the language names are written in their own language, as iOS does; the change is immediate
                Button { AppLanguage.set("en") } label: {
                    if !ar { Label("English", systemImage: "checkmark") } else { Text("English") }
                }
                .accessibilityIdentifier("xr-home-lang-en")
                Button { AppLanguage.set("ar") } label: {
                    if ar { Label("العربية", systemImage: "checkmark") } else { Text("العربية") }
                }
                .accessibilityIdentifier("xr-home-lang-ar")
            } label: {
                Label(ar ? "اللغة" : "Language", systemImage: "globe")
            }
            .accessibilityIdentifier("xr-home-lang")
            Divider()
            Button { showAbout = true } label: {
                Label(ar ? "حول التطبيق والتراخيص" : "About & Licences", systemImage: "info.circle")
            }
            .accessibilityIdentifier("xr-home-about")
            Button { openURL(URL(string: "https://xrero.com/privacy")!) } label: {
                Label(ar ? "سياسة الخصوصية" : "Privacy Policy", systemImage: "hand.raised")
            }
            .accessibilityIdentifier("xr-home-privacy")
            Button { openURL(URL(string: "mailto:info@xrero.com?subject=Xrero%20Office%20for%20iPhone%20and%20iPad")!) } label: {
                Label(ar ? "إرسال ملاحظات" : "Send Feedback", systemImage: "envelope")
            }
            .accessibilityIdentifier("xr-home-feedback")
        } label: {
            Image(systemName: "ellipsis.circle").font(.title3)
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel(ar ? "المزيد" : "More")
        .accessibilityIdentifier("xr-home-more")
    }

    // MARK: sections

    /// The optional Xrero account, offered inline until answered, so new users reach their documents at once.
    private var accountCard: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 28))
                        .foregroundStyle(Color.xrTeal)
                        .accessibilityHidden(true)
                    Text(ar ? "تستخدم Xrero على ويندوز؟ سجّل الدخول بنفس الحساب. اختياري."
                            : "Use Xrero on Windows? Sign in to use the same account. Optional.")
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 8) {
                    Button { showAccount = true } label: {
                        Text(ar ? "تسجيل الدخول" : "Sign in")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.xrOnTeal)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("xr-home-signin")
                    Button {
                        withAnimation(reduceMotion ? nil : Animation.default) { accountOffered = true }
                    } label: {
                        Text(ar ? "ليس الآن" : "Not now")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("xr-home-signin-later")
                }
                .controlSize(.large)                                     // 44 pt+ touch targets
            }
            .tint(Color.xrTeal)
            .padding(.vertical, 6)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("xr-home-account-card")
        }
    }

    /// Three create tiles in one row (one column at accessibility text sizes, so the words never get cut).
    private var createSection: some View {
        Section {
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
            layout {
                ForEach(HomeTile.creatable) { t in
                    Button { opener.create(t.kind) } label: { TileView(tile: t, ar: ar) }
                        .buttonStyle(.plain)                 // each tile its own button inside the one list row
                        .accessibilityLabel(ar ? "\(t.title.ar) جديد (\(t.ext))" : "New \(t.title.en.lowercased()) (\(t.ext))")
                        .accessibilityIdentifier("xr-home-" + t.id)
                }
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        } header: {
            Text(ar ? "جديد" : "New")
        }
    }

    private var openSection: some View {
        Section {
            OpenRow(symbol: "folder.fill", color: .xrTeal,
                    title: ar ? "تصفّح الملفات" : "Browse files",
                    detail: ar ? "على هذا الجهاز وiCloud Drive والتطبيقات الأخرى" : "On this device, iCloud Drive and other apps") {
                opener.browse()
            }
            .accessibilityIdentifier("xr-home-browse")
            OpenRow(symbol: "doc.richtext.fill", color: .xrPDF,
                    title: ar ? "فتح ملف PDF" : "Open a PDF",
                    detail: ar ? "عرض وتعبئة وتعليق" : "View, fill and annotate") {
                opener.browse([.pdf])
            }
            .accessibilityIdentifier("xr-home-pdf")
        } header: {
            Text(ar ? "فتح" : "Open")
        }
    }

    @ViewBuilder private var recentSection: some View {
        if recents.items.isEmpty {
            Section {
                emptyState
            } header: {
                Text(ar ? "الأخيرة" : "Recent")
            }
        } else {
            Section {
                ForEach(recents.items) { recentRow($0) }
            } header: {
                Text(ar ? "الأخيرة" : "Recent")
            }
        }
    }

    @ViewBuilder private var searchResults: some View {
        let found = shownRecents
        if found.isEmpty {
            Section {
                Text(ar ? "لا توجد ملفات أخيرة بهذا الاسم." : "No recent files match.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .accessibilityIdentifier("xr-home-search-empty")
            }
        } else {
            Section {
                ForEach(found) { recentRow($0) }
            } header: {
                Text(ar ? "الأخيرة" : "Recent")
            }
        }
    }

    /// First launch / nothing opened yet: what the app is, where files live, and the way to them.
    private var emptyState: some View {
        VStack(spacing: 12) {
            HStack(spacing: -10) {
                ForEach(HomeTile.creatable) { t in
                    Image(systemName: t.symbol)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(t.color)
                        .frame(width: 44, height: 44)
                        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(.separator), lineWidth: 0.5))
                }
            }
            .environment(\.layoutDirection, .leftToRight)          // the stack of glyphs is a picture, not text
            .accessibilityHidden(true)
            Text(ar ? "ملفاتك تبقى على جهازك" : "Your files stay on this device")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(ar ? "مستندات وجداول وعروض تقديمية وملفات PDF، بالعربية والإنجليزية، بدون إنترنت. الملفات التي تفتحها ستظهر هنا."
                    : "Documents, spreadsheets, presentations and PDF, in Arabic and English, offline. Files you open will appear here.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button { opener.browse() } label: {
                Label(ar ? "فتح من الملفات" : "Open from Files", systemImage: "folder")
                    .font(.body.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .tint(Color.xrTeal)
            .controlSize(.large)
            .accessibilityIdentifier("xr-home-empty-open")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("xr-home-empty")
    }

    // MARK: recent rows

    private func recentRow(_ item: RecentFiles.Item) -> some View {
        Button { openRecent(item) } label: { RecentRow(item: item, ar: ar, locale: language.locale) }
            .buttonStyle(.plain)
            .accessibilityIdentifier("xr-recent-" + item.name)
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) { remove(item) } label: {
                    Label(ar ? "إزالة" : "Remove", systemImage: "minus.circle")
                }
                .accessibilityIdentifier("xr-recent-swipe-remove")
                Button { shareRecent(item) } label: {
                    Label(ar ? "مشاركة" : "Share", systemImage: "square.and.arrow.up")
                }
                .tint(Color.xrTeal)
                .accessibilityIdentifier("xr-recent-swipe-share")
            }
            .contextMenu {
                Button { openRecent(item) } label: { Label(ar ? "فتح" : "Open", systemImage: "doc") }
                    .accessibilityIdentifier("xr-recent-open")
                Button { shareRecent(item) } label: { Label(ar ? "مشاركة" : "Share", systemImage: "square.and.arrow.up") }
                    .accessibilityIdentifier("xr-recent-share")
                Button { showInFiles(item) } label: { Label(ar ? "إظهار في الملفات" : "Show in Files", systemImage: "folder") }
                    .accessibilityIdentifier("xr-recent-show")
                Divider()
                // removes the row only: the file itself is never deleted from here
                Button(role: .destructive) { remove(item) } label: {
                    Label(ar ? "إزالة من الأخيرة" : "Remove from Recent", systemImage: "minus.circle")
                }
                .accessibilityIdentifier("xr-recent-remove")
            } preview: {
                RecentThumbnail(item: item, width: 240, height: 320)
            }
    }

    private func remove(_ item: RecentFiles.Item) {
        withAnimation(reduceMotion ? nil : Animation.default) { recents.remove(item) }
    }

    private func openRecent(_ item: RecentFiles.Item) {
        guard let url = recents.resolve(item), FileManager.default.fileExists(atPath: url.path) || url.startAccessingSecurityScopedResource()
        else {
            missing = item.name
            recents.remove(item)
            return
        }
        url.stopAccessingSecurityScopedResource()
        opener.open(url)
    }

    /// The file itself (not a copy) to the share sheet; its security-scoped access is held until the sheet closes.
    private func shareRecent(_ item: RecentFiles.Item) {
        guard let url = recents.resolve(item) else { missing = item.name; recents.remove(item); return }
        sharedScoped?.stopAccessingSecurityScopedResource()
        sharedScoped = url.startAccessingSecurityScopedResource() ? url : nil
        guard FileManager.default.fileExists(atPath: url.path) else {
            sharedScoped?.stopAccessingSecurityScopedResource()
            sharedScoped = nil
            missing = item.name
            recents.remove(item)
            return
        }
        share = ShareFile(url: url)
    }

    /// The Files app at the file's folder (shareddocuments:// is the Files app's own scheme for a local path).
    private func showInFiles(_ item: RecentFiles.Item) {
        guard let url = recents.resolve(item) else { missing = item.name; recents.remove(item); return }
        let folder = url.deletingLastPathComponent().path
        guard let path = folder.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let target = URL(string: "shareddocuments://" + path) else { return }
        openURL(target)
    }
}

/// One kind of file: its colour, symbol and words (Xrero's own colours, Assets.xcassets Kind*, and generic symbols:
/// the kinds are told apart at a glance without Microsoft's Office colours, icons or product names; the captions name
/// the file format only).
struct HomeTile: Identifiable {
    let id: String
    let kind: OfficeKind
    let color: Color
    let symbol: String
    let title: (en: String, ar: String)
    let ext: String

    static let all: [HomeTile] = [
        HomeTile(id: "word", kind: .word, color: .xrDocument, symbol: "doc.text.fill",
                 title: ("Document", "مستند"), ext: ".docx"),
        HomeTile(id: "cell", kind: .cell, color: .xrSpreadsheet, symbol: "tablecells.fill",
                 title: ("Spreadsheet", "جدول"), ext: ".xlsx"),
        HomeTile(id: "slide", kind: .slide, color: .xrPresentation, symbol: "rectangle.on.rectangle",
                 title: ("Presentation", "عرض تقديمي"), ext: ".pptx"),
        HomeTile(id: "pdf", kind: .pdf, color: .xrPDF, symbol: "doc.richtext.fill",
                 title: ("PDF", "PDF"), ext: ".pdf"),
    ]

    /// what the create row offers (a new PDF is made by exporting a document, not from a blank template)
    static var creatable: [HomeTile] { all.filter { OfficeKind.creatable.contains($0.kind) } }

    static func of(_ kind: OfficeKind?) -> HomeTile { all.first { $0.kind == kind } ?? all[0] }
}

/// A create tile: the kind glyph in its colour over the name and the format. No colour slab or stripe: colour is an
/// accent on the glyph only (plan principles).
struct TileView: View {
    let tile: HomeTile
    let ar: Bool
    @ScaledMetric(relativeTo: .title) private var glyph: CGFloat = 40

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: tile.symbol)
                .font(.system(size: glyph * 0.8, weight: .regular))
                .foregroundStyle(tile.color)
                .frame(height: glyph)
            Text(ar ? tile.title.ar : tile.title.en)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1).minimumScaleFactor(0.8)
            // the extension is Latin text: kept left-to-right inside an Arabic layout
            Text(verbatim: tile.ext)
                .font(.caption)
                .foregroundStyle(.secondary)
                .environment(\.layoutDirection, .leftToRight)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: 96)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// A row of the Open section: a coloured glyph, a title and a line of detail, and the forward chevron (which iOS
/// mirrors by itself in right-to-left).
struct OpenRow: View {
    let symbol: String
    let color: Color
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(color)
                    .frame(width: 30)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A recent file: the first-page thumbnail, the name, and where it lives with when it was opened.
struct RecentRow: View {
    let item: RecentFiles.Item
    let ar: Bool
    let locale: Locale

    var body: some View {
        HStack(spacing: 12) {
            RecentThumbnail(item: item)
            VStack(alignment: .leading, spacing: 3) {
                Text((item.name as NSString).deletingPathExtension)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 64)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// "On My iPhone · Today 20:03" in the app's language and locale.
    private var subtitle: String {
        let when = RecentRow.formatter(locale).string(from: item.date)
        guard let place = placeName else { return when }
        return place + " · " + when
    }

    private var placeName: String? {
        let pad = UIDevice.current.userInterfaceIdiom == .pad
        switch item.place {
        case "device": return ar ? (pad ? "على iPad" : "على iPhone") : (pad ? "On My iPad" : "On My iPhone")
        case "icloud": return "iCloud Drive"
        case let p where p.hasPrefix("folder:"):
            let name = String(p.dropFirst("folder:".count))
            return name.isEmpty ? nil : name
        default: return nil
        }
    }

    private static var formatters: [String: DateFormatter] = [:]

    /// "Today 20:03" / "Yesterday" style dates (relative day names), one formatter per locale.
    static func formatter(_ locale: Locale) -> DateFormatter {
        if let f = formatters[locale.identifier] { return f }
        let f = DateFormatter()
        f.locale = locale
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        formatters[locale.identifier] = f
        return f
    }
}
