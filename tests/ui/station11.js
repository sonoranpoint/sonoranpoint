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
  check(/United BW's Vacuum 02/.test(text()) && /unless they lend it to you/.test(text()), "United BW gear can't be checked out here, and it says whose it is");
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
  check(/United BW's Vacuum 02/.test(text()), "offline: United BW gear still can't be checked out");
  E("endSession(); endSummary(); demo.wifi = true"); await sleep(50);

  // Above wing shares, and items move to where they're returned
  E("demo.db.stations[0].contract_id = 'uaw'; demo.save()"); await E("refreshData(true)"); await sleep(400);
  await tap(SAM); await tap("04DE000501", 600);
  check(/Checked out Radio 01/.test(text()), "above wing shares: Delta AW checks out Delta AW gear at a United AW station");
  await tap("04DE000501", 600);
  check(/Returned Radio 01/.test(text()) && /now belongs to United AW/.test(text()) && E("demo.db.equipment.find(x => x.name === 'Radio 01').contract_id") === "uaw",
        "returned at the United AW station: it moves there, and the station says so");
  E("endSession(); endSummary()");
  // Tapped on its own at a Delta BW station: says whose it is
  E("demo.db.stations[0].contract_id = 'dbw'; demo.save()"); await E("refreshData(true)"); await sleep(400);
  await tap("04DE000102", 600);
  check(/Belongs to United BW/.test(text()) && /Can't be checked out here/.test(text()), "tapped on its own: says it belongs to United BW");
  E("endLookup()");

  // Loans: a United BW manager lends Vacuum 02 to Delta BW at a United BW station
  E("demo.db.stations[0].contract_id = 'ubw'; demo.save()"); await E("refreshData(true)"); await sleep(400);
  await tap(DANA, 200); await click("#staffBtn", 100); await pin("2468");
  await click('[data-act="item"]', 100); await tap("04DE000102", 600);
  check(/Belongs to United BW/.test(text()) && doc.querySelector('#screen [data-act="lend"]'), "admin menu: the item says whose it is, with Lend");
  await click('[data-act="lend"]');
  check(/Lend Vacuum 02 to/.test(text()) && /Delta BW/.test(text()) && !/United BW<\/b>/.test(doc.querySelector("#screen .people").innerHTML), "pick who to lend it to");
  await click('[data-pick="lend:dbw"]', 600);
  check(/on loan to Delta BW/.test(text()) && E("demo.loanOf(demo.db.equipment.find(q => q.name === 'Vacuum 02').id).to") === "dbw", "lent");
  E("exitStaff()"); await sleep(300);
  // Delta BW can take it
  E("demo.db.stations[0].contract_id = 'dbw'; demo.save()"); await E("refreshData(true)"); await sleep(400);
  await tap(ALEX); await tap("04DE000102", 600);
  check(/Checked out Vacuum 02/.test(text()) && /On loan from United BW/.test(text()), "Delta BW checks out the loaned item");
  check(E("demo.db.txns.at(-1).flags.includes('on_loan')"), "the checkout is marked on loan");
  await tap("04DE000102", 600); E("endSession(); endSummary()");
  // Back at a United BW station: the loan ends
  E("demo.db.stations[0].contract_id = 'ubw'; demo.save()"); await E("refreshData(true)"); await sleep(400);
  await tap(JORDAN); await tap("04DE000102", 600);
  check(/Back from loan Vacuum 02/.test(text()) && /Delta BW had it on loan/.test(text()) && !E("demo.loanOf(demo.db.equipment.find(q => q.name === 'Vacuum 02').id)"), "tapped back at United BW: the loan is over");
  await tap("04DE000102", 600);
  check(/Checked out Vacuum 02/.test(text()), "and the next tap checks it out as normal");
  E("endSession(); endSummary()");
  // Colors: the top bar follows the logos, and the main color always shows on the screen
  const css = (k) => doc.documentElement.style.getPropertyValue(k).trim().toLowerCase();
  E("Object.assign(S.saved.config.organization, { primary_color: '#FFFFFF', logo_url: 'data:image/png;base64,AAA', logo_dark_url: null }); applyBrand(); renderTop()");
  check(css("--bar") === "#ffffff" && doc.querySelector("#logo img")?.getAttribute("src") === "data:image/png;base64,AAA", "normal logo only: white top bar with it");
  check(E(`contrast("${css("--brand")}", "#f7f8fa")`) >= 3, "a white main color is darkened so the rings and icon still show (" + css("--brand") + ")");
  E("Object.assign(S.saved.config.organization, { primary_color: '#000000', logo_dark_url: 'data:image/png;base64,BBB' }); applyBrand(); renderTop()");
  check(css("--bar") === "#000000" && doc.querySelector("#logo img")?.getAttribute("src") === "data:image/png;base64,BBB" && css("--bar-ink") === "#ffffff", "with a light logo: main color top bar with the light logo");
  E("Object.assign(S.saved.config.organization, { primary_color: '#FBFAFF' }); applyBrand(); renderTop()");
  check(css("--bar") === "#fbfaff" && doc.querySelector("#logo img")?.getAttribute("src") === "data:image/png;base64,AAA", "light main color with both logos: the normal logo, since the light one wouldn't show");
  E("Object.assign(S.saved.config.organization, { primary_color: '#1F4E79', logo_url: 'data:image/png;base64,AAA', logo_dark_url: null }); applyBrand(); renderTop()");
  check(css("--bar") === "#ffffff", "dark main color, normal logo only: white bar");
  E("Object.assign(S.saved.config.organization, { primary_color: '#1F4E79', logo_url: null, logo_dark_url: null }); applyBrand(); renderTop()");
  check(css("--bar") === "#1f4e79" && css("--brand") === "#1f4e79" && /Demo Air Services/.test(doc.querySelector("#logo").textContent), "no logo: main color bar with their name; a dark main color is used as is");
  // Barcode scanners: a scan works like a tap, for badges and items (with or without an NFC tag)
  E("S.saved.config.station.contract = null; demo.db.stations[0].contract_id = null; demo.db.employees.forEach(e => e.contract_id = null); demo.db.equipment.forEach(q => q.contract_id = null)");
  await E("refreshData(true)"); await sleep(300);
  const type = async (str) => { for (const ch of str) doc.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: ch, bubbles: true })); doc.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true })); await sleep(450); };
  check(E("scanToUid('000102')") === "04BA00000002" && E("scanToUid('pas-10021')") === E("barcodeUid('PAS-10021')") && E("scanToUid('04:BA:00:00:00:01')") === "04BA00000001",
        "a scanned code is matched to the badge or item it belongs to (NFC readers that type still work)");
  await type("000102");
  check(/Jordan/.test(text()), "scanning a badge's barcode signs that person in");
  await type("PAS-10021");
  check(/Headset 01/.test(text()) && E("demo.db.equipment.find(q => q.name === 'Headset 01').current_employee_id") === "e2", "scanning an item's barcode checks it out (an item with only a barcode)");
  E("endSession(); endSummary(); S.check = null; S.screen = 'idle'; render()"); await sleep(50);
  // Self-updates: switch to a waiting version only when nobody's using the station
  E(`window.__upd = []; updater.enabled = true; updater.reload = () => window.__upd.push("reload");
     window.fetch = async (url, o) => { window.__upd.push((o?.method || "GET") + " " + url); return { json: async () => url === "/update/status" ? { current: VERSION, staged: "station-9.9.9+abc" } : { ok: true } }; };`);
  E("S.screen = 'session'; S.session = { emp: { name: 'Test' } }");
  await E("updater.tick()");
  check(!E("window.__upd.length"), "no update while someone is using the station");
  E("S.session = null; S.screen = 'idle'; S.overlay = null; render()"); await sleep(50);
  await E("updater.tick()");
  check(E("window.__upd.join('|')") === "GET /update/status|POST /update/apply|reload", "idle: applies the waiting version and reloads", );
  E("updater.enabled = false; document.querySelector('.updating')?.remove()");
  check(errors.length === 0, "no script errors " + errors.join(";"));
  process.exit();
})();
