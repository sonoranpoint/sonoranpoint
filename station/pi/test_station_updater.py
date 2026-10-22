#!/usr/bin/env python3
"""Checks station_updater.py without a Pi: a fake release server on localhost, a temp folder for /opt/sp-station.

  python3 station/pi/test_station_updater.py
"""
import hashlib, importlib.util, io, json, os, sys, tempfile, threading, time, urllib.request, zipfile
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from functools import partial

HERE = os.path.dirname(os.path.abspath(__file__))
fails = 0


def check(cond, msg):
    global fails
    print(("pass  " if cond else "FAIL  ") + msg)
    fails += 0 if cond else 1


def release(srv_dir, version, files=None, sha=None):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        for name, body in (files or {"index.html": f'<script>const VERSION = "{version}";</script>', "brand/logo.png": "png"}).items():
            z.writestr(name, body)
    data = buf.getvalue(); name = version.replace("+", "-") + ".zip"
    open(os.path.join(srv_dir, name), "wb").write(data)
    json.dump({"version": version, "file": name, "sha256": sha or hashlib.sha256(data).hexdigest(), "size": len(data)},
              open(os.path.join(srv_dir, "latest.json"), "w"))


srv_dir, opt = tempfile.mkdtemp(), tempfile.mkdtemp()
class Quiet(SimpleHTTPRequestHandler):
    def log_message(self, *a): pass
web = ThreadingHTTPServer(("127.0.0.1", 0), partial(Quiet, directory=srv_dir))
pass
threading.Thread(target=web.serve_forever, daemon=True).start()
os.environ.update(STATION_DIR=opt, STATION_RELEASES=f"http://127.0.0.1:{web.server_port}/latest.json", STATION_OK_WITHIN="1", STATION_PORT="0")
spec = importlib.util.spec_from_file_location("upd", os.path.join(HERE, "station_updater.py")); u = importlib.util.module_from_spec(spec); spec.loader.exec_module(u)

# A Pi set up by hand: version A on screen.
os.makedirs(os.path.join(opt, "releases", "A", "brand"))
open(os.path.join(opt, "releases", "A", "index.html"), "w").write('const VERSION = "A";')
u.point("current", "A")
check(u.status()["current"] == "A", "starts on the version set up by hand")

release(srv_dir, "B")
check(u.check() == "B" and u.status()["current"] == "A", "a newer version downloads and waits (nothing changes on screen)")
check(u.check() == "B" and len(os.listdir(os.path.join(opt, "releases"))) == 2, "checking again doesn't download it twice")
r = u.apply()
check(r["ok"] and u.status()["current"] == "B" and u.status()["previous"] == "A", "applying puts it on screen and keeps the one before")
u.confirm("B")
time.sleep(1.2)
check(not u.watchdog() and u.status()["current"] == "B", "a version that says it started stays")

release(srv_dir, "C")
u.check(); u.apply()
time.sleep(1.2)
check(u.watchdog() and u.status()["current"] == "B" and "C" in u.status()["bad"], "a version that never says it started goes back to the one before")
check(u.check() is None and u.status()["staged"] is None, "and is never tried again")

release(srv_dir, "D", sha="0" * 64)
check(u.check() is None and "checksum" in u.status()["error"] and not os.path.exists(os.path.join(opt, "releases", "D")), "a download that doesn't match its checksum is thrown away")
release(srv_dir, "E", files={"../evil.txt": "x", "index.html": 'const VERSION = "E";'})
check(u.check() is None and not os.path.exists(os.path.join(opt, "evil.txt")), "a zip that tries to write outside its folder is refused")
release(srv_dir, "F", files={"index.html": 'const VERSION = "something else";'})
check(u.check() is None and "version" in u.status()["error"], "a release whose page has a different version is refused")
check(u.apply()["error"] == "nothing_staged", "nothing to apply when nothing's waiting")

# The web server: serves the current version, nothing outside it.
srv = ThreadingHTTPServer(("127.0.0.1", 0), u.Handler); threading.Thread(target=srv.serve_forever, daemon=True).start()
base = f"http://127.0.0.1:{srv.server_address[1]}"
get = lambda p: urllib.request.urlopen(base + p, timeout=5)
check(b'VERSION = "B"' in get("/").read(), "serves the version on screen at /")
check(json.loads(get("/update/status").read())["current"] == "B", "reports its status to the page")
try:
    get("/../state.json"); check(False, "doesn't serve files outside the app")
except Exception:
    check(True, "doesn't serve files outside the app")
release(srv_dir, "G")
r = json.loads(urllib.request.urlopen(urllib.request.Request(base + "/update/check", data=b"{}", method="POST"), timeout=30).read())
r2 = json.loads(urllib.request.urlopen(urllib.request.Request(base + "/update/apply", data=b"{}", method="POST"), timeout=5).read())
ok = json.loads(urllib.request.urlopen(urllib.request.Request(base + "/update/ok", data=b'{"version": "G"}', method="POST"), timeout=5).read())
check(r["staged"] == "G" and r2["ok"] and ok["ok"] and u.load_state().get("waiting") is None and b'"G"' in get("/").read(), "check, apply and OK over HTTP")
check(sorted(os.listdir(os.path.join(opt, "releases"))) == ["B", "G"], "old versions are cleaned up (keeps the one on screen and the one before)")

web.shutdown(); srv.shutdown()
print("ALL PASSED" if not fails else f"{fails} FAILED")
sys.exit(1 if fails else 0)
