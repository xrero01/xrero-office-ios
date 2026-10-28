import SwiftUI

/// The optional Xrero account: sign in / create an account, or - when signed in - the account, Sign out and Delete
/// account (App Review 5.1.1(v)). `welcome` = the one-time first-launch card, with "Continue without an account".
struct AccountView: View {
    @ObservedObject private var account = XreroAccount.shared
    var welcome = false
    @Environment(\.dismiss) private var dismiss

    @State private var creating = false
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var askDelete = false
    @State private var deletePassword = ""
    @State private var deleted = false

    private var ar: Bool { L.ar }

    var body: some View {
        NavigationStack {
            Form {
                if let info = account.info {
                    signedIn(info)
                } else {
                    signedOut
                }
            }
            .navigationTitle(ar ? "حساب Xrero" : "Xrero account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if !welcome || account.isSignedIn {
                        Button(ar ? "تم" : "Done") { dismiss() }
                    }
                }
            }
            .alert(ar ? "حذف الحساب؟" : "Delete account?", isPresented: $askDelete) {
                SecureField(ar ? "كلمة المرور" : "Password", text: $deletePassword)
                Button(ar ? "حذف نهائي" : "Delete permanently", role: .destructive) { Task { await deleteAccount() } }
                Button(ar ? "إلغاء" : "Cancel", role: .cancel) { deletePassword = "" }
            } message: {
                Text(ar ? "سيُحذف حسابك (الاسم والبريد الإلكتروني) من xrero.com نهائيًا. مستنداتك على هذا الجهاز لن تتأثر. أدخل كلمة المرور للتأكيد."
                        : "Your account (name and email) will be permanently deleted from xrero.com. Documents on this device are not affected. Enter your password to confirm.")
            }
            .alert(ar ? "تم حذف الحساب" : "Account deleted", isPresented: $deleted) {
                Button(L.ok) { dismiss() }
            }
        }
        .environment(\.layoutDirection, ar ? .rightToLeft : .leftToRight)
    }

    @ViewBuilder private var signedOut: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(welcome ? (ar ? "أهلًا بك في Xrero Office" : "Welcome to Xrero Office") : (ar ? "حساب Xrero" : "Xrero account"))
                    .font(.title3.bold())
                Text(ar ? "سجّل الدخول بحساب Xrero نفسه المستخدم في Xrero Office على ويندوز. هذا اختياري - كل الميزات تعمل بدون حساب، ومستنداتك تبقى على جهازك."
                        : "Sign in with the same Xrero account you use in Xrero Office for Windows. It is optional - everything works without an account, and your documents stay on your device.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
        Section {
            Picker("", selection: $creating) {
                Text(ar ? "تسجيل الدخول" : "Sign in").tag(false)
                Text(ar ? "إنشاء حساب" : "Create account").tag(true)
            }
            .pickerStyle(.segmented)
            if creating {
                TextField(ar ? "الاسم الكامل" : "Full name", text: $name)
                    .textContentType(.name).accessibilityIdentifier("xr-acct-name")
            }
            TextField(ar ? "البريد الإلكتروني" : "Email", text: $email)
                .textContentType(.emailAddress).keyboardType(.emailAddress)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .environment(\.layoutDirection, .leftToRight)
                .accessibilityIdentifier("xr-acct-email")
            SecureField(creating ? (ar ? "كلمة المرور (8 أحرف على الأقل)" : "Password (at least 8 characters)") : (ar ? "كلمة المرور" : "Password"),
                        text: $password)
                .textContentType(creating ? .newPassword : .password)
                .accessibilityIdentifier("xr-acct-password")
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            Button {
                Task { await submit() }
            } label: {
                HStack {
                    Spacer()
                    if busy { ProgressView() } else { Text(creating ? (ar ? "إنشاء الحساب" : "Create account") : (ar ? "تسجيل الدخول" : "Sign in")).bold() }
                    Spacer()
                }
            }
            .disabled(busy || email.isEmpty || password.isEmpty || (creating && name.isEmpty))
            .accessibilityIdentifier("xr-acct-submit")
        } footer: {
            Link(ar ? "سياسة الخصوصية" : "Privacy Policy", destination: URL(string: "https://xrero.com/privacy")!)
        }
        if welcome {
            Section {
                Button(ar ? "المتابعة بدون حساب" : "Continue without an account") { dismiss() }
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("xr-acct-skip")
            }
        }
    }

    @ViewBuilder private func signedIn(_ info: XreroAccount.Info) -> some View {
        Section {
            HStack(spacing: 14) {
                Text(initials(info))
                    .font(.headline).foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(Color(red: 0.12, green: 0.48, blue: 0.55)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.name.isEmpty ? (ar ? "حساب Xrero" : "Xrero account") : info.name).font(.headline)
                    Text(info.email).font(.subheadline).foregroundStyle(.secondary)
                        .environment(\.layoutDirection, .leftToRight)
                }
            }
            .padding(.vertical, 4)
            LabeledContent(ar ? "الخطة" : "Plan", value: info.plan == "pro" ? "Pro" : (ar ? "مجانية" : "Free"))
        } footer: {
            Text(ar ? "مستنداتك تبقى على هذا الجهاز. الحساب هو اسمك وبريدك الإلكتروني فقط على xrero.com."
                    : "Your documents stay on this device. The account is only your name and email on xrero.com.")
        }
        Section {
            Button(ar ? "تسجيل الخروج" : "Sign out") { account.signOut() }
                .accessibilityIdentifier("xr-acct-signout")
        }
        Section {
            Button(ar ? "حذف الحساب" : "Delete account", role: .destructive) { askDelete = true }
                .accessibilityIdentifier("xr-acct-delete")
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
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
            if welcome { dismiss() }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func deleteAccount() async {
        busy = true; error = nil
        defer { busy = false; deletePassword = "" }
        do {
            try await account.deleteAccount(password: deletePassword)
            deleted = true
        } catch {
            self.error = error.localizedDescription
        }
    }
}
