"""office_cors.py - lets the Xrero Office desktop pages on macOS (served from file://, Origin "null") call the account API
(/office/api/login, signup, validate, delete) on xrero.com.

The API authenticates with the account token in the request body, never with cookies, so "Access-Control-Allow-Origin: *"
gives a web page nothing it could not already do with a plain form post. The Mac pages send text/plain (a "simple"
request), so no preflight route is needed.

Run ON THE SERVER (as root):  python3 office_cors.py   then restart the master Odoo container.
Idempotent; backs up controllers/main.py first (main.py.bak_cors_<timestamp>)."""
import shutil, sys, time

PATH = "/opt/odoo/saasmaster/xrero_office_accounts/controllers/main.py"
OLD = '            headers=[("Content-Type", "application/json")],\n'
NEW = ('            headers=[("Content-Type", "application/json"),\n'
       '                     ("Access-Control-Allow-Origin", "*")],          # Xrero Office for Mac (file:// pages)\n')


def main():
    s = open(PATH, encoding="utf-8").read()
    if "Access-Control-Allow-Origin" in s:
        print("already installed")
        return 0
    if s.count(OLD) != 1:
        print("anchor found %d times - not changed" % s.count(OLD))
        return 1
    bak = PATH + ".bak_cors_" + time.strftime("%Y%m%d_%H%M%S")
    shutil.copy2(PATH, bak)
    s = s.replace(OLD, NEW, 1)
    compile(s, PATH, "exec")                      # never write a file that does not parse
    open(PATH, "w", encoding="utf-8").write(s)
    print("installed; backup:", bak)
    return 0


if __name__ == "__main__":
    sys.exit(main())
