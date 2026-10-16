#!/usr/bin/env python3
"""
Station NFC reader service for a PN532 board wired to the Pi (for example the
HiLetgo PN532 NFC Module V3) — the reader built into the station case.

It reads each tag's UID (the built-in serial number; nothing is written to
tags) and hands it to the station app as it's tapped:

  GET /nfc/events   Server-Sent Events, kept open by the station page:
                      event: tag     data: {"uid": "04A1B2C3D4E5F6"}
                      event: status  data: {"reader": true}   (false + "error" if the board isn't answering)
  GET /nfc/status   {"reader": true|false, "error": "...", "taps": n}

A tag sitting on the reader counts once; it has to be lifted off (about half a
second) before the same tag counts again.

Listens on 127.0.0.1:8766 only. Wiring, switches and install: station/pi/README.md.

  STATION_NFC=i2c   (default) board on the Pi's I2C pins
  STATION_NFC=uart  board on the Pi's serial pins (/dev/serial0)
  STATION_NFC=stdin no board: type UIDs + Enter (for testing the service)
"""
import json
import os
import queue
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST, PORT = "127.0.0.1", 8766
REMOVED_AFTER = 0.6      # seconds without seeing a tag before it counts as lifted off
RETRY_EVERY = 5          # seconds between attempts to reach the board


def open_reader(mode):
    """Returns a function read() -> bytes UID or None (no tag). Raises if the board can't be reached."""
    if mode == "stdin":
        q = queue.Queue()
        threading.Thread(target=lambda: [q.put(bytes.fromhex(l.strip().replace(":", ""))) for l in sys.stdin if l.strip()], daemon=True).start()

        def read():
            try:
                return q.get(timeout=0.2)
            except queue.Empty:
                return None
        return read

    if mode == "uart":
        import serial                                     # pip: pyserial
        from adafruit_pn532.uart import PN532_UART        # pip: adafruit-circuitpython-pn532
        pn = PN532_UART(serial.Serial("/dev/serial0", baudrate=115200, timeout=0.1), debug=False)
    else:
        import board, busio                               # pip: adafruit-blinka
        from adafruit_pn532.i2c import PN532_I2C
        pn = PN532_I2C(busio.I2C(board.SCL, board.SDA), debug=False)
    pn.firmware_version                                   # raises if the board isn't answering
    pn.SAM_configuration()
    return lambda: pn.read_passive_target(timeout=0.15)


class TagWatcher:
    """Turns a stream of raw reads into taps: one per tag placed on the reader."""

    def __init__(self, emit, now=time.monotonic):
        self.emit, self.now = emit, now
        self.current, self.last_seen = None, 0.0

    def saw(self, uid):
        t = self.now()
        if uid is None:
            if self.current and t - self.last_seen > REMOVED_AFTER:
                self.current = None
            return
        uid_hex = uid.hex().upper()
        if uid_hex != self.current:
            self.current = uid_hex
            self.emit(uid_hex)
        self.last_seen = t


class Hub:
    """Fans tap/status events out to every open /nfc/events connection."""

    def __init__(self):
        self.lock, self.clients = threading.Lock(), set()
        self.state = {"reader": False, "error": "starting", "taps": 0}

    def subscribe(self):
        q = queue.Queue(maxsize=50)
        with self.lock:
            self.clients.add(q)
        return q

    def unsubscribe(self, q):
        with self.lock:
            self.clients.discard(q)

    def publish(self, event, data):
        with self.lock:
            for q in list(self.clients):
                try:
                    q.put_nowait((event, data))
                except queue.Full:
                    pass

    def set_reader(self, ok, error=None):
        if self.state["reader"] != ok or self.state.get("error") != error:
            self.state.update(reader=ok, error=error)
            self.publish("status", {"reader": ok, **({"error": error} if error else {})})

    def tap(self, uid):
        self.state["taps"] += 1
        self.publish("tag", {"uid": uid})


def run_reader(hub, mode):
    watcher = TagWatcher(hub.tap)
    while True:
        try:
            read = open_reader(mode)
            hub.set_reader(True)
            while True:
                watcher.saw(read())
        except Exception as e:   # unplugged, loose wire, bus error: report it and keep retrying
            hub.set_reader(False, f"{type(e).__name__}: {e}"[:160])
            time.sleep(RETRY_EVERY)


def make_handler(hub):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def _head(self, code, ctype, length=None):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Access-Control-Allow-Origin", "*")    # the kiosk page; only reachable from this Pi
            self.send_header("Cache-Control", "no-cache")
            if length is not None:
                self.send_header("Content-Length", str(length))
            self.end_headers()

        def do_GET(self):
            if self.path == "/nfc/status":
                data = json.dumps(hub.state).encode()
                self._head(200, "application/json", len(data)); self.wfile.write(data); return
            if self.path != "/nfc/events":
                self._head(404, "application/json", 2); self.wfile.write(b"{}"); return
            self._head(200, "text/event-stream")
            q = hub.subscribe()
            try:
                st = {"reader": hub.state["reader"], **({"error": hub.state["error"]} if hub.state.get("error") else {})}
                self.wfile.write(f"retry: 2000\nevent: status\ndata: {json.dumps(st)}\n\n".encode()); self.wfile.flush()
                while True:
                    try:
                        event, data = q.get(timeout=15)
                        self.wfile.write(f"event: {event}\ndata: {json.dumps(data)}\n\n".encode())
                    except queue.Empty:
                        self.wfile.write(b": keep-alive\n\n")
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError, OSError):
                pass
            finally:
                hub.unsubscribe(q)

        def log_message(self, *args):
            pass

    return Handler


def main():
    mode = os.environ.get("STATION_NFC", "i2c").lower()
    hub = Hub()
    threading.Thread(target=run_reader, args=(hub, mode), daemon=True).start()
    ThreadingHTTPServer((HOST, PORT), make_handler(hub)).serve_forever()


if __name__ == "__main__":
    main()
