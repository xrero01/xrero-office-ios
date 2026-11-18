import SwiftUI

/// The Xrero account, REQUIRED (owner 18 Nov 2026, as on Windows and Mac 20.2).
///
/// `.wall`: what the app shows while no account is stored - Home's whole screen (HomeScene) and a cover over an open
/// editor (EditorHost). Sign in / Create account, the privacy policy, About & Licences and the interface language
/// (EN / العربية), and no way past it: no Done, no "continue without an account", and nothing to swipe away or close
/// with Escape - it is screen content, not a presented sheet.
/// `.sheet`: ⋯ > Account while signed in - the account, Sign out and Delete account (App Review 5.1.1(v)). Once the
/// account is gone (Sign out, Delete) the sheet closes itself and the wall under it takes over.
struct AccountView: View {
    enum Mode { case sheet, wall }
    var mode: Mode = .sheet

    @ObservedObject private var account = XreroAccount.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    @State private var creating = false
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var askDelete = false
    @State private var deletePassword = ""
    @FocusState private var focus: Field?
    @ObservedObject private var language = AppLanguage.shared

    /// The keyboard's Next / Go chain: name -> email -> password -> Continue.
    private enum Field { case name, email, password }

    private var ar: Bool { language.isArabic }
    private var wall: Bool { mode == .wall }

    private var canSubmit: Bool { !busy && !email.isEmpty && !password.isEmpty && !(creating && name.isEmpty) }

    private static let privacyURL = URL(string: "https://xrero.com/privacy")!

    var body: some View {
        NavigationStack {
            Form {
                if wall { wallHeader }
                if let info = account.info {
                    signedIn(info)
                } else {
                    signedOut
                }
                links
            }
            .accessibilityIdentifier(wall ? "xr-acct-wall" : "xr-acct-sheet")
            // the wall: a readable column on a wide iPad, not form fields across 1000 pt
            .frame(maxWidth: wall ? 640 : CGFloat.infinity)
            .frame(maxWidth: .infinity)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle(ar ? "حساب Xrero" : "Xrero account")
            .navigationBarTitleDisplayMode(.inline)
            // the wall has its own heading (and nothing to close): no bar over it; About & Licences pushes with its own
            .toolbar(wall ? .hidden : .automatic, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if !wall {
                        Button(ar ? "تم" : "Done") { dismiss() }
                            .accessibilityIdentifier("xr-acct-done")
                    }
                }
            }
            .alert(ar ? "حذف الحساب؟" : "Delete account?", isPresented: $askDelete) {
                SecureField(ar ? "كلمة المرور" : "Password", text: $deletePassword)
                    .accessibilityIdentifier("xr-acct-delete-password")
                Button(ar ? "حذف نهائي" : "Delete permanently", role: .destructive) { Task { await deleteAccount() } }
                    .accessibilityIdentifier("xr-acct-delete-confirm")
                Button(ar ? "إلغاء" : "Cancel", role: .cancel) { deletePassword = "" }
                    .accessibilityIdentifier("xr-acct-delete-cancel")
            } message: {
                Text(ar ? "سيُحذف حسابك (الاسم والبريد الإلكتروني) من xrero.com نهائيًا. مستنداتك على هذا الجهاز لن تتأثر. أدخل كلمة المرور للتأكيد."
                        : "Your account (name and email) will be permanently deleted from xrero.com. Documents on this device are not affected. Enter your password to confirm.")
            }
        }
        .environment(\.layoutDirection, ar ? .rightToLeft : .leftToRight)
        .interactiveDismissDisabled(wall)
        .onChange(of: account.isSignedIn) { _, signedIn in
            if signedIn {
                password = ""; error = nil
            } else if !wall {
                dismiss()                       // signed out / deleted: the wall under this sheet takes over
            }
        }
    }

    // MARK: the wall's heading

    @ViewBuilder private var wallHeader: some View {
        Section {
            VStack(spacing: 10) {
                HStack {
                    Spacer(minLength: 0)
                    languageButton
                }
                Image("Logo")
                    .resizable().scaledToFit()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityHidden(true)
                Text(ar ? "مرحبًا بك في Xrero Office" : "Welcome to Xrero Office")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("xr-acct-welcome")
                Text(intro)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("xr-acct-intro")
                if let notice = account.notice {
                    Label(noticeText(notice), systemImage: notice == .deleted ? "checkmark.circle" : "exclamationmark.circle")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(notice == .deleted ? Color.primary : Color.red)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("xr-acct-notice")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .listRowBackground(Color.clear)
    }

    private var intro: String {
        ar ? "أنشئ حساب Xrero المجاني، أو سجّل الدخول بالحساب نفسه الذي تستخدمه في Xrero Office على Windows وMac. مستنداتك تبقى على هذا الجهاز."
           : "Create your free Xrero account, or sign in with the one you use in Xrero Office for Windows and Mac. Your documents stay on this device."
    }

    private func noticeText(_ n: XreroAccount.Notice) -> String {
        switch n {
        case .deleted:
            return ar ? "تم حذف حسابك. مستنداتك على هذا الجهاز لم تتأثر." : "Your account was deleted. Documents on this device are not affected."
        case .expired:
            return ar ? "انتهت صلاحية تسجيل الدخول. سجّل الدخول مرة أخرى للمتابعة." : "Your sign-in has expired. Sign in again to continue."
        case .expiredDuringDelete:
            return ar ? "انتهت صلاحية تسجيل الدخول ولم يُحذف الحساب. سجّل الدخول مرة أخرى ثم احذف الحساب."
                      : "Your sign-in has expired, so the account was not deleted. Sign in again, then delete the account."
        case .disabled:
            return ar ? "هذا الحساب موقوف. سجّل الدخول بحساب آخر أو أنشئ حسابًا جديدًا."
                      : "This account is disabled. Sign in with another account or create a new one."
        }
    }

    /// The interface language, switched right on the wall (the same setting as Home's ⋯ > Language). The button shows
    /// the other language's name in that language, as iOS does; VoiceOver says what it does in the current one.
    private var languageButton: some View {
        Button { AppLanguage.set(ar ? "en" : "ar") } label: {
            Label(ar ? "English" : "العربية", systemImage: "globe")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 6)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)                // its own target: a tap elsewhere in the heading row does nothing
        .tint(Color.xrTeal)
        .accessibilityLabel(ar ? "التبديل إلى الإنجليزية" : "Switch to Arabic")
        .accessibilityInputLabels(languageInputLabels)
        .accessibilityIdentifier("xr-acct-lang")
    }

    /// Voice Control: the name shown on the button, in both languages.
    private var languageInputLabels: [String] { ar ? ["English", "الإنجليزية"] : ["العربية", "Arabic"] }

    // MARK: signed out: Sign in / Create account

    @ViewBuilder private var signedOut: some View {
        if !wall {
            Section {
                Text(intro)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 4)
            }
        }
        Section {
            modeTabs
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            if creating {
                TextField(ar ? "الاسم الكامل" : "Full name", text: $name)
                    .textContentType(.name)
                    .submitLabel(.next)
                    .focused($focus, equals: .name)
                    .onSubmit { focus = .email }
                    .accessibilityIdentifier("xr-acct-name")
            }
            TextField(ar ? "البريد الإلكتروني" : "Email", text: $email)
                .textContentType(.emailAddress).keyboardType(.emailAddress)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .submitLabel(.next)
                .focused($focus, equals: .email)
                .onSubmit { focus = .password }
                .environment(\.layoutDirection, .leftToRight)
                .accessibilityIdentifier("xr-acct-email")
            SecureField(creating ? (ar ? "كلمة المرور (8 أحرف على الأقل)" : "Password (at least 8 characters)") : (ar ? "كلمة المرور" : "Password"),
                        text: $password)
                .textContentType(creating ? .newPassword : .password)
                .submitLabel(.go)
                .focused($focus, equals: .password)
                .onSubmit { if canSubmit { Task { await submit() } } }
                .accessibilityIdentifier("xr-acct-password")
            if let error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.footnote).foregroundStyle(.red)
                    .accessibilityIdentifier("xr-acct-error")
            }
        }
        // one big filled teal button (50 pt, full width): the screen's single primary action
        Section {
            Button {
                focus = nil
                Task { await submit() }
            } label: {
                ZStack {
                    if busy { ProgressView().tint(Color.xrOnTeal) }
                    else { Text(ar ? "متابعة" : "Continue").font(.headline).foregroundStyle(Color.xrOnTeal) }
                }
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(Color.xrTeal, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .opacity(canSubmit || busy ? 1 : 0.45)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .accessibilityLabel(creating ? (ar ? "إنشاء الحساب" : "Create account") : (ar ? "تسجيل الدخول" : "Sign in"))
            .accessibilityIdentifier("xr-acct-submit")
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
    }

    /// Sign in | Create account: two tabs (the Mac card's xr-acct-tab-in / xr-acct-tab-new), 44 pt tall, side by side
    /// - one above the other at accessibility text sizes, so neither name is cut. Leading = Sign in (right in Arabic).
    private var modeTabs: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 4))
        return layout {
            tab(create: false, ar ? "تسجيل الدخول" : "Sign in", id: "xr-acct-tab-in")
            tab(create: true, ar ? "إنشاء حساب" : "Create account", id: "xr-acct-tab-new")
        }
        .padding(3)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("xr-acct-mode")
    }

    private func tab(create: Bool, _ title: String, id: String) -> some View {
        let on = creating == create
        return Button {
            guard creating != create else { return }
            creating = create
            error = nil
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(on ? Color.xrOnTeal : Color.primary)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(on ? Color.xrTeal : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)                    // each tab its own button inside the one form row
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier(id)
    }

    // MARK: signed in: the account, Sign out, Delete account

    @ViewBuilder private func signedIn(_ info: XreroAccount.Info) -> some View {
        Section {
            HStack(spacing: 14) {
                Text(initials(info))
                    .font(.headline).foregroundStyle(Color.xrOnTeal)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(Color.xrTeal))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.name.isEmpty ? (ar ? "حساب Xrero" : "Xrero account") : info.name).font(.headline)
                        .accessibilityIdentifier("xr-acct-name-shown")
                    Text(info.email).font(.subheadline).foregroundStyle(.secondary)
                        .environment(\.layoutDirection, .leftToRight)
                }
            }
            .padding(.vertical, 4)
            // no Plan row: there is nothing to buy or change in this app, so a plan would only raise questions
        } footer: {
            Text(ar ? "مستنداتك تبقى على هذا الجهاز. الحساب هو اسمك وبريدك الإلكتروني فقط على xrero.com."
                    : "Your documents stay on this device. The account is only your name and email on xrero.com.")
        }
        Section {
            Button(ar ? "تسجيل الخروج" : "Sign out") { account.signOut() }
                .accessibilityIdentifier("xr-acct-signout")
        }
        Section {
            Button(ar ? "حذف الحساب" : "Delete account", role: .destructive) { error = nil; askDelete = true }
                .accessibilityIdentifier("xr-acct-delete")
            if let error {
                Text(error).font(.footnote).foregroundStyle(.red)
                    .accessibilityIdentifier("xr-acct-delete-error")
            }
        }
    }

    // MARK: Privacy Policy, About & Licences (both modes: reachable from the wall, before any account exists)

    private var links: some View {
        Section {
            Link(destination: Self.privacyURL) {
                Label(ar ? "سياسة الخصوصية" : "Privacy Policy", systemImage: "hand.raised")
            }
            .accessibilityIdentifier("xr-acct-privacy")
            NavigationLink { AboutView() } label: {
                Label(ar ? "حول التطبيق والتراخيص" : "About & Licences", systemImage: "info.circle")
            }
            .accessibilityIdentifier("xr-acct-about")
        }
    }

    private func initials(_ i: XreroAccount.Info) -> String {
        let parts = (i.name.isEmpty ? i.email : i.name).split(separator: " ")
        return parts.prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    private func submit() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            if creating { try await account.signUp(name: name, email: email, password: password) }
            else { try await account.signIn(email: email, password: password) }
            password = ""
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Deleted (or the sign-in expired meanwhile): the account is signed out, this sheet closes itself and the wall
    /// says what happened. A wrong password keeps the account and is said here.
    private func deleteAccount() async {
        busy = true; error = nil
        defer { busy = false; deletePassword = "" }
        do {
            try await account.deleteAccount(password: deletePassword)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
