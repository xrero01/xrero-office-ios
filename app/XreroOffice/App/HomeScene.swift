import SwiftUI
import UniformTypeIdentifiers

/// The start screen: what the app does at a glance (documents, spreadsheets, presentations, PDF), a tile per kind,
/// the system file browser one tap away, and the files opened last.
struct HomeScene: View {
    @StateObject private var opener = DocumentOpener()
    @ObservedObject private var recents = RecentFiles.shared
    @ObservedObject private var account = XreroAccount.shared
    /// The optional account has been offered and answered: "Not now" on the Home card, signing in, or (20.1) the
    /// first-launch sheet. The key is the 20.1 one, so an update does not offer the account a second time.
    @AppStorage("xr.welcomeShown") private var accountOffered = false
    @State private var showAccount = false
    @State private var missing: String?
    @Environment(\.horizontalSizeClass) private var hsc
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var ar: Bool { L.ar }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    if !accountOffered && !account.isSignedIn { accountCard }
                    tiles
                    browseButton
                    recentSection
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAccount = true } label: {
                        Image(systemName: account.isSignedIn ? "person.crop.circle.fill" : "person.crop.circle")
                            .font(.title3)
                    }
                    .accessibilityLabel(account.isSignedIn ? (ar ? "الحساب" : "Account") : (ar ? "تسجيل الدخول" : "Sign in"))
                    .accessibilityIdentifier("xr-home-account")
                }
            }
        }
        .background(PresenterAnchor(opener: opener).frame(width: 0, height: 0))
        .environment(\.layoutDirection, ar ? .rightToLeft : .leftToRight)
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

    // MARK: parts

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image("Logo")
                    .resizable().scaledToFit()
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)
                Text("Xrero Office").font(.largeTitle.bold())
            }
            Text(ar ? "مستندات وجداول وعروض تقديمية وملفات PDF - بالعربية والإنجليزية، بدون إنترنت."
                    : "Documents, spreadsheets, presentations and PDF - Arabic and English, offline.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    /// The optional Xrero account, offered inline until answered, so new users reach their documents at once.
    private var accountCard: some View {
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
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("xr-home-account-card")
    }

    private var tiles: some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 12), count: hsc == .regular ? 4 : 2)
        return VStack(alignment: .leading, spacing: 10) {
            Text(ar ? "إنشاء أو فتح" : "Create or open").font(.headline)
            LazyVGrid(columns: cols, spacing: 12) {
                ForEach(HomeTile.all) { t in
                    Button { t.kind == .pdf ? opener.browse([.pdf]) : opener.create(t.kind) } label: { TileView(tile: t) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("xr-home-" + t.id)
                }
            }
        }
    }

    private var browseButton: some View {
        Button { opener.browse() } label: {
            HStack(spacing: 12) {
                Image(systemName: "folder.fill").font(.title2).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ar ? "تصفّح الملفات" : "Browse files").font(.body.weight(.semibold)).foregroundStyle(.primary)
                    Text(ar ? "على هذا الجهاز وiCloud Drive والتطبيقات الأخرى" : "On this device, iCloud Drive and other apps")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: ar ? "chevron.left" : "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(14)
            .frame(minHeight: 60)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("xr-home-browse")
    }

    @ViewBuilder private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ar ? "الملفات الأخيرة" : "Recent").font(.headline)
            if recents.items.isEmpty {
                Text(ar ? "الملفات التي تفتحها ستظهر هنا." : "Files you open will appear here.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                VStack(spacing: 0) {
                    ForEach(recents.items) { item in
                        Button { openRecent(item) } label: { RecentRow(item: item, ar: ar) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("xr-recent-" + item.name)
                            .contextMenu {
                                Button(role: .destructive) { recents.remove(item) } label: {
                                    Label(ar ? "إزالة من القائمة" : "Remove from list", systemImage: "minus.circle")
                                }
                            }
                        if item != recents.items.last { Divider().padding(.leading, 60) }
                    }
                }
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
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
}

/// One kind of file: its colour, symbol and words.
struct HomeTile: Identifiable {
    let id: String
    let kind: OfficeKind
    let color: Color
    let symbol: String
    let title: (en: String, ar: String)
    let detail: (en: String, ar: String)

    // Xrero's own colours (Assets.xcassets Kind*, Color+Xrero.swift) and generic symbols: the kinds are told apart at a
    // glance without Microsoft's Office colours, icons or product names (the subtitles name the file format only)
    static let all: [HomeTile] = [
        HomeTile(id: "word", kind: .word, color: .xrDocument, symbol: "doc.text.fill",
                 title: ("New document", "مستند جديد"), detail: ("Document · .docx", "مستند · ‎.docx")),
        HomeTile(id: "cell", kind: .cell, color: .xrSpreadsheet, symbol: "tablecells.fill",
                 title: ("New spreadsheet", "جدول بيانات جديد"), detail: ("Spreadsheet · .xlsx", "جدول · ‎.xlsx")),
        HomeTile(id: "slide", kind: .slide, color: .xrPresentation, symbol: "rectangle.stack.fill",
                 title: ("New presentation", "عرض تقديمي جديد"), detail: ("Presentation · .pptx", "عرض · ‎.pptx")),
        HomeTile(id: "pdf", kind: .pdf, color: .xrPDF, symbol: "doc.richtext.fill",
                 title: ("Open a PDF", "فتح ملف PDF"), detail: ("View, fill, annotate", "عرض وتعبئة وتعليق")),
    ]

    static func of(_ kind: OfficeKind?) -> HomeTile { all.first { $0.kind == kind } ?? all[0] }
}

struct TileView: View {
    let tile: HomeTile
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: tile.symbol)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(tile.color, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(L.ar ? tile.title.ar : tile.title.en)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2).minimumScaleFactor(0.85)
                Text(L.ar ? tile.detail.ar : tile.detail.en)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .top) {
            UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16, style: .continuous)
                .fill(tile.color).frame(height: 4)
        }
        .contentShape(Rectangle())
    }
}

struct RecentRow: View {
    let item: RecentFiles.Item
    let ar: Bool
    var body: some View {
        let t = HomeTile.of(item.kind)
        HStack(spacing: 12) {
            Image(systemName: t.symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(t.color, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text((item.name as NSString).deletingPathExtension).font(.body).foregroundStyle(.primary).lineLimit(1)
                Text(item.date, format: .relative(presentation: .named))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text((item.name as NSString).pathExtension.uppercased())
                .font(.caption2.weight(.bold)).foregroundStyle(t.color)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 58)
        .contentShape(Rectangle())
    }
}
