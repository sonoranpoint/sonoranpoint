const { JSDOM } = require("jsdom");
const fs = require("fs");
const src = fs.readFileSync(process.argv[2], "utf8");
const errors = [];
const dom = new JSDOM("<!doctype html><html><body>" + src + "</body></html>", { runScripts: "dangerously", pretendToBeVisual: true, url: "https://example.test/",
  beforeParse(w) { w.matchMedia = () => ({ matches: false, addEventListener() {} }); w.scrollTo = () => {}; } });
dom.window.addEventListener("error", (e) => errors.push(e.message + " @" + e.lineno));
const E = (s) => dom.window.eval(s), doc = dom.window.document;
const check = (c, m, t) => { console.log((c ? "pass  " : "FAIL  ") + m + (c ? "" : "\n      " + (t || ""))); if (!c) process.exitCode = 1; };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const go = async (r) => { dom.window.location.hash = r; await sleep(30); };
const click = async (sel) => { const el = doc.querySelector(sel); if (!el) throw new Error("missing " + sel); el.click(); await sleep(15); };
const submit = async (sel, vals) => { const f = doc.querySelector(sel); for (const [k, v] of Object.entries(vals)) f.elements[k].value = v; f.dispatchEvent(new dom.window.Event("submit", { bubbles: true, cancelable: true })); await sleep(20); };
const drawer = () => doc.querySelector(".drawer")?.textContent.replace(/\s+/g, " ") || "";
const page = () => doc.querySelector(".main").textContent.replace(/\s+/g, " ");
const setChecks = (name, vals) => doc.querySelectorAll(`.drawer input[name="${name}"]`).forEach((cb) => { cb.checked = vals.includes(cb.value); });
const change = async (el, v) => { if (typeof v === "boolean") el.checked = v; else el.value = v; el.dispatchEvent(new dom.window.Event("change", { bubbles: true })); await sleep(15); };
(async () => {
  await sleep(100);
  // Home and alerts show what's reported
  check(/Battery 05: Damaged/.test(page()) && /Radio 06: Not charging/.test(page()), "home: reported problems need attention");
  await go("activity");
  check(/had a reported problem/.test(page()), "activity flags a checkout of an item with a reported problem");
  await go("alerts"); await click('[data-seg="alertTab:problems"]');
  check(/Open \(2\)/.test(page()) && /Cleared by Dana Brooks/.test(page()) && /Found it in the van/.test(page()), "alerts: a Reported problems tab with open and cleared ones");
  await go("equipment"); await click('[data-seg="eqStatus:problem"]');
  check(doc.querySelectorAll("tbody tr").length === 2 && /Damaged/.test(page()), "equipment: filter to items with problems; the chip says what's wrong");

  // Report one from the equipment panel
  const vac1 = E("DB.equipment.find(q => q.name === 'Vacuum 01').id");
  E(`openDrawer('equipment', '${vac1}')`); await sleep(20);
  check(/Nothing reported/.test(drawer()), "an item with no problems says so");
  await click("[data-act=reportStart]");
  check(doc.querySelectorAll(".drawer .reasons input[type=radio]").length === 4 && !/Stops checkout/.test(drawer()), "report form lists the company's reasons");
  doc.querySelector('.drawer .reasons input[value="r1"]').checked = true;
  await submit('[data-form^="problem:"]', { notes: "Hose split" });
  check(/Reported/.test(doc.body.textContent) && /Damaged/.test(drawer()) && /Hose split/.test(drawer()), "reporting it damaged shows on the item");
  check(E(`api.equipment().find(q => q.id === '${vac1}').problem.blocks`) === false, "damaged flags it but doesn't stop checkout");
  await click("[data-act=clearStart]"); await submit('[data-form^="clear:"]', { note: "New hose fitted" });
  check(!E(`api.equipment().find(q => q.id === '${vac1}').problem`) && /Cleared before \(1\)/.test(drawer()), "clearing it keeps it in the item's past problems");
  E("S.drawer = null; render()");

  // A viewer can see but not report or clear
  E("DB.me.role = 'viewer'; render()"); E(`openDrawer('equipment', DB.equipment.find(q => q.name === 'Battery 05').id)`); await sleep(20);
  check(/Damaged/.test(drawer()) && !doc.querySelector(".drawer [data-act=reportStart]") && !doc.querySelector(".drawer [data-act=clearStart]"), "view-only: sees problems, can't report or clear");
  E("S.drawer = null; DB.me.role = 'owner'; render()");

  // Settings: the reasons list
  await go("settings");
  check(doc.querySelectorAll("input[data-reason][data-k=label]").length === 4, "settings lists the four starting reasons");
  await submit('[data-form="newReason"]', { label: "Battery swollen" }); 
  check(E("api.reasons().map(r => r.label).join(',')") === "Damaged,Not charging,Missing part,Other,Battery swollen", "admin adds a reason");
  await submit('[data-form="newReason"]', { label: "damaged" });
  check(/already on the list/.test(doc.querySelector("#reasonErr").textContent), "no duplicates");
  const sw = [...doc.querySelectorAll("input[data-reason][data-k=blocks]")].find((x) => x.closest("tr").querySelector("input[data-k=label]").value === "Battery swollen");
  await change(sw, true);
  check(E("api.reasons().find(r => r.label === 'Battery swollen').blocks") === true, "and makes it stop checkout");
  const nm = [...doc.querySelectorAll("input[data-reason][data-k=label]")].find((x) => x.value === "Other");
  await change(nm, "Something else");
  check(E("api.reasons().some(r => r.label === 'Something else')"), "renames one");
  await click('[data-act="askRmReason"]'); await click('[data-act="doRmReason"]');
  check(!E("api.reasons().some(r => r.label === 'Damaged')") && E("DB.problems.find(p => p.id === 'p1').reason") === "Damaged", "removes one; past reports keep their wording");

  // Email alerts
  check(doc.querySelectorAll("tr[data-email-row]").length === 4, "email alerts: an admin sees everyone on the team");
  const box = doc.querySelector('input[data-email="u4"][value="problem"]');
  await change(box, true);
  check(JSON.stringify(E("api.emailPrefs('u4')")) === '["problem"]' && /Email alerts saved/.test(doc.body.textContent), "turns on problem emails for someone");
  E("DB.me.role = 'supervisor'; render()"); await sleep(10);
  check(doc.querySelectorAll("tr[data-email-row]").length === 1 && doc.querySelector('tr[data-email-row="u1"]'), "a supervisor only sees (and sets) their own");
  check(!E("api.setEmailPrefs('u2', []).ok"), "and can't change someone else's");
  E("DB.me.role = 'owner'; render()");

  // Links from alert emails open the exact thing
  const bat5 = E("DB.equipment.find(q => q.name === 'Battery 05').id");
  dom.window.location.hash = `equipment?open=equipment:${bat5}&org=x`; await sleep(60);
  check(E("S.route") === "equipment" && E("S.drawer && S.drawer.id") === bat5 && dom.window.location.hash === "#equipment", "an email link opens that item (and tidies the address)");
  E("S.drawer = null; render()");
  const rep = E("api.shiftReports().find(r => !r.inProgress).key");
  dom.window.location.hash = `shifts?open=report:${rep}`; await sleep(60);
  check(E("S.route") === "shifts" && E("S.drawer && S.drawer.kind") === "report", "a shift report email link opens the report");
  E("S.drawer = null; render()");
  dom.window.location.hash = "equipment?open=equipment:gone"; await sleep(60);
  check(!E("S.drawer") && /isn't in your equipment anymore/.test(doc.body.textContent), "a link to something deleted says so");
  // Small polish
  check(doc.title === "Demo Air Services · Sonoran Point", "browser tab shows the company's name");
  E(`openDrawer('equipment', '${bat5}')`); await sleep(20);
  check(doc.querySelector(".drawer .xclose[aria-label=Close] svg"), "panels close with an X button");
  await click(".drawer .xclose"); check(!E("S.drawer"), "and it closes");
  await go("shifts");
  const sections = () => [...doc.querySelectorAll(".main section.panel .panel-h h2")].map((h) => h.textContent).filter((t) => t !== "Shifts");
  check(sections().length <= 7, "shift reports: the last 7 days");
  const am = E("DB.shifts.find(x => x.name === 'AM').id");
  await click(`[data-seg="repShift:${am}"]`);
  check([...doc.querySelectorAll('.main [data-open^="report:"] b')].every((b) => b.textContent === "AM") && doc.querySelectorAll('.main [data-open^="report:"]').length > 0, "filter reports to one shift");
  E("DB.occs.push(...DB.occs.filter(o => o.s.name === 'AM').map(o => ({ ...o, start: o.start - 10 * 86400000, end: o.end - 10 * 86400000, day: addDays(o.day, -10) })))");
  E("const _sr = api.shiftReports; api.shiftReports = () => { const r = []; for (const o of DB.occs) { const cutoff = o.end + o.s.grace * MIN; r.push({ key: o.s.id + ':' + dayKey(o.day), shift: o.s, day: o.day, start: o.start, end: o.end, cutoff, inProgress: cutoff > Date.now(), items: [], outstanding: 0, stillOut: 0, ack: null }); } return r.sort((a, b) => b.start - a.start); }; render()");
  check(/Show older reports/.test(page()), "older reports are behind Show older");
  await click("[data-act=repOlder]"); await click("[data-act=repOlder]");
  check(sections().length > 7, "Show older adds a week at a time");
  await go("stations");
  check(/Taps today/.test(page()) && /Items out/.test(page()), "station cards show taps today and items out");
  E("openDrawer('station', 'st2')"); await sleep(20);
  await submit('[data-form="stationEdit:st2"]', { name: "Equipment Room 01", location: "" });
  check(/Another station already has that name/.test(drawer()), "two stations can't share a name");
  await submit('[data-form="stationEdit:st2"]', { name: "Bag Room West", location: "Terminal 4" });
  check(E("DB.stations.find(s => s.id === 'st2').name") === "Bag Room West" && /Station saved/.test(doc.body.textContent), "rename a station from its panel");
  check(errors.length === 0, "no script errors " + errors.join(";"));
  process.exit();
})();
