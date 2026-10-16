const { JSDOM } = require("jsdom");
const fs = require("fs");
const src = fs.readFileSync(process.argv[2], "utf8");
const errors = [];
const dom = new JSDOM("<!doctype html><html><body>" + src + "</body></html>", { runScripts: "dangerously", pretendToBeVisual: true, url: "https://example.test/",
  beforeParse(w) { w.crypto.randomUUID ??= () => require("crypto").randomUUID(); } });
dom.window.addEventListener("error", (e) => errors.push(e.message));
const E = (s) => dom.window.eval(s), doc = dom.window.document, sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const text = () => doc.querySelector("#screen").textContent.replace(/\s+/g, " ");
const check = (c, m) => { console.log((c ? "pass  " : "FAIL  ") + m + (c ? "" : "\n      " + text().slice(0, 300))); if (!c) process.exitCode = 1; };
const click = async (sel, ms = 60) => { const el = doc.querySelector("#screen " + sel); if (!el) throw new Error("no " + sel + " :: " + text().slice(0, 200)); el.click(); await sleep(ms); };
(async () => {
  await sleep(300);
  E("demoDevice.skip(); wizStart(); S.wiz.code='DEMO0001'"); await E("activate()"); await sleep(300); E("finishSetup()"); await sleep(100);
  // fake EventSource standing in for pi/nfc_reader.py
  E(`window.FakeES = class { constructor(u) { this.u = u; this.h = {}; window.__es = this; } addEventListener(t, f) { this.h[t] = f; } fire(t, d) { this.h[t]({ data: JSON.stringify(d) }); } }; window.EventSource = FakeES;`);
  E("connectReader()");
  check(E("__es.u") === "http://127.0.0.1:8766/nfc/events", "station connects to the reader service");
  E("__es.fire('status', { reader: false, error: 'OSError' })"); await sleep(50);
  check(/NFC reader not responding/.test(text()), "reader problem shows on the station");
  E("__es.fire('status', { reader: true })"); await sleep(50);
  check(!/NFC reader not responding/.test(text()), "clears when it's back");
  E("__es.fire('tag', { uid: '04BA00000001' })"); await sleep(400);
  E("__es.fire('tag', { uid: '04DE000101' })"); await sleep(600);
  check(/Checked out|checked out/i.test(text()), "badge then item from the built-in reader -> checkout");
  check(errors.length === 0, "no script errors " + errors.join(";"));
  process.exit();
})();
