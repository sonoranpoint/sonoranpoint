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
  // a tap saved while offline
  doc.querySelector("#wifi").click(); await sleep(50);
  E("handleTag('04BA00000001')"); await sleep(300); E("handleTag('04DE000101')"); await sleep(400); E("endSession && endSession()"); await sleep(200);
  check(E("S.saved.queue.length") >= 1, "offline tap saved on the station");
  // pause, then reconnect
  doc.querySelector("#acct").click(); await sleep(50);
  doc.querySelector("#wifi").click(); await sleep(50);
  await E("call('station_heartbeat', { p_device_key: S.saved.deviceKey })"); await sleep(200);
  check(/This station is paused/.test(text()) && /Demo Air Services/.test(text()), "paused account -> station shows 'This station is paused'");
  check(!!E("S.saved.deviceKey"), "still paired (no new code needed)");
  await E("flush()"); await sleep(300);
  check(E("S.saved.queue.length") >= 1, "saved taps are kept while paused");
  E("handleTag('04BA00000002')"); await sleep(300);
  check(/Station paused/.test(text()) && !E("S.session"), "badge taps are refused while paused");
  doc.querySelector("#acct").click(); await sleep(50);
  await E("call('station_heartbeat', { p_device_key: S.saved.deviceKey })"); await sleep(1500);
  check(/Tap your badge/.test(text()) && !/paused/i.test(text()), "account back on -> station works again on its own");
  check(E("S.saved.queue.length") === 0, "saved taps sync after resume");
  E("handleTag('04BA00000002')"); await sleep(300);
  check(!!E("S.session"), "badge tap works again");
  check(errors.length === 0, "no script errors " + errors.join(";"));
  process.exit();
})();
