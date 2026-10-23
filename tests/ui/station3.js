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
const click = async (sel, ms = 450) => { const el = doc.querySelector("#screen " + sel); if (!el) throw new Error("no element " + sel + " :: " + text().slice(0,200)); el.click(); await sleep(ms); };
const type = async (str) => { for (const ch of str) await click(`[data-k="${ch === " " ? "SPACE" : ch.toUpperCase()}"]`, 5); };
const pin = async (digits) => { for (const d of digits) await click(`[data-pin="${d}"]`, 5); await click(`[data-pin="OK"]`, 450); };
const DANA = "04BA0000000A", MORGAN = "04BA0000000B";
(async () => {
  await sleep(300);
  E("demoDevice.skip(); wizStart(); S.wiz.code='DEMO0001'"); await E("activate()"); await sleep(300); E("finishSetup()"); await sleep(100);

  await tap("04BA00000001", 100);
  check(/Hi, Alex/.test(text()) && !doc.querySelector("#staffBtn"), "regular badge: no Admin menu button");
  E("endSession()");
  await tap(DANA, 100);
  check(/Hi, Dana/.test(text()) && E("S.screen") === "session", "manager fob works like a normal badge by default");
  await tap("04DE000601", 500);
  check(/Checked out Van Keys 01/.test(text()), "Dana checks out Van Keys 01 with her fob");
  doc.querySelector("#staffBtn").click(); await sleep(100);
  check(/Manager fob/.test(text()) && /Dana Brooks/.test(text()) && /Enter your PIN/.test(text()), "Admin menu button -> PIN pad");
  await pin("1111");
  check(/Wrong PIN. 4 tries left/.test(text()), "wrong PIN -> tries left");
  await pin("2468");
  check(E("S.screen") === "staff" && /Add employee/.test(text()) && /Replace a lost badge/.test(text()) && !/unpair/i.test(text()), "right PIN -> manager menu (no admin-only items)");

  await click('[data-act="addEmp"]', 50);
  check(/First name/.test(text()) && !/Role/.test(text()), "add employee form (managers don't see Role)");
  await type("chris"); await click('[data-k="NEXT"]', 20); await type("diaz"); await click('[data-k="NEXT"]', 20); await type("e1004");
  check(/Chris/.test(text()) && /Diaz/.test(text()) && /E1004/.test(text()), "on-screen keyboard fills the fields (auto-capitalized)");
  await click('[data-act="primary"]', 50);
  check(/Tap their badge or scan its barcode/.test(text()) && /Registering Chris Diaz/.test(text()), "Next -> tap their badge or scan its barcode");
  await tap("04BA00000001");
  check(/already belongs to Alex Rivera/.test(text()), "tapping a badge in use -> says whose");
  await tap("04BA000000C1", 100);
  check(/04:BA:00:00:00:C1/.test(text()) && !!doc.querySelector('#screen [data-act="saveCapture"]'), "blank badge -> shown as captured, with Save");
  await click('[data-act="saveCapture"]', 600);
  check(/Added Chris Diaz/.test(text()) && /04:BA:00:00:00:C1/.test(text()), "Save -> Chris added");
  await click('[data-act="menu"]', 50); await click('[data-act="exit"]', 100);
  await tap("04BA000000C1", 100);
  check(/Hi, Chris/.test(text()), "Chris's new badge opens a normal session right away");
  E("endSession()"); E("endSummary && endSummary()");
  // Barcode only: someone whose badge has a barcode and no NFC chip
  await tap(DANA, 100); doc.querySelector("#staffBtn").click(); await sleep(100); await pin("2468");
  await click('[data-act="addEmp"]', 50); await type("pat"); await click('[data-act="primary"]', 50);
  E("handleTag(scanToUid('EMP-777'))"); await sleep(100); await click('[data-act="saveCapture"]', 600);
  check(/Added Pat/.test(text()) && /Barcode EMP-777 is registered/.test(text()), "barcode only -> Pat added with their badge's barcode");
  await click('[data-act="menu"]', 50); await click('[data-act="exit"]', 100);
  E("handleTag(scanToUid('EMP-777'))"); await sleep(150);
  check(/Hi, Pat/.test(text()), "scanning Pat's badge barcode starts their session");
  E("endSession()"); E("endSummary && endSummary()");

  await tap(DANA, 100); doc.querySelector("#staffBtn").click(); await sleep(100); await pin("2468");
  await click('[data-act="addEq"]', 50);
  await click('[data-pick^="cat:c5"]', 50);
  check(/Radio 03/.test(text()), "pick Radio -> name suggested as the next number (Radio 03)");
  await click('[data-act="primary"]', 50);
  check(/Tap its tag or scan its barcode/.test(text()), "Next -> tap its tag or scan its barcode");
  await tap("04DE00000503", 100); await click('[data-act="saveCapture"]', 600);
  check(/Added Radio 03/.test(text()), "new tag -> Radio 03 added");
  await click('[data-act="addEqAgain"]', 50);
  check(/Radio 04/.test(text()), "Add another -> keeps the category, suggests Radio 04");
  // Both: an NFC tag and the barcode already printed on it, in either order. Saves on its own once it has both.
  await click('[data-act="primary"]', 50);
  E("handleTag(scanToUid('RAD-0004'))"); await sleep(100);
  check(/RAD-0004/.test(text()) && /Add the other one too/.test(text()), "scan a barcode -> captured, NFC tag still open");
  E("handleTag(scanToUid('PAS-10021'))"); await sleep(100);
  check(/already belongs to Headset 01/.test(text()), "a barcode that's already on something -> says what");
  await tap("04DE00000504", 600);
  const r4 = E("JSON.stringify((() => { const q = demo.db.equipment.find(x => x.name === 'Radio 04'); return q && [q.nfc_uid, q.barcode]; })())");
  check(/Added Radio 04/.test(text()) && r4 === JSON.stringify(["04DE00000504", "RAD-0004"]), "tag + barcode -> Radio 04 saved with both " + r4);
  await click('[data-act="menu"]', 50);

  await click('[data-act="item"]', 50); await tap("04DE000101", 500);
  check(/Vacuum 01/.test(text()) && /AVAILABLE/.test(text()) && /Mark lost/.test(text()) && !/Retire/.test(text()), "Equipment status: tap an item -> its status + actions (no Retire for managers)");
  await click('[data-act="setStatus"][data-status="maintenance"]', 500);
  check(/in maintenance and can't be checked out/.test(text()) && /IN MAINTENANCE/.test(text()), "send to maintenance");
  await click('[data-act="setStatus"][data-status="available"]', 500);
  check(/back in service/.test(text()), "back in service");
  await click('[data-act="replaceTag"]', 50); await tap("04DE0000F101", 600);
  check(/New tag on Vacuum 01/.test(text()), "give an item a new tag");

  await click('[data-act="menu"]', 50); await click('[data-act="people"]', 50);
  const chrisId = E("demo.db.employees.find(e=>e.name==='Chris Diaz').id");
  await click(`[data-pick="person:${chrisId}"]`, 50);
  check(/Chris Diaz/.test(text()) && /Replace lost badge/.test(text()) && !/Deactivate/.test(text()), "manager: employee page shows Replace badge only");
  await click('[data-act="replaceBadge"]', 50); await tap("04BA000000C9", 600);
  check(/New badge for Chris Diaz/.test(text()), "replace Chris's lost badge");
  const morganId = E("demo.db.employees.find(e=>e.name==='Morgan Reyes').id");
  await click('[data-act="menu"]', 50); await click('[data-act="people"]', 50); await click(`[data-pick="person:${morganId}"]`, 50);
  check(doc.querySelector('#screen [data-act="replaceBadge"]').disabled, "manager can't re-badge an admin (button disabled)");
  await click('[data-act="exit"]', 100);

  await tap(MORGAN, 100); doc.querySelector("#staffBtn").click(); await sleep(100); await pin("1357");
  check(/Admin/.test(text()) && /Roles, PINs/.test(text()), "admin fob -> admin menu");
  await click('[data-act="people"]', 50); await click(`[data-pick="person:${chrisId}"]`, 50);
  await click('[data-pick="setrole:manager"]', 50);
  check(/Give Chris Diaz's fob a PIN/.test(text()) && /New PIN/.test(text()), "promote to manager asks for a PIN first");
  for (const d of "8642") await click(`[data-k="${d}"]`, 5);
  await click('[data-act="primary"]', 600);
  check(/Chris Diaz is now a manager/.test(text()), "Chris is now a manager");
  await click('[data-act="toggleActive"]', 600);
  check(/deactivated/.test(text()) && /INACTIVE/.test(text()), "admin deactivates Chris");
  await click('[data-act="menu"]', 50); await click('[data-act="station"]', 50);
  check(/Unpair/.test(text()), "admin's station menu includes Unpair");
  E("S.overlay=null; renderLayer()");
  await click('[data-act="exit"]', 100);
  await tap("04BA000000C9", 100);
  check(!/Hi, Chris/.test(text()), "deactivated badge no longer works");

  const log = doc.querySelector("#activity").textContent;
  check(/Dana Brooks added employee Chris Diaz/.test(log) && /Dana Brooks added equipment Radio 03/.test(log)
        && /Morgan Reyes made Chris Diaz a manager/.test(log) && /Morgan Reyes deactivated Chris Diaz/.test(log), "activity log records every staff action with whose fob");

  await tap(DANA, 100); doc.querySelector("#staffBtn").click(); await sleep(100); for (let i = 0; i < 5; i++) await pin("9999");
  check(/Fob locked/.test(text()), "5 wrong PINs lock the fob");
  check(errors.length === 0, "no script errors " + errors.join(";"));
  process.exit();
})();
