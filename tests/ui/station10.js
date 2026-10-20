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
const ALEX = "04BA00000001", JORDAN = "04BA00000002", DANA = "04BA0000000A", VAC1 = "04DE000101", RADIO1 = "04DE000501", BAT1 = "04DE000301";
const done = async () => { await click("#doneBtn", 100); };
(async () => {
  await sleep(300);
  E("demoDevice.skip(); wizStart(); S.wiz.code='DEMO0001'"); await E("activate()"); await sleep(300); E("finishSetup()"); await sleep(300);
  check(E("reasons().map(r => r.label + (r.blocks_checkout ? '*' : '')).join(',')") === "Damaged,Not charging,Missing part,Other", "the station has the company's reasons; none stops checkout to start");

  // Mid-visit report: Alex takes Vacuum 01 and Radio 01, reports the vacuum damaged by touching it
  await tap(ALEX); await tap(VAC1, 500); await tap(RADIO1, 500);
  await click("#reportBtn");
  check(/Tap the item now/.test(text()) && doc.querySelectorAll('#screen li.pick[data-rep]').length === 2, "Report a problem: tap the item, or touch one of yours");
  await click("li.pick[data-rep]");
  check(/What's wrong with Vacuum 01/.test(text()) && doc.querySelectorAll("#screen .rbtn").length === 4, "then pick what's wrong");
  await click('.rbtn[data-reason="r1"]', 500);
  check(/Problem reported Vacuum 01/.test(text()) && /Damaged\. A supervisor will take a look/.test(text()), "reported");
  check(E("demo.db.problems.length") === 1 && E("demo.db.problems[0].reported_by_employee") === "e1", "the report reaches the server with who made it");
  await done();
  check(/All set, Alex/.test(text()) && !/Any problems/.test(text()), "a visit with no returns goes straight to the summary");
  E("endSummary()");

  // Returns -> "Any problems?" -> Yes -> pick a reason per item
  await tap(ALEX); await tap(VAC1, 500); await tap(RADIO1, 500);
  await done();
  check(/Any problems with what you returned\?/.test(text()) && /Vacuum 01, Radio 01/.test(text()), "after returning, the station asks if anything's wrong");
  await click("#ckYes");
  check(doc.querySelectorAll("#screen .ck-row").length === 2 && doc.querySelector("#ckSend").disabled, "Yes -> each returned item with the reasons to pick from");
  await click('.ckchip[data-ck-item="q51"][data-ck-reason="r2"]'); await click('.ckchip[data-ck-item="q11"][data-ck-reason="r3"]');
  check(/Report 2 items/.test(text()), "pick a reason for each item with a problem");
  await click('.ckchip[data-ck-item="q11"][data-ck-reason="r3"]');
  check(/Report 1 item/.test(text()), "tapping a reason again unpicks it");
  await click('.ckchip[data-ck-item="q11"][data-ck-reason="r3"]');
  await click("#ckSend", 800);
  check(doc.querySelector("#screen .summary.good") && /Checked in, Alex/.test(text()) && /Problems reported \(2\)/.test(text()) && /Not charging/.test(text()), "sent -> green Checked in screen listing what was reported");
  check(E("demo.db.problems.filter(p => p.reported_by_employee === 'e1' && p.reason !== 'Damaged').map(p => p.reason).sort().join(',')") === "Missing part,Not charging", "both reports reach the server");
  E("endSummary()");

  // Damaged doesn't block: Jordan can take it, with a heads-up, and the checkout is flagged
  await tap(JORDAN); await tap(VAC1, 600);
  check(/Checked out Vacuum 01/.test(text()) && /Reported: (Damaged|Missing part)\. Look it over before you use it/.test(text()), "a damaged item can be checked out, with a heads-up");
  check(E("demo.db.txns.at(-1).flags.includes('reported_problem')"), "and the checkout is flagged for supervisors");

  await tap(VAC1, 500); await done(); await click("#ckNo"); E("endSummary()");
  // No -> green screen; no answer -> same
  await tap(ALEX); await tap(BAT1, 500); await tap(BAT1, 500); await done();
  await click("#ckNo");
  check(doc.querySelector("#screen .summary.good") && /Checked in, Alex/.test(text()), "No -> green Checked in screen");
  E("endSummary()");
  await tap(ALEX); await tap(BAT1, 500); await tap(BAT1, 500); await done();
  E("S.check.at = Date.now() - CHECK_MS"); await sleep(700);
  check(doc.querySelector("#screen .summary.good"), "no answer counts as no");
  E("endSummary()");

  // A reason set to stop checkout still blocks; offline report; manager clears it
  E("demo.db.reasons.push({ id: 'r9', label: 'Unsafe', blocks_checkout: true, sort: 9 }); demo.save()"); await E("refreshData(true)"); await sleep(400);
  E("demo.wifi = false");
  await tap(JORDAN, 200); await click("#reportBtn"); await tap(BAT1, 300);
  await click('.rbtn[data-reason="r9"]', 400);
  check(/Unsafe\. A supervisor will take a look/.test(text()) && /Saved on this station/.test(text()) && E("S.saved.queue[0].fn") === "station_report_problem", "offline: the report is saved on the station");
  await tap(BAT1, 500);
  check(/Can't check out Battery 01/.test(text()) && /Reported: Unsafe/.test(text()), "a reason that stops checkout blocks it, offline too");
  await done(); E("demo.wifi = true; flush()"); await sleep(2500);
  check(E("S.saved.queue.length") === 0 && E("demo.db.problems.some(p => p.reason === 'Unsafe' && !p.cleared_at)"), "back online -> the report syncs");
  await tap(BAT1, 600);
  check(/can't be used right now/.test(text()) && /Reported: Unsafe/.test(text()), "tapping it without a badge shows the problem");
  E("endLookup()");
  await tap(DANA, 200); await click("#staffBtn", 100); await pin("2468");
  await click('[data-act="item"]', 100); await tap(BAT1, 600);
  check(/Reported: Unsafe/.test(text()) && doc.querySelector('#screen [data-act="clearProblem"]'), "admin menu: the item shows its problem and a clear button");
  await click('[data-act="clearProblem"]', 600);
  check(/cleared and can be checked out again/.test(text()), "a manager clears it");
  E("exitStaff()"); await sleep(1500);
  await tap(JORDAN); await tap(BAT1, 600);
  check(/Checked out Battery 01/.test(text()) && !/Reported:/.test(text()), "cleared -> checked out with no heads-up");
  check(errors.length === 0, "no script errors " + errors.join(";"));
  process.exit();
})();
