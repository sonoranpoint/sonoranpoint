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
const tap = async (uid, ms = 450) => { E(`handleTag('${uid}')`); await sleep(ms); };
const pin = async (digits) => { for (const d of digits) await click(`[data-pin="${d}"]`, 5); await click(`[data-pin="OK"]`, 450); };
const ALEX = "04BA00000001", JORDAN = "04BA00000002", DANA = "04BA0000000A", VAC1 = "04DE000101", RADIO1 = "04DE000501";
(async () => {
  await sleep(300);
  E("demoDevice.skip(); wizStart(); S.wiz.code='DEMO0001'"); await E("activate()"); await sleep(300); E("finishSetup()"); await sleep(300);
  check(E("reasons().map(r => r.label).join(',')") === "Damaged,Not charging,Missing part,Other", "the station has the company's problem reasons");

  // Alex checks out Vacuum 01, then reports it damaged by touching it in his list
  await tap(ALEX); await tap(VAC1, 600);
  check(/Report a problem/.test(text()), "a session has a Report a problem button");
  await click("#reportBtn");
  check(/Tap the item now/.test(text()) && doc.querySelector('#screen li.pick[data-rep]'), "report: asks for the item; his own items can be touched");
  await click("li.pick[data-rep]");
  check(/What's wrong with Vacuum 01/.test(text()) && doc.querySelectorAll("#screen .rbtn").length === 4 && /Stops checkout until fixed/.test(text()), "then what's wrong, with the reasons as big buttons");
  await click('.rbtn[data-reason="r1"]', 500);
  check(/Problem reported Vacuum 01/.test(text()) && /Damaged\. A supervisor will take a look/.test(text()) && /Tap it again to return it/.test(text()), "reported; he's told he can still return it");
  check(E("demo.db.problems.length") === 1 && E("demo.db.problems[0].reported_by_employee") === "e1", "the report reaches the server with who made it");
  check(/This visit: .*1 reported/.test(text()), "the visit tally counts it");
  await tap(VAC1, 600);
  check(/Returned Vacuum 01/.test(text()) && /stays in the room until a supervisor clears it/.test(text()), "a damaged item can be returned; it stays in the room");
  E("endSession()"); await sleep(50);

  // Jordan can't take it
  await tap(JORDAN); await tap(VAC1, 600);
  check(/Can't check out Vacuum 01/.test(text()) && /Reported: Damaged/.test(text()) && /supervisor has to clear it/.test(text()), "a damaged item can't be checked out");
  E("endSession()"); await sleep(50);
  await tap(VAC1, 600);
  check(/can't be used right now/.test(text()) && /Reported: Damaged/.test(text()) && /Can't be checked out/.test(text()), "tapping it without a badge shows the problem");
  E("endLookup()");

  // Report by tapping the tag, while offline
  E("demo.wifi = false");
  await tap(JORDAN, 200); await click("#reportBtn"); await tap(RADIO1, 300);
  check(/What's wrong with Radio 01/.test(text()), "report: tapping the tag picks the item");
  await click('.rbtn[data-reason="r2"]', 400);
  check(/Not charging\. A supervisor will take a look/.test(text()) && /Saved on this station/.test(text()), "offline: the report is saved on the station");
  check(E("S.saved.queue.length") === 1 && E("S.saved.queue[0].fn") === "station_report_problem", "it waits in the same queue as saved taps");
  await tap(RADIO1, 600);
  check(/Checked out Radio 01/.test(text()), "\"Not charging\" doesn't stop checkout");
  E("endSession()");
  E("demo.wifi = true; flush()"); await sleep(2500);
  check(E("S.saved.queue.length") === 0 && E("demo.db.problems.length") === 2 && E("demo.db.problems[1].reason") === "Not charging", "back online -> the report syncs");

  // Dana clears it from the admin menu
  await tap(DANA, 200); await click("#staffBtn", 100); await pin("2468");
  await click('[data-act="item"]', 100); await tap(VAC1, 600);
  check(/Reported: Damaged/.test(text()) && doc.querySelector('#screen [data-act="clearProblem"]'), "admin menu: the item shows its problem and a clear button");
  await click('[data-act="clearProblem"]', 600);
  check(/cleared and can be checked out again/.test(text()) && !!E("demo.db.problems[0].cleared_at"), "a manager clears it");
  E("exitStaff()"); await sleep(1500);
  await tap(JORDAN); await tap(VAC1, 600);
  check(/Checked out Vacuum 01/.test(text()), "cleared -> it can be checked out again");
  check(errors.length === 0, "no script errors " + errors.join(";"));
  process.exit();
})();
