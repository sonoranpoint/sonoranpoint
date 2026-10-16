#!/usr/bin/env python3
"""
Station Wi-Fi helper for the Raspberry Pi.

The station app is a web page running in kiosk mode, and web pages can't
control Wi-Fi. This tiny service does it for the page, using NetworkManager
(nmcli, the default on Raspberry Pi OS Bookworm and later). It only listens on
127.0.0.1, so nothing on the network can reach it.

  GET  /wifi/scan     -> [{"ssid", "signal": 0-4, "secure": bool, "connected": bool}, ...]
  POST /wifi/connect  {"ssid": "...", "password": "..."} -> {"ok": true} | {"ok": false, "error": "wrong_password" | ...}
  GET  /wifi/status   -> {"ssid": "T3-Operations" | null, "wired": bool}

Run it as a systemd service (see station/pi/README.md). Standard library only.
"""
import json
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST, PORT = "127.0.0.1", 8765


def nmcli(*args, timeout=30):
    return subprocess.run(["nmcli", *args], capture_output=True, text=True, timeout=timeout)


def split_terse(line):
    """nmcli -t separates fields with ':' and escapes ':' and '\\' inside values."""
    fields, cur, esc = [], [], False
    for ch in line:
        if esc:
            cur.append(ch); esc = False
        elif ch == "\\":
            esc = True
        elif ch == ":":
            fields.append("".join(cur)); cur = []
        else:
            cur.append(ch)
    fields.append("".join(cur))
    return fields


def parse_scan(output):
    best = {}
    for line in output.splitlines():
        if not line.strip():
            continue
        in_use, ssid, signal, security = (split_terse(line) + ["", "", "", ""])[:4]
        if not ssid:
            continue  # hidden networks
        try:
            pct = int(signal)
        except ValueError:
            pct = 0
        net = {"ssid": ssid, "signal": min(4, max(1, round(pct / 25))), "secure": security not in ("", "--"),
               "connected": in_use.strip() == "*", "_pct": pct}
        # The same network shows once per access point; keep the strongest.
        if ssid not in best or pct > best[ssid]["_pct"] or net["connected"]:
            net["connected"] = net["connected"] or best.get(ssid, {}).get("connected", False)
            best[ssid] = net
    nets = sorted(best.values(), key=lambda n: (not n["connected"], -n["_pct"]))
    for n in nets:
        n.pop("_pct")
    return nets


def scan():
    r = nmcli("-t", "-f", "IN-USE,SSID,SIGNAL,SECURITY", "device", "wifi", "list", "--rescan", "yes")
    return parse_scan(r.stdout)


def connect(ssid, password):
    if not ssid:
        return {"ok": False, "error": "not_found"}
    args = ["device", "wifi", "connect", ssid] + (["password", password] if password else [])
    r = nmcli(*args, timeout=45)
    if r.returncode == 0:
        return {"ok": True}
    msg = (r.stderr or r.stdout).lower()
    if "secrets were required" in msg or "802-11-wireless-security" in msg or "password" in msg:
        return {"ok": False, "error": "wrong_password"}
    if "no network with ssid" in msg:
        return {"ok": False, "error": "not_found"}
    return {"ok": False, "error": "failed", "detail": msg.strip()[:200]}


def status():
    r = nmcli("-t", "-f", "TYPE,STATE,CONNECTION", "device")
    ssid, wired = None, False
    for line in r.stdout.splitlines():
        typ, state, conn = (split_terse(line) + ["", "", ""])[:3]
        if state.startswith("connected"):
            if typ == "wifi":
                ssid = conn
            elif typ == "ethernet":
                wired = True
    return {"ssid": ssid, "wired": wired}


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")       # the kiosk page; only reachable from this Pi
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_OPTIONS(self):
        self._send(204, {})

    def do_GET(self):
        try:
            if self.path == "/wifi/scan":
                return self._send(200, scan())
            if self.path == "/wifi/status":
                return self._send(200, status())
            self._send(404, {"error": "not_found"})
        except Exception as e:  # never crash the kiosk over Wi-Fi
            self._send(500, {"error": str(e)[:200]})

    def do_POST(self):
        try:
            if self.path != "/wifi/connect":
                return self._send(404, {"error": "not_found"})
            length = min(int(self.headers.get("Content-Length", 0)), 4096)
            body = json.loads(self.rfile.read(length) or b"{}")
            self._send(200, connect(str(body.get("ssid", ""))[:64], str(body.get("password", ""))[:128]))
        except Exception as e:
            self._send(500, {"ok": False, "error": "failed", "detail": str(e)[:200]})

    def log_message(self, *args):  # keep the journal quiet (no passwords in logs)
        pass


if __name__ == "__main__":
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
