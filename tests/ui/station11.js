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
const ALEX = "04BA00000001", JORDAN = "04BA00000002", SAM = "04BA00000003", DANA = "04BA0000000A";
(async () => {
  await sleep(300);
  E("demoDevice.skip(); wizStart(); S.wiz.code='DEMO0001'"); await E("activate()"); await sleep(300); E("finishSetup()"); await sleep(300);
  // BW (no sharing): Delta BW, United BW.  AW (sharing, items move on return): Delta AW, United AW.  This station: Delta BW.
  E(`const C = demo.db.contracts; C.push({ id: 'bw', parent_id: null, name: 'BW' }, { id: 'aw', parent_id: null, name: 'AW', share_children: true, move_on_return: true },
      { id: 'dbw', parent_id: 'bw', name: 'Delta BW' }, { id: 'ubw', parent_id: 'bw', name: 'United BW' }, { id: 'daw', parent_id: 'aw', name: 'Delta AW' }, { id: 'uaw', parent_id: 'aw', name: 'United AW' });
     demo.db.stations[0].contract_id = 'dbw';
     const emp = (n) => demo.db.employees.find(e => e.badge_uid === n);
     emp('${ALEX}').contract_id = 'dbw'; emp('${JORDAN}').contract_id = 'ubw'; emp('${SAM}').contract_id = 'daw';
     const q = (n) => demo.db.equipment.find(x => x.name === n);
     q('Vacuum 01').contract_id = 'dbw'; q('Vacuum 02').contract_id = 'ubw'; q('Radio 01').contract_id = 'daw';
     demo.save()`);
  await E("refreshData(true)"); await sleep(400);
  check(E("stationContract()") === "Delta BW" && JSON.stringify(E("S.saved.cache.reach").slice().sort()) === JSON.stringify(["bw", "dbw"]), "the station knows its contract and who it serves");

  await tap(ALEX); await tap("04DE000101", 600);
  check(/Checked out Vacuum 01/.test(text()), "Delta BW crew checks out Delta BW gear");
  await tap("04DE000102", 600);
  check(/Can't check out Vacuum 02/.test(text()) && /belongs to United BW/.test(text()), "United BW gear can't be checked out here");
  E("endSession(); endSummary()"); await sleep(50);
  await tap(JORDAN, 300);
  check(/Not your station/.test(text()) && /This station is for Delta BW/.test(text()) && !E("S.session"), "a United BW badge is turned away");
  await tap(SAM, 300);
  check(/Not your station/.test(text()), "so is above wing (BW and AW don't share)");
  await tap(DANA, 300);
  check(E("S.session && S.session.emp.name") === "Dana Brooks", "someone with no contract (the admin office) works everywhere");
  E("endSession(); endSummary()"); await sleep(50);

  // Offline: same rules from the station's own lists
  E("demo.wifi = false");
  await tap(JORDAN, 200);
  check(/Not your station/.test(text()), "offline: a United BW badge is still turned away");
  await tap(ALEX, 200); await tap("04DE000102", 300);
  check(/Can't check out Vacuum 02/.test(text()), "offline: United BW gear still can't be checked out");
  E("endSession(); endSummary(); demo.wifi = true"); await sleep(50);

  // Above wing shares, and items move to where they're returned
  E("demo.db.stations[0].contract_id = 'uaw'; demo.save()"); await E("refreshData(true)"); await sleep(400);
  await tap(SAM); await tap("04DE000501", 600);
  check(/Checked out Radio 01/.test(text()), "above wing shares: Delta AW checks out Delta AW gear at a United AW station");
  await tap("04DE000501", 600);
  check(/Returned Radio 01/.test(text()) && /now belongs to United AW/.test(text()) && E("demo.db.equipment.find(x => x.name === 'Radio 01').contract_id") === "uaw",
        "returned at the United AW station: it moves there, and the station says so");
  E("endSession(); endSummary()");
  check(errors.length === 0, "no script errors " + errors.join(";"));
  process.exit();
})();
