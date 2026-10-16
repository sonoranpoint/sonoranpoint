import sys, importlib.util, time, subprocess, json, urllib.request, threading
spec = importlib.util.spec_from_file_location("nfc", __import__("os").path.join(__import__("os").path.dirname(__import__("os").path.abspath(__file__)), "nfc_reader.py")); nfc = importlib.util.module_from_spec(spec); spec.loader.exec_module(nfc)
ok = lambda c, m: print(("pass  " if c else "FAIL  ") + m) or (c or sys.exit(1))
t = [0.0]; got = []
w = nfc.TagWatcher(got.append, now=lambda: t[0])
A, B = bytes.fromhex("04a1b2c3d4e5f6"), bytes.fromhex("deadbeef")
for i in range(10): t[0] += 0.15; w.saw(A)                 # tag held on the reader 1.5 s
ok(got == ["04A1B2C3D4E5F6"], "tag held on the reader counts once")
t[0] += 0.15; w.saw(None); t[0] += 0.15; w.saw(A)        # brief miss (shorter than lift-off)
ok(len(got) == 1, "a flicker in reading doesn't double-count")
for i in range(6): t[0] += 0.15; w.saw(None)              # lifted off
t[0] += 0.15; w.saw(A)
ok(got == ["04A1B2C3D4E5F6"] * 2, "lift off and tap again counts again")
t[0] += 0.15; w.saw(B)
ok(got[-1] == "DEADBEEF", "a different tag counts right away (4-byte MIFARE card)")
# end to end: service in stdin mode, SSE client
p = subprocess.Popen([sys.executable, "-I", __import__("os").path.join(__import__("os").path.dirname(__import__("os").path.abspath(__file__)), "nfc_reader.py")], stdin=subprocess.PIPE, env={"STATION_NFC": "stdin"}, text=True)
time.sleep(0.8)
st = json.load(urllib.request.urlopen("http://127.0.0.1:8766/nfc/status"))
ok(st["reader"] is True, "service up, reader ready")
events = []
def listen():
    r = urllib.request.urlopen("http://127.0.0.1:8766/nfc/events", timeout=10); ev = None
    for line in r:
        line = line.decode().strip()
        if line.startswith("event:"): ev = line[6:].strip()
        elif line.startswith("data:"): events.append((ev, json.loads(line[5:]))); 
        if len(events) >= 3: return
th = threading.Thread(target=listen, daemon=True); th.start(); time.sleep(0.5)
p.stdin.write("04:A1:B2:C3:D4:E5:F6\n"); p.stdin.flush(); time.sleep(1.0)
p.stdin.write("DEADBEEF\n"); p.stdin.flush(); th.join(5)
ok(events[0] == ("status", {"reader": True}), "page gets reader status on connect")
ok(events[1] == ("tag", {"uid": "04A1B2C3D4E5F6"}) and events[2] == ("tag", {"uid": "DEADBEEF"}), "taps stream to the page")
ok(json.load(urllib.request.urlopen("http://127.0.0.1:8766/nfc/status"))["taps"] == 2, "tap count")
p.kill()
# no board: i2c mode without libraries -> reports not responding, keeps running
p = subprocess.Popen([sys.executable, "-I", __import__("os").path.join(__import__("os").path.dirname(__import__("os").path.abspath(__file__)), "nfc_reader.py")], env={"STATION_NFC": "i2c"}); time.sleep(0.8)
st = json.load(urllib.request.urlopen("http://127.0.0.1:8766/nfc/status"))
ok(st["reader"] is False and st["error"], "no board -> reports the problem instead of crashing: " + st["error"])
p.kill()
