const { JSDOM } = require("jsdom");
const fs = require("fs");
const html = "<!doctype html><html><head><meta charset=utf-8></head><body>" + fs.readFileSync(process.argv[2], "utf8") + "</body></html>";
const errors = [];
const dom = new JSDOM(html, { runScripts: "dangerously", pretendToBeVisual: true, url: "https://example.test/",
  beforeParse(w) { w.crypto.randomUUID ??= () => require("crypto").randomUUID(); } });
dom.window.addEventListener("error", (e) => errors.push(e.message));
const E = (s) => dom.window.eval(s);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const text = () => dom.window.document.querySelector("#screen").textContent.replace(/\s+/g, " ").trim();
const check = (c, m) => { console.log((c ? "pass  " : "FAIL  ") + m + (c ? "" : "\n      screen: " + text().slice(0, 300))); if (!c) process.exitCode = 1; };
const tap = async (uid, ms = 500) => { E(`handleTag('${uid}')`); await sleep(ms); };
const toggle = (id, v) => E(`(()=>{const el=document.querySelector('${id}'); el.checked=${v}; el.dispatchEvent(new Event('change'));})()`);
const ALEX = "04BA00000001", JORDAN = "04BA00000002", SAM = "04BA00000003";
(async () => {
  await sleep(300);
  E("demoDevice.skip(); wizStart(); S.wiz.code='DEMO0001'"); await E("activate()"); await sleep(300); E("finishSetup()"); await sleep(100);
  E(`document.querySelector('#timeSel').value='09:00'; document.querySelector('#timeSel').dispatchEvent(new Event('change'))`);
  check(E("S.screen") === "idle", "station activated");
  { const d = dom.window.document; check(d.querySelector("#logo.sp img")?.getAttribute("src") === "brand/mark-180.png" && /Demo Air Services/.test(d.querySelector("#logo").textContent) && /Equipment Room 01/.test(d.querySelector("#status").textContent) && !/synced/i.test(d.querySelector("#status").textContent), "no company logo -> our icon + their name at the top; station name at the bottom, no sync line"); }
  E("S.saved.config.organization.logo_url = 'https://example.test/acme.png'; render()"); await sleep(20);
  { const d = dom.window.document; check(d.querySelector("#logo:not(.sp) img")?.getAttribute("src") === "https://example.test/acme.png" && !/Demo Air Services/.test(d.querySelector("#logo").textContent) && /mark-180/.test(d.querySelector("#logo img").getAttribute("onerror")), "company logo alone at the top (no name), falls back to ours if it won't load"); }
  E("S.saved.config.organization.logo_url = null; render()");

  await tap("04DE000501");
  check(/Radio 01/.test(text()) && /AVAILABLE/.test(text()) && /Tap your badge to check it out/.test(text()), "tap Radio 01 with no badge -> AVAILABLE, prompts for a badge");
  await tap(ALEX, 700);
  check(/Hi, Alex/.test(text()) && /Checked out Radio 01/.test(text()) && /1:30 PM/.test(text()), "badge right after -> Radio 01 checked out to Alex, due 1:30 PM");
  E("endSession()");

  await tap("04DE000501");
  check(/CHECKED OUT/.test(text()) && /Alex Rivera has it/.test(text()) && /Due 1:30 PM/.test(text()), "tap it again with no badge -> CHECKED OUT, Alex Rivera has it, due 1:30");
  check(/Returning it\? Tap your badge/.test(text()), "offers to return it with a badge");
  E("document.querySelector('#lkCancel').click()"); await sleep(50);
  check(E("S.screen") === "idle", "Cancel goes back to the start screen");

  await tap(JORDAN, 100); await tap("04DE000501");
  check(/Returned Radio 01/.test(text()) && /Returned for Alex Rivera/.test(text()), "Jordan taps Alex's radio -> returned for Alex");
  await tap("04DE000501");
  check(/Checked out Radio 01/.test(text()), "Jordan taps again -> checked out to Jordan");
  E("endSession()");

  toggle("#ruleReturn", false); await sleep(500);
  await tap(ALEX, 100); await tap("04DE000501");
  check(/Can't check out Radio 01/.test(text()) && /Checked out to Jordan Lee/.test(text()) && /has to be returned/.test(text()),
        "returning for others turned off -> Alex is refused: checked out to Jordan, must be returned first");
  E("endSession()"); toggle("#ruleReturn", true); await sleep(500);

  E(`document.querySelector('#supItem').value='q52'; document.querySelector('[data-status=lost]').click()`); await sleep(50);
  await tap("04DE000502");
  check(/LOST/.test(text()) && /Found it\? Tap your badge/.test(text()), "supervisor marks Radio 02 lost -> tapping it shows LOST, found it? tap badge");
  await tap(SAM, 700);
  check(/Found Radio 02/.test(text()) && /listed as lost/.test(text()), "Sam badges -> Radio 02 returned as found");
  check(E("demo.db.equipment.find(q=>q.id==='q52').status") === "available", "server shows Radio 02 available again");
  E("endSession()");

  E(`document.querySelector('#supItem').value='q12'; document.querySelector('[data-status=maintenance]').click()`); await sleep(50);
  await tap("04DE000102");
  check(/IN MAINTENANCE/.test(text()) && /Can't be checked out/.test(text()), "item in maintenance -> lookup says it can't be checked out");
  await tap(ALEX, 400);
  check(/Hi, Alex/.test(text()) && !/Checked out Vacuum 02/.test(text()), "badging after a maintenance lookup just opens the session");
  await tap("04DE000102");
  check(/Can't check out Vacuum 02/.test(text()) && /maintenance/.test(text()), "tapping it in the session -> refused, in maintenance");
  E("endSession()");

  toggle("#wifi", false);
  await tap(SAM, 100); await tap("04DE000101", 600);
  check(/Checked out Vacuum 01/.test(text()) && /Saved on this station/.test(text()), "offline: Sam checks out Vacuum 01, saved on the station");
  await tap("04DE000501", 600);
  check(/Returned Radio 01/.test(text()) && /Returned for Jordan Lee/.test(text()), "offline: same rules apply (Sam returns Jordan's radio)");
  E("endSession()");
  await tap("04DE000101", 300);
  check(/Sam Patel has it/.test(text()) && /Offline: showing the last synced status/.test(text()), "offline lookup shows the station's own latest info");
  E("endLookup()");
  toggle("#wifi", true); await sleep(2000);
  check(E("S.saved.queue.length") === 0 && E("demo.db.equipment.find(q=>q.id==='q11').current_employee_id") === "e3"
        && E("demo.db.equipment.find(q=>q.id==='q51').current_employee_id") === null, "back online -> both saved taps sync to the server");
  check(errors.length === 0, "no script errors " + errors.join(";"));
  process.exit();
})();
