import Foundation
import Security

/// The OPTIONAL Xrero account - the same account as Xrero Office for Windows (xrero.com/office). Everything in the app
/// works without it. Email + password only on iPhone/iPad (the server's Google sign-in would need Sign in with Apple
/// next to it, App Review 4.8). The token lives in the Keychain; name/email/plan (for display) in UserDefaults.
///
/// Server API (xrero_office_accounts): POST /office/api/login {email,password} | /office/api/signup {name,email,password}
/// -> {ok, token, name}; /office/api/validate {token} -> {ok, name, email, plan} | 401 expired | 403 disabled;
/// /office/api/delete {token, password} -> {ok, deleted} (in-app account deletion, App Review 5.1.1(v)).
@MainActor
final class XreroAccount: ObservableObject {
    static let shared = XreroAccount()

    struct Info: Codable, Equatable {
        var name: String
        var email: String
        var plan: String
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @Published private(set) var info: Info?

    private let base = URL(string: "https://xrero.com")!
    private let infoKey = "xr.account.info"
    private let service = "com.xrero.office.account"

    private init() {
        if token() != nil, let d = UserDefaults.standard.data(forKey: infoKey), let i = try? JSONDecoder().decode(Info.self, from: d) {
            info = i
        }
    }

    var isSignedIn: Bool { info != nil }

    // MARK: actions

    func signIn(email: String, password: String) async throws {
        let r = try await post("/office/api/login", ["email": email.trimmingCharacters(in: .whitespaces), "password": password])
        try await finishSignIn(r, fallbackEmail: email)
    }

    func signUp(name: String, email: String, password: String) async throws {
        let r = try await post("/office/api/signup", ["name": name.trimmingCharacters(in: .whitespaces),
                                                      "email": email.trimmingCharacters(in: .whitespaces), "password": password])
        try await finishSignIn(r, fallbackEmail: email)
    }

    /// At start: refresh the details; an account disabled or removed on xrero.com signs out here too. Offline = keep.
    func refresh() async {
        guard let t = token() else { return }
        do {
            let r = try await post("/office/api/validate", ["token": t])
            store(Info(name: r["name"] as? String ?? info?.name ?? "", email: r["email"] as? String ?? info?.email ?? "",
                       plan: r["plan"] as? String ?? "free"))
        } catch let e as HTTPFailure where e.status == 401 || e.status == 403 {
            signOut()
        } catch {}
    }

    func signOut() {
        deleteToken()
        UserDefaults.standard.removeObject(forKey: infoKey)
        info = nil
    }

    /// Deletes the account on xrero.com (documents on this device are not touched), then signs out.
    func deleteAccount(password: String) async throws {
        guard let t = token() else { signOut(); return }
        _ = try await post("/office/api/delete", ["token": t, "password": password])
        signOut()
    }

    /// What the editors' header reads (localStorage "xr-acct", shared with the Windows editors' account chip).
    var webValue: String {
        let o: [String: Any] = info.map { ["name": $0.name, "email": $0.email, "locked": false] } ?? ["locked": true]
        let d = (try? JSONSerialization.data(withJSONObject: o)) ?? Data("{\"locked\":true}".utf8)
        return String(data: d, encoding: .utf8) ?? "{\"locked\":true}"
    }

    // MARK: plumbing

    private struct HTTPFailure: Error { let status: Int; let message: String }

    private func finishSignIn(_ r: [String: Any], fallbackEmail: String) async throws {
        guard let t = r["token"] as? String, !t.isEmpty else { throw Failure(message: Self.friendly(status: 0, server: "", disabled: false)) }
        saveToken(t)
        store(Info(name: r["name"] as? String ?? "", email: fallbackEmail.trimmingCharacters(in: .whitespaces).lowercased(), plan: "free"))
        await refresh()
    }

    private func store(_ i: Info) {
        info = i
        if let d = try? JSONEncoder().encode(i) { UserDefaults.standard.set(d, forKey: infoKey) }
    }

    private func post(_ path: String, _ body: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: 25)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { throw Failure(message: L.noConnection) }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if status == 200, json["ok"] as? Bool == true { return json }
        let server = json["error"] as? String ?? ""
        if path == "/office/api/validate" { throw HTTPFailure(status: status, message: server) }
        if path == "/office/api/delete" && status == 401 {         // the confirmation password, not a sign-in
            throw Failure(message: L.ar ? "كلمة المرور غير صحيحة." : "That password isn't right.")
        }
        throw Failure(message: Self.friendly(status: status, server: server, disabled: json["disabled"] as? Bool == true))
    }

    /// The server answers in English developer wording ("Invalid email or password.", "HTTP 502"); the sheet shows
    /// a short sentence in the app's language that says what to do next. Unknown answers get a general sentence, never
    /// a status code. Server words (xrero_office_accounts: controllers/main.py, models/office_user.py) are matched
    /// loosely so a small rewording there still maps.
    static func friendly(status: Int, server: String, disabled: Bool) -> String {
        let ar = L.ar
        let s = server.lowercased()
        if disabled || status == 403 || s.contains("disabled") { return L.accountDisabled }
        if status == 401 || s.contains("invalid email or password") {
            return ar ? "البريد الإلكتروني أو كلمة المرور غير صحيحة، تحقّق منهما وحاول مرة أخرى."
                      : "That email and password don't match. Check them and try again."
        }
        if s.contains("already registered") {
            return ar ? "هذا البريد مسجّل بالفعل، سجّل الدخول بدلًا من ذلك." : "This email already has an account — sign in instead."
        }
        if s.contains("valid email") {
            return ar ? "اكتب بريدًا إلكترونيًا صحيحًا." : "Enter a valid email address."
        }
        if s.contains("password must") {
            return ar ? "كلمة المرور قصيرة جدًا." : "That password is too short."
        }
        if s.contains("name and email") {
            return ar ? "اكتب اسمك وبريدك الإلكتروني." : "Enter your name and email."
        }
        if status == 429 {
            return ar ? "محاولات كثيرة، انتظر قليلًا ثم حاول مرة أخرى." : "Too many attempts — wait a moment and try again."
        }
        return ar ? "تعذّر الوصول إلى حسابك الآن، حاول مرة أخرى بعد قليل." : "Couldn't reach your account right now — try again in a moment."
    }

    // Keychain: one generic-password item, this device only
    private func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "token"]
    }

    private func token() -> String? {
        var q = query()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    private func saveToken(_ t: String) {
        deleteToken()
        var q = query()
        q[kSecValueData as String] = Data(t.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    private func deleteToken() {
        SecItemDelete(query() as CFDictionary)
    }
}
