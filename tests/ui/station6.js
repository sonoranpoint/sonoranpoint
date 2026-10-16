// Guided setup: help, reader hint, get-started checklist (add people/equipment from setup), tour, resume after power cut.
const { JSDOM } = require("jsdom");
const fs = require("fs");
const src = fs.readFileSync(process.argv[2], "utf8");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let errors = [];
const check = (c, m, t) => { console.log((c ? "pass  " : "FAIL  ") + m + (c ? "" : "\n      " + (t || ""))); if (!c) process.exitCode = 1; };
function boot(storage) {
  const dom = new JSDOM("<!doctype html><html><body>" + src + "</body></html>", { runScripts: "dangerously", pretendToBeVisual: true, url: "https://example.test/",
    beforeParse(w) { w.crypto.randomUUID ??= () => require("crypto").randomUUID(); for (const [k, v] of Object.entries(storage || {})) w.localStorage.setItem(k, v); } });
  dom.window.addEventListener("error", (e) => errors.push(e.message));
  return dom;
}
(async () => {
  let dom = boot(); await sleep(400);
  let E = (s) => dom.window.eval(s), doc = dom.window.document, text = () => doc.querySelector("#screen").textContent.replace(/\s+/g, " ");
  const click = async (sel, ms = 60) => { const el = doc.querySelector("#screen " + sel); if (!el) throw new Error("no element " + sel + " :: " + text().slice(0, 250)); el.click(); await sleep(ms); };
  await click('[data-w="help"]');
  check(/Need help\?/.test(text()) && /4 short steps/.test(text()) && /support@sonoranpoint.com/.test(text()), "Need help? shows tips for this step + support contact");
  await click('[data-a="close"]'); await click('[data-w="start"]', 900);
  await click('[data-w="help"]');
  check(/not a guest network/.test(text()) && /case-sensitive/.test(text()), "help on the Wi-Fi step is about Wi-Fi");
  await click('[data-a="close"]'); await click('[data-w="skip"]');
  for (const c of "DEMO0001") await click(`[data-ck="${c}"]`, 5);
  await click('[data-w="activate"]', 700);
  check(/Tap the admin tag/.test(text()) && !/Nothing happening/.test(text()), "admin tag step");
  E("S.wiz.adminAt = Date.now() - 25000"); await sleep(700);
  check(/Nothing happening\? Hold the tag flat/.test(text()), "no tag after 20s -> tip on how to hold it to the reader");

  // Power cut here: reboot with the same storage
  const saved = {}; for (let i = 0; i < dom.window.localStorage.length; i++) { const k = dom.window.localStorage.key(i); saved[k] = dom.window.localStorage.getItem(k); }
  dom.window.close(); dom = boot(saved); await sleep(400);
  E = (s) => dom.window.eval(s); doc = dom.window.document; text = () => doc.querySelector("#screen").textContent.replace(/\s+/g, " ");
  const click2 = async (sel, ms = 60) => { const el = doc.querySelector("#screen " + sel); if (!el) throw new Error("no element " + sel + " :: " + text().slice(0, 250)); el.click(); await sleep(ms); };
  check(/Tap the admin tag/.test(text()) && /Demo Air Services/.test(text()), "unplugged mid-setup -> comes back on the admin tag step, still branded");

  E("handleTag('04BA0000AD01')"); await sleep(500);
  for (const c of "SAM") await click2(`[data-wk="${c}"]`, 5); await click2('[data-wk="NEXT"]', 5); await click2('[data-wk="NEXT"]', 5);
  for (const c of "7391") await click2(`[data-wk="${c}"]`, 5); await click2('[data-wk="NEXT"]', 5);
  for (const c of "7391") await click2(`[data-wk="${c}"]`, 5); await click2('[data-w="saveAdmin"]', 700);
  check(/Let's get your team set up/.test(text()) && /Add your employees/.test(text()) && /See how checkout works/.test(text()), "Get started checklist");

  await click2('[data-w="qsEmp"]', 700);
  check(E("S.screen") === "staff" && /First name/.test(text()) && /Back to setup/.test(text()), "Add your employees -> opens the add-employee form directly (no PIN again)");
  for (const c of "TAYLOR") await click2(`[data-k="${c}"]`, 5);
  await click2('[data-act="primary"]', 60); E("handleTag('04BA0000C7C7')"); await sleep(700);
  check(/Added Taylor/.test(text()), "employee added from setup");
  await click2('[data-act="exit"]', 100);
  check(/1 added/.test(text()) && doc.querySelector("#screen .qs-row.did"), "Back to setup -> checklist shows 1 employee added, ticked");

  await click2('[data-w="qsEq"]', 700); await click2('[data-pick^="cat:c1"]', 60); await click2('[data-act="primary"]', 60);
  E("handleTag('04DE0000C8C8')"); await sleep(700); await click2('[data-act="exit"]', 100);
  check(/Add your equipment/.test(text()) && (text().match(/1 added/g) || []).length === 2, "equipment added from setup, ticked");

  await click2('[data-w="qsTour"]');
  check(/Tap your badge/.test(text()), "tour slide 1");
  await click2('[data-w="tourNext"]'); await click2('[data-w="tourNext"]');
  check(/Tap Done/.test(text()) && /Got it/.test(text()), "tour slide 3");
  await click2('[data-w="tourNext"]');
  check(doc.querySelectorAll("#screen .qs-row.did").length === 3 && /Finish setup/.test(text()), "all three ticked -> Finish setup");
  await click2('[data-w="toDone"]'); await click2('[data-w="finish"]', 200);
  check(E("S.screen") === "idle" && E("S.saved.setupDone") === true, "setup finished");

  E("handleTag('04BA0000C7C7')"); await sleep(200);
  check(/Hi, Taylor/.test(text()), "the employee added during setup can check out right away");
  // reboot after setup -> no wizard
  const saved2 = {}; for (let i = 0; i < dom.window.localStorage.length; i++) { const k = dom.window.localStorage.key(i); saved2[k] = dom.window.localStorage.getItem(k); }
  dom.window.close(); dom = boot(saved2); await sleep(400);
  check(dom.window.eval("S.screen") === "idle", "after setup, a reboot goes straight to Tap your badge");
  check(errors.length === 0, "no script errors " + errors.join(";"));
  process.exit();
})();
