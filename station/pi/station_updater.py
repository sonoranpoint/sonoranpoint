#!/usr/bin/env python3
"""
Station app server and self-updater for the Raspberry Pi.

Serves the station app to the kiosk browser at http://localhost/ and keeps it up to date:

  * Every 30 minutes (and a minute after starting) it reads
      https://app.sonoranpoint.com/station-release/latest.json
    ({"version", "file", "sha256", "size"}), and when there's a newer station version it downloads
    the zip next to it, checks its size and SHA-256, unpacks it into releases/<version>/ and keeps
    it ready ("staged"). Nothing changes on screen yet.
  * The station page asks GET /update/status every minute. When something is staged and nobody is
    using the station, it calls POST /update/apply and reloads: the new version is on screen.
  * Releases are signed (Ed25519). With a public key installed (release_key.pub in STATION_DIR, or
    STATION_RELEASE_KEY_FILE), a release without a valid Sonoran Point signature is never downloaded.
  * The new page calls POST /update/ok once it has started. If it doesn't within 5 minutes, the
    updater switches back to the version before and never tries that version again.

Files (STATION_DIR, default /opt/sp-station):
  releases/<version>/   index.html + brand/
  current, previous     links to the version on screen and the one before
  state.json            what's staged, what's waiting for its OK, versions that failed

Listens on 127.0.0.1 only (port 80 by default; STATION_PORT to change).
Install: station/pi/README.md.  Tests: station/pi/test_station_updater.py.
"""
import base64
import hashlib
import io
import json
import os
import random
import shutil
import subprocess
import tempfile
import threading
import time
import urllib.request
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = "127.0.0.1"
PORT = int(os.environ.get("STATION_PORT", "80"))
DIR = os.environ.get("STATION_DIR", "/opt/sp-station")
MANIFEST = os.environ.get("STATION_RELEASES", "https://app.sonoranpoint.com/station-release/latest.json")
CHECK_EVERY = int(os.environ.get("STATION_CHECK_EVERY", str(30 * 60)))   # seconds
FIRST_CHECK = int(os.environ.get("STATION_FIRST_CHECK", "60"))
OK_WITHIN = int(os.environ.get("STATION_OK_WITHIN", str(5 * 60)))        # seconds for a new version to say it started
MAX_SIZE = 50 * 1024 * 1024
KEY_FILE = os.environ.get("STATION_RELEASE_KEY_FILE") or os.path.join(DIR, "release_key.pub")
TYPES = {".html": "text/html; charset=utf-8", ".png": "image/png", ".ico": "image/x-icon", ".svg": "image/svg+xml",
         ".js": "text/javascript", ".css": "text/css", ".json": "application/json", ".woff2": "font/woff2"}

lock = threading.RLock()
last = {"checked_at": None, "error": None, "latest": None}


def path(*p):
    return os.path.join(DIR, *p)


def load_state():
    try:
        with open(path("state.json")) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_state(st):
    tmp = path("state.json.tmp")
    with open(tmp, "w") as f:
        json.dump(st, f)
    os.replace(tmp, path("state.json"))


def version_of(link):
    try:
        return os.path.basename(os.readlink(path(link)))
    except OSError:
        return None


def point(link, version):
    """Atomically point current/previous at releases/<version>."""
    tmp = path(link + ".tmp")
    if os.path.lexists(tmp):
        os.remove(tmp)
    os.symlink(os.path.join("releases", version), tmp)
    os.replace(tmp, path(link))


def prune(keep):
    for v in os.listdir(path("releases")):
        if v not in keep and not v.endswith(".tmp"):
            shutil.rmtree(path("releases", v), ignore_errors=True)


# ---------------------------------------------------------------- checking for updates
def fetch(url, limit):
    with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "sp-station-updater"}), timeout=60) as r:
        data = r.read(limit + 1)
    if len(data) > limit:
        raise ValueError("download too big")
    return data


def release_message(m):
    return f"sonoranpoint-station-release\n{m['version']}\n{m['file']}\n{m['sha256']}\n{m['size']}\n".encode()


def signed_by_us(m):
    """True when the release info carries a valid signature from our release key (or no key is installed yet)."""
    try:
        with open(KEY_FILE, "rb") as f:
            pem = f.read()
    except FileNotFoundError:
        return True
    try:
        sig = base64.b64decode(m.get("sig") or "", validate=True)
    except Exception:
        return False
    if len(sig) != 64:
        return False
    msg = release_message(m)
    try:  # the cryptography library when it's there, else the openssl command (on every Raspberry Pi OS)
        from cryptography.hazmat.primitives.serialization import load_pem_public_key
        try:
            load_pem_public_key(pem).verify(sig, msg)
            return True
        except Exception:
            return False
    except ImportError:
        pass
    with tempfile.TemporaryDirectory() as d:
        mf, sf = os.path.join(d, "m"), os.path.join(d, "s")
        with open(mf, "wb") as f:
            f.write(msg)
        with open(sf, "wb") as f:
            f.write(sig)
        r = subprocess.run(["openssl", "pkeyutl", "-verify", "-pubin", "-inkey", KEY_FILE, "-rawin", "-in", mf, "-sigfile", sf], capture_output=True)
        return r.returncode == 0


def check():
    """Downloads and stages the newest version if it's new to us. Returns the staged version or None."""
    try:
        m = json.loads(fetch(MANIFEST, 64 * 1024))
        version, name, sha, size = m["version"], m["file"], m["sha256"].lower(), int(m["size"])
        if not version or "/" in version or version.startswith(".") or "/" in name or size > MAX_SIZE:
            raise ValueError("bad release info")
        if not signed_by_us(m):
            raise ValueError("release isn't signed by Sonoran Point: not installing it")
        with lock:
            st = load_state()
            last.update(latest=version, error=None)
            if version in (version_of("current"), st.get("staged")) or version in st.get("bad", []):
                return st.get("staged")
        data = fetch(MANIFEST.rsplit("/", 1)[0] + "/" + name, MAX_SIZE)
        if len(data) != size or hashlib.sha256(data).hexdigest() != sha:
            raise ValueError("download didn't match its checksum")
        unpack(data, version)
        with lock:
            st = load_state()
            st["staged"] = version
            save_state(st)
            prune({version_of("current"), version_of("previous"), version})
        return version
    except Exception as e:  # offline, server down, bad download: try again next time
        last["error"] = str(e)[:200]
        return None
    finally:
        last["checked_at"] = time.time()


def unpack(data, version):
    tmp = tempfile.mkdtemp(dir=path("releases"), suffix=".tmp")
    try:
        with zipfile.ZipFile(io.BytesIO(data)) as z:
            for info in z.infolist():
                target = os.path.realpath(os.path.join(tmp, info.filename))
                if not target.startswith(os.path.realpath(tmp) + os.sep):
                    raise ValueError("unsafe file name in the release")
            z.extractall(tmp)
        with open(os.path.join(tmp, "index.html"), encoding="utf-8") as f:
            if f'const VERSION = "{version}"' not in f.read():
                raise ValueError("release doesn't contain the version it says")
        dest = path("releases", version)
        if os.path.exists(dest):
            shutil.rmtree(dest)
        os.rename(tmp, dest)
    except Exception:
        shutil.rmtree(tmp, ignore_errors=True)
        raise


# ---------------------------------------------------------------- switching versions
def apply():
    with lock:
        st = load_state()
        v = st.get("staged")
        if not v or not os.path.isdir(path("releases", v)):
            return {"ok": False, "error": "nothing_staged"}
        cur = version_of("current")
        if cur:
            point("previous", cur)
        point("current", v)
        st.update(staged=None, waiting={"version": v, "until": time.time() + OK_WITHIN})
        save_state(st)
        return {"ok": True, "version": v}


def confirm(version):
    with lock:
        st = load_state()
        w = st.get("waiting")
        if w and w.get("version") == version and version == version_of("current"):
            st["waiting"] = None
            save_state(st)
        return {"ok": True}


def watchdog():
    """A new version that never said it started goes back to the one before."""
    with lock:
        st = load_state()
        w = st.get("waiting")
        if not w or time.time() < w["until"]:
            return False
        prev = version_of("previous")
        if prev and os.path.isdir(path("releases", prev)):
            point("current", prev)
        st.setdefault("bad", []).append(w["version"])
        st["bad"] = st["bad"][-20:]
        st["waiting"] = None
        save_state(st)
        return True


def status():
    st = load_state()
    return {"current": version_of("current"), "staged": st.get("staged"), "previous": version_of("previous"),
            "latest": last["latest"], "checked_at": last["checked_at"], "error": last["error"],
            "waiting": (st.get("waiting") or {}).get("version"), "bad": st.get("bad", [])}


# ---------------------------------------------------------------- web server
class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="application/json", cache="no-store"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", cache)
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        p = self.path.split("?", 1)[0]
        if p == "/update/status":
            return self._send(200, status())
        rel = "index.html" if p in ("/", "") else p.lstrip("/")
        root = os.path.realpath(path("current"))
        f = os.path.realpath(os.path.join(root, rel))
        if not f.startswith(root + os.sep) or not os.path.isfile(f):
            return self._send(404, {"error": "not_found"})
        with open(f, "rb") as fh:
            body = fh.read()
        ext = os.path.splitext(f)[1].lower()
        self._send(200, body, TYPES.get(ext, "application/octet-stream"), "no-store" if ext == ".html" else "no-cache")

    def do_POST(self):
        p = self.path.split("?", 1)[0]
        n = min(int(self.headers.get("Content-Length") or 0), 4096)
        try:
            body = json.loads(self.rfile.read(n) or b"{}")
        except ValueError:
            body = {}
        if p == "/update/apply":
            return self._send(200, apply())
        if p == "/update/ok":
            return self._send(200, confirm(str(body.get("version", ""))))
        if p == "/update/check":
            return self._send(200, {"staged": check()})
        self._send(404, {"error": "not_found"})

    def log_message(self, *args):
        pass


def loop():
    time.sleep(FIRST_CHECK)
    while True:
        check()
        time.sleep(CHECK_EVERY + random.randint(0, 300))   # spread stations out


def guard():
    while True:
        watchdog()
        time.sleep(15)


def main():
    os.makedirs(path("releases"), exist_ok=True)
    threading.Thread(target=loop, daemon=True).start()
    threading.Thread(target=guard, daemon=True).start()
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
