const { JSDOM } = require("jsdom");
const fs = require("fs");
const html = "<!doctype html><html><head><meta charset=utf-8></head><body>" + fs.readFileSync(process.argv[2], "utf8") + "</body></html>";
const errors = [];
const dom = new JSDOM(html, { runScripts: "dangerously", pretendToBeVisual: true, url: "https://example.test/",
  beforeParse(w) { w.crypto.randomUUID ??= () => require("crypto").randomUUID(); } });
dom.window.addEventListener("error", (e) => errors.push(e.message));
const E = (s) => dom.window.eval(s);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const doc = dom.window.document;
const text = () => doc.querySelector("#screen").textContent.replace(/\s+/g, " ").trim();
const check = (c, m) => { console.log((c ? "pass  " : "FAIL  ") + m + (c ? "" : "\n      screen: " + text().slice(0, 400))); if (!c) process.exitCode = 1; };
const tap = async (uid, ms = 450) => { E(`handleTag('${uid}')`); await sleep(ms); };
(async () => {
  await sleep(300);
  E("demoDevice.skip(); wizStart(); S.wiz.code='DEMO0001'"); await E("activate()"); await sleep(300); E("finishSetup()"); await sleep(100);
  E(`document.querySelector('#timeSel').value='09:00'; document.querySelector('#timeSel').dispatchEvent(new Event('change'))`);
  // Jordan has Radio 01 first
  await tap("04BA00000002", 100); await tap("04DE000501"); E("endSession()"); E("endSummary()");
  // Alex's visit: 6 items + return for Jordan + a refused (maintenance) + one checked out then returned
  E(`demo.setStatus('q22','maintenance')`);
  await tap("04BA00000001", 100);
  for (const u of ["04DE000101", "04DE000201", "04DE000301", "04DE000401", "04DE000601", "04DE000102"]) await tap(u);
  await tap("04DE000501"); await tap("04DE000202"); await tap("04DE000602"); await tap("04DE000602");
  const rows = doc.querySelectorAll("#screen .results > *").length;
  check(rows === 9, `one row per item: 10 taps on 9 items -> ${rows} rows`);
  check(/This visit: 6 checked out · 2 returned · 1 not done/.test(text()), "running tally of the visit");
  check(/for Jordan Lee/.test(text()), "row shows the return was for Jordan");
  E("document.querySelector('#doneBtn').click()"); await sleep(50);
  check(/Any problems with what you returned\?/.test(text()) && /Radio 01, Van Keys 02/.test(text()), "Done after returns -> asks if anything's wrong with them");
  E("document.querySelector('#ckNo').click()"); await sleep(50);
  const t = text();
  check(/All set, Alex/.test(t) && doc.querySelector("#screen .summary.good"), "No -> green confirmation screen");
  check(/Checked out \(6\)/.test(t) && /Vacuum 01/.test(t) && /Due back by 5:00 PM/.test(t), "lists the 6 items checked out with due times");
  check(/Returned \(2\)/.test(t) && /For Jordan Lee/.test(t), "lists returns, including Radio 01 returned for Jordan");
  check(/Not done \(1\)/.test(t) && /Blower 02/.test(t) && /in maintenance/.test(t), "lists what didn't go through and why");
  check(!/Van Keys 02[^]*Checked out \(/.test(t) && /Van Keys 02/.test(t), "item checked out then returned shows once, as returned");
  check(/You have 6 items checked out/.test(t), "says how many items he has now");
  const log = doc.querySelector("#activity").textContent;
  check(/Alex Rivera returned Radio 01 for Jordan Lee/.test(log) && /Jordan Lee checked out Radio 01/.test(log) && /Alex Rivera checked out Vacuum 01/.test(log),
        "activity log records who checked out what and who returned for whom");
  await tap("04BA00000003", 100);
  check(/Hi, Sam/.test(text()), "a badge tap during the confirmation goes straight to the next person");
  E("endSession()"); await sleep(50);
  check(E("S.screen") === "idle", "a visit with no taps skips the confirmation");
  await tap("04BA00000003", 100); await tap("04DE000502"); E("S.session.last = Date.now() - 21000"); await sleep(700);
  check(/All set, Sam/.test(text()), "auto sign-out also shows the confirmation");
  E("S.summary.at = Date.now() - 10000"); await sleep(700);
  check(E("S.screen") === "idle", "confirmation closes itself after a few seconds");
  check(errors.length === 0, "no script errors " + errors.join(";"));
  process.exit();
})();
