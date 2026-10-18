"""office_delete_endpoint.py - adds POST /office/api/delete to xrero.com (module xrero_office_accounts), the in-app
account deletion App Review requires (guideline 5.1.1(v)) for the optional Xrero account in the iOS app.

Run ON THE SERVER (as root):  python3 office_delete_endpoint.py   then restart the master Odoo container.
Idempotent; backs up controllers/main.py first (main.py.bak_delete_<timestamp>).

  {token, password}  ->  200 {ok: true, deleted: true}
  - token: the app's account token (proves who is asking); expired/invalid -> 401
  - password: required for email accounts (a leaked token alone cannot delete an account); wrong -> 403
  - the account row is removed; if anything still references it, it is anonymised and archived instead."""
import shutil, sys, time

PATH = "/opt/odoo/saasmaster/xrero_office_accounts/controllers/main.py"
MARK = "/office/api/delete"
ANCHOR = '    @http.route("/office/auth/google", type="http", auth="public", csrf=False)'

CODE = '''    # ------------------------------------------------------------------ #
    # Delete account - in-app account deletion (App Store guideline 5.1.1(v))
    # ------------------------------------------------------------------ #
    @http.route("/office/api/delete", type="http", auth="public", methods=["POST"], csrf=False)
    def api_delete(self, **kw):
        data = self._body()
        payload = self._users()._decode_token(data.get("token"))
        if not payload:
            return self._json({"ok": False, "error": "Invalid or expired token."}, status=401)
        user = self._users().browse(payload["uid"])
        if not user.exists():
            return self._json({"ok": True, "deleted": True})
        if user.password_hash and not user._verify_password(data.get("password") or ""):
            return self._json({"ok": False, "error": "Wrong password."}, status=403)
        try:
            with request.env.cr.savepoint():
                user.unlink()
        except Exception:  # noqa: BLE001 - still referenced somewhere: keep the row, remove the person
            user.write({"name": "Deleted account", "email": "deleted-%d@deleted.invalid" % user.id,
                        "password_hash": False, "google_sub": False, "status": "disabled", "active": False})
        return self._json({"ok": True, "deleted": True})

'''


def main():
    s = open(PATH, encoding="utf-8").read()
    if MARK in s:
        print("already installed")
        return 0
    if ANCHOR not in s:
        print("anchor not found - not changed")
        return 1
    bak = PATH + ".bak_delete_" + time.strftime("%Y%m%d_%H%M%S")
    shutil.copy2(PATH, bak)
    s = s.replace(ANCHOR, CODE + ANCHOR, 1)
    compile(s, PATH, "exec")                      # never write a file that does not parse
    open(PATH, "w", encoding="utf-8").write(s)
    print("installed; backup:", bak)
    return 0


if __name__ == "__main__":
    sys.exit(main())
