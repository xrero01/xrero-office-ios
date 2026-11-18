import Foundation
import Security

/// The Xrero account - the same free account as Xrero Office for Windows and Mac (xrero.com/office). REQUIRED (owner
/// 18 Nov 2026, as on Windows and Mac 20.2): while no account is stored the app shows the account wall (AccountView,
/// mode .wall - Home's whole screen and a cover over an open editor) and opens no document (DocumentOpener holds the
/// request until the user has signed in). Users who skipped the optional account of 20.1-21.0 meet the wall after the
/// update; a signed-in user keeps the stored session and never sees it. Email + password only on iPhone/iPad (the
/// server's Google sign-in would need Sign in with Apple next to it, App Review 4.8). The token lives in the Keychain;
/// name/email/plan (for display) in UserDefaults. Offline, a stored account keeps working (refresh() keeps it).
///
/// Server API (xrero_office_accounts): POST /office/api/login {email,password} | /office/api/signup {name,email,password}
/// -> {ok, token, name}; /office/api/validate {token} -> {ok, name, email, plan} | 401 expired | 403 disabled;
/// /office/api/delete {token, password} -> {ok, deleted} | 401 invalid or expired token | 403 wrong password
/// (server/office_delete_endpoint.py; in-app account deletion, App Review 5.1.1(v)).
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

    /// Why the account went away, said once on the wall that follows (cleared by the next sign-in).
    enum Notice: Equatable { case deleted, expired, expiredDuringDelete, disabled }

    @Published private(set) var info: Info?
    @Published private(set) var notice: Notice?

    private let base = URL(string: "https://xrero.com")!
    private let infoKey = "xr.account.info"
    private let service = "com.xrero.office.account"

    #if XR_AUTOTEST || DEBUG
    /// Test builds only (configurations Autotest and Debug - never Release): a LOCAL session, like the Mac UI test's
    /// XR_NO_SIGNUP path. Launch with XR_TEST_SESSION=1 (or, Autotest build, post the Darwin notification
    /// `testSessionNote` while the wall is up). It lives in memory only - nothing in the Keychain (the CI simulator
    /// build is unsigned) or in UserDefaults - and it never reaches xrero.com: no validate, no delete.
    /// XR_NO_SESSION=1 removes any stored account at launch (the wall as on a first launch).
    static let testToken = "local-ui-test"
    static let testSessionNote = "com.xrero.office.autotest.session"
    private var testSession = false
    #endif

    private init() {
        #if XR_AUTOTEST || DEBUG
        let env = ProcessInfo.processInfo.environment
        if env["XR_NO_SESSION"] == "1" {
            deleteToken()
            UserDefaults.standard.removeObject(forKey: infoKey)
            NSLog("XR account stored session cleared (XR_NO_SESSION)")
        }
        #if XR_AUTOTEST
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            Task { @MainActor in XreroAccount.shared.startTestSession() }
        }, Self.testSessionNote as CFString, nil, .deliverImmediately)
        #endif
        if env["XR_TEST_SESSION"] == "1" {
            startTestSession()
            return
        }
        #endif
        if token() != nil, let d = UserDefaults.standard.data(forKey: infoKey), let i = try? JSONDecoder().decode(Info.self, from: d) {
            info = i
        }
        NSLog("XR account %@", info == nil ? "signed-out (wall)" : "signed-in")
    }

    var isSignedIn: Bool { info != nil }

    /// For main-thread code outside SwiftUI's views (DocumentOpener, the menu bar's actions).
    nonisolated static var signedInNow: Bool { MainActor.assumeIsolated { shared.isSignedIn } }

    #if XR_AUTOTEST || DEBUG
    func startTestSession() {
        testSession = true
        notice = nil
        info = Info(name: "iOS Store Check", email: "ios-check@example.invalid", plan: "free")
        NSLog("XR account test-session (local, nothing sent to xrero.com)")
    }
    #endif

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

    /// At start: refresh the details; an account disabled or removed on xrero.com signs out here too (the wall comes
    /// back, over an open editor as well). Offline = keep: a stored account works without a connection.
    func refresh() async {
        guard let t = token() else { return }
        #if XR_AUTOTEST || DEBUG
        if testSession { return }                         // the local test session never reaches xrero.com
        #endif
        do {
            let r = try await post("/office/api/validate", ["token": t])
            store(Info(name: r["name"] as? String ?? info?.name ?? "", email: r["email"] as? String ?? info?.email ?? "",
                       plan: r["plan"] as? String ?? "free"))
        } catch let e as HTTPFailure where e.status == 401 || e.status == 403 {
            NSLog("XR account refresh: %ld, signing out", e.status)
            signOut(notice: e.status == 403 ? .disabled : .expired)
        } catch {}
    }

    /// Sign out (the user's own, or `notice`: why the account went away). Every Home and every open editor shows the
    /// wall at once; an open editor saves first (EditorScreen).
    func signOut(notice: Notice? = nil) {
        #if XR_AUTOTEST || DEBUG
        testSession = false
        #endif
        deleteToken()
        UserDefaults.standard.removeObject(forKey: infoKey)
        self.notice = notice
        info = nil
        NSLog("XR account signed-out%@", notice.map { " (\($0))" } ?? "")
    }

    /// Deletes the account on xrero.com (documents on this device are not touched), then signs out - back to the wall,
    /// which says the account was deleted. A sign-in the server no longer accepts (401) deleted nothing: signed out too,
    /// and the wall asks to sign in again first, as the Mac app does. A wrong password throws and keeps the account.
    func deleteAccount(password: String) async throws {
        guard let t = token() else { signOut(); return }
        #if XR_AUTOTEST || DEBUG
        if testSession {                                  // the local test session: nothing to delete on xrero.com
            NSLog("XR account delete: test session, local sign-out only (nothing sent)")
            signOut(notice: .deleted)
            return
        }
        #endif
        do {
            _ = try await post("/office/api/delete", ["token": t, "password": password])
        } catch let e as HTTPFailure where e.status == 401 {
            NSLog("XR account delete: sign-in expired, signing out")
            signOut(notice: .expiredDuringDelete)
            return
        }
        signOut(notice: .deleted)
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
        #if XR_AUTOTEST || DEBUG
        testSession = false
        #endif
        saveToken(t)
        notice = nil
        store(Info(name: r["name"] as? String ?? "", email: fallbackEmail.trimmingCharacters(in: .whitespaces).lowercased(), plan: "free"))
        NSLog("XR account signed-in")
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
        NSLog("XR account answer %@: status=%ld", path, status)
        if path == "/office/api/validate" { throw HTTPFailure(status: status, message: server) }
        if path == "/office/api/delete" {
            // the delete endpoint's own codes: 401 = the sign-in token is invalid or expired (deleteAccount signs out),
            // 403 = the confirmation password is wrong
            if status == 401 { throw HTTPFailure(status: status, message: server) }
            if status == 403 { throw Failure(message: L.ar ? "كلمة المرور غير صحيحة." : "That password isn't right.") }
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
        #if XR_AUTOTEST || DEBUG
        if testSession { return Self.testToken }
        #endif
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
