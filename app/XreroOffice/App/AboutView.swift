import SwiftUI

/// About & Licences: who makes the app and which version this is, the AGPL-3.0 source offer (a link to the source of
/// this very build), the ONLYOFFICE attribution with the ONLYOFFICE logo (its licence's Section 7(b) asks for the logo
/// to be kept), every third-party notice and licence text, the Microsoft trademark notice and the privacy promise.
/// Reached from Home (⋯) and from the account sheet, which the editor's top bar opens too.
struct AboutView: View {
    private var ar: Bool { L.ar }

    var body: some View {
        List {
            header
            openSource
            engine
            licences
            trademarks
            privacy
            Section {
                Link("© 2026 Xrero · xrero.com", destination: URL(string: "https://xrero.com")!)
                    .font(.footnote)
                    .frame(maxWidth: .infinity)
                    .environment(\.layoutDirection, .leftToRight)
            }
            .listRowBackground(Color.clear)
        }
        .listStyle(.insetGrouped)
        .navigationTitle(ar ? "حول التطبيق" : "About")
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.layoutDirection, ar ? .rightToLeft : .leftToRight)
    }

    // MARK: sections

    private var header: some View {
        Section {
            VStack(spacing: 8) {
                Image("Logo")
                    .resizable().scaledToFit()
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .accessibilityHidden(true)
                Text("Xrero Office").font(.title2.bold())
                Text(ar ? "الإصدار \(AppBuild.version) (\(AppBuild.build))" : "Version \(AppBuild.version) (\(AppBuild.build))")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .accessibilityIdentifier("xr-about-version")
                Text(ar ? "حزمة مكتبية مجانية ومفتوحة المصدر للمستندات والجداول والعروض التقديمية وملفات PDF. العربية أولًا، وتعمل بالكامل دون إنترنت."
                        : "Free, open-source office suite for documents, spreadsheets, presentations and PDF. Arabic-first, works fully offline.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .listRowBackground(Color.clear)
    }

    private var openSource: some View {
        Section(ar ? "مجاني ومفتوح المصدر" : "Free and open source") {
            Text(ar ? "Xrero Office برنامج حر مرخّص وفق رخصة جنو أفيرو العمومية العامة، الإصدار 3 (AGPL-3.0). يحق لك استخدامه ودراسته ومشاركته وتعديله وفق هذه الرخصة، ويُقدَّم دون أي ضمان."
                    : "Xrero Office is free software under the GNU Affero General Public License v3 (AGPL-3.0). You may use, study, share and change it under that licence. It comes with no warranty.")
                .font(.subheadline)
                .accessibilityIdentifier("xr-about-agpl")
            Link(destination: AppBuild.sourceURL) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ar ? "الشيفرة المصدرية لهذا الإصدار" : "Source code of this version")
                    // the address reads left to right in both languages
                    Text(AppBuild.sourceCaption)
                        .font(.caption).foregroundStyle(.secondary)
                        .environment(\.layoutDirection, .leftToRight)
                }
            }
            .accessibilityIdentifier("xr-about-source")
        }
    }

    private var engine: some View {
        Section(ar ? "محرك التحرير" : "Editing engine") {
            VStack(alignment: .leading, spacing: 10) {
                // ONLYOFFICE's own logo (dark-mode variant in the asset), kept as its AGPL Section 7(b) terms require
                Image("OnlyofficeLogo")
                    .resizable().scaledToFit()
                    .frame(height: 22)
                    .accessibilityLabel("ONLYOFFICE")
                    .accessibilityIdentifier("xr-about-onlyoffice-logo")
                Text(ar ? "محررات المستندات والجداول والعروض التقديمية وملفات PDF مبنية على ONLYOFFICE Docs من شركة Ascensio System SIA وفق رخصة AGPL-3.0، وعدّلتها Xrero لدعم النص العربي وأجهزة iPhone وiPad. ONLYOFFICE علامة تجارية لشركة Ascensio System SIA، وXrero Office غير تابع لها ولا معتمد منها."
                        : "The document, spreadsheet, presentation and PDF editors are based on ONLYOFFICE Docs by Ascensio System SIA under the AGPL-3.0, modified by Xrero for Arabic text, iPhone and iPad. ONLYOFFICE is a trademark of Ascensio System SIA; Xrero Office is not affiliated with or endorsed by Ascensio System SIA.")
                    .font(.subheadline)
                    .accessibilityIdentifier("xr-about-onlyoffice")
            }
            .padding(.vertical, 4)
            Link(destination: URL(string: "https://github.com/ONLYOFFICE")!) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ar ? "الشيفرة المصدرية لـ ONLYOFFICE" : "ONLYOFFICE source code")
                    Text("github.com/ONLYOFFICE")
                        .font(.caption).foregroundStyle(.secondary)
                        .environment(\.layoutDirection, .leftToRight)
                }
            }
            .accessibilityIdentifier("xr-about-onlyoffice-source")
        }
    }

    /// The notices and licence texts of Settings.bundle, so this screen and iOS Settings > Xrero Office > Licences
    /// always say the same thing (both come from scripts/make_settings_bundle.py).
    private var licences: some View {
        Section {
            NavigationLink {
                NoticesView()
            } label: {
                Label(ar ? "إشعارات المكوّنات والخطوط" : "Third-party notices and fonts", systemImage: "doc.text")
            }
            .accessibilityIdentifier("xr-about-notices")
            ForEach(LicenceCatalog.licences) { lic in
                NavigationLink {
                    LicenceTextView(licence: lic)
                } label: {
                    Text(lic.title)
                }
                .accessibilityIdentifier("xr-about-licence-" + lic.file)
            }
        } header: {
            Text(ar ? "التراخيص" : "Licences")
        } footer: {
            if ar { Text("نصوص حقوق النشر والتراخيص معروضة بلغتها الأصلية (الإنجليزية).") }
        }
    }

    private var trademarks: some View {
        Section(ar ? "العلامات التجارية" : "Trademarks") {
            Text(ar ? "Microsoft وWord وExcel وPowerPoint علامات تجارية لمجموعة شركات Microsoft. Xrero Office تطبيق مستقل غير تابع لشركة Microsoft ولا برعايتها ولا معتمد منها، ويفتح ملفات Office Open XML ويحفظها (‎.docx و‎.xlsx و‎.pptx)."
                    : "Microsoft, Word, Excel and PowerPoint are trademarks of the Microsoft group of companies. Xrero Office is an independent app and is not affiliated with, sponsored or endorsed by Microsoft. It opens and saves the Office Open XML file formats (.docx, .xlsx, .pptx).")
                .font(.subheadline)
                .accessibilityIdentifier("xr-about-trademarks")
        }
    }

    private var privacy: some View {
        Section(ar ? "الخصوصية" : "Privacy") {
            Text(ar ? "تُفتح مستنداتك وتُحرَّر وتُحفظ على هذا الجهاز ولا تُرفع إلى أي خادم. حساب Xrero الاختياري يحفظ اسمك وبريدك الإلكتروني فقط."
                    : "Your documents are opened, edited and saved on this device; they are never uploaded. The optional Xrero account holds only your name and email.")
                .font(.subheadline)
            Link(ar ? "سياسة الخصوصية" : "Privacy Policy", destination: URL(string: "https://xrero.com/privacy")!)
                .accessibilityIdentifier("xr-about-privacy")
        }
    }
}

/// AboutView with its own navigation and a Done button, for places that present it as a sheet (Home, the CI tests).
struct AboutSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AboutView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L.ar ? "تم" : "Done") { dismiss() }
                            .accessibilityIdentifier("xr-about-done")
                    }
                }
        }
        .environment(\.layoutDirection, L.ar ? .rightToLeft : .leftToRight)
    }
}

/// Every copyright notice of Settings.bundle's Licences page: the app, the editors, the converter and each font.
/// The notices are English legal text: shown left to right in both interface languages.
struct NoticesView: View {
    var body: some View {
        List(LicenceCatalog.notices) { n in
            VStack(alignment: .leading, spacing: 4) {
                Text(n.title).font(.subheadline.weight(.semibold))
                Text(n.text).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
            .environment(\.layoutDirection, .leftToRight)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("xr-notice")
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L.ar ? "إشعارات المكوّنات والخطوط" : "Third-party notices")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One full licence text. The texts are hard-wrapped at 72 columns for terminals: re-flowed into paragraphs so they
/// read on a phone, in a lazy stack (the AGPL is 38 KB).
struct LicenceTextView: View {
    let licence: LicenceCatalog.Licence

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(Array(LicenceCatalog.paragraphs(LicenceCatalog.text(licence.file)).enumerated()), id: \.offset) { _, p in
                    Text(p).font(.footnote).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
            .environment(\.layoutDirection, .leftToRight)
        }
        .navigationTitle(licence.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Version, build and the commit this build was made from.
enum AppBuild {
    static let repo = "https://github.com/xrero01/xrero-office-ios"
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "" }
    /// Info.plist XRSourceCommit = $(GITHUB_SHA): set on GitHub's builders (the App Store build included), empty in a
    /// local build - then the source link points at the repository itself.
    static var commit: String? {
        guard let c = Bundle.main.object(forInfoDictionaryKey: "XRSourceCommit") as? String,
              c.count == 40, c.allSatisfy(\.isHexDigit) else { return nil }
        return c.lowercased()
    }
    static var sourceURL: URL { URL(string: commit.map { repo + "/tree/" + $0 } ?? repo)! }
    static var sourceCaption: String {
        let short: String = commit.map { " · " + String($0.prefix(7)) } ?? ""
        return "github.com/xrero01/xrero-office-ios" + short
    }
}

/// Settings.bundle's Licences page (generated by scripts/make_settings_bundle.py), read from the app bundle.
enum LicenceCatalog {
    struct Notice: Identifiable { let title: String; let text: String; var id: String { title } }
    struct Licence: Identifiable { let title: String; let file: String; var id: String { file } }

    private static func specifiers(_ file: String) -> [[String: Any]] {
        guard let url = Bundle.main.url(forResource: file, withExtension: "plist", subdirectory: "Settings.bundle"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let specs = plist["PreferenceSpecifiers"] as? [[String: Any]] else { return [] }
        return specs
    }

    static let notices: [Notice] = specifiers("Licences").compactMap { s in
        guard s["Type"] as? String == "PSGroupSpecifier", let t = s["Title"] as? String,
              let f = s["FooterText"] as? String, !f.isEmpty else { return nil }
        return Notice(title: t, text: f)
    }

    static let licences: [Licence] = specifiers("Licences").compactMap { s in
        guard s["Type"] as? String == "PSChildPaneSpecifier", let t = s["Title"] as? String,
              let f = s["File"] as? String else { return nil }
        return Licence(title: t, file: f)
    }

    static func text(_ file: String) -> String {
        specifiers(file).compactMap { $0["FooterText"] as? String }.joined(separator: "\n\n")
    }

    /// Blank lines separate paragraphs; the lines inside one are joined; "-----" / "=====" rules are dropped.
    static func paragraphs(_ text: String) -> [String] {
        var out: [String] = []
        var cur: [String] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if !cur.isEmpty { out.append(cur.joined(separator: " ")); cur = [] }
            } else if !line.allSatisfy({ $0 == "-" || $0 == "=" }) {
                cur.append(line)
            }
        }
        if !cur.isEmpty { out.append(cur.joined(separator: " ")) }
        return out
    }
}
