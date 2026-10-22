const { JSDOM } = require("jsdom");
const fs = require("fs");
const src = fs.readFileSync(process.argv[2], "utf8");
const errors = [];
const dom = new JSDOM("<!doctype html><html><body>" + src + "</body></html>", { runScripts: "dangerously", pretendToBeVisual: true, url: "https://example.test/",
  beforeParse(w) { w.matchMedia = () => ({ matches: false, addEventListener() {} }); w.scrollTo = () => {}; } });
dom.window.addEventListener("error", (e) => errors.push(e.message + " @" + e.lineno));
const E = (s) => dom.window.eval(s), doc = dom.window.document;
const text = () => doc.body.textContent.replace(/\s+/g, " ");
const check = (c, m, t) => { console.log((c ? "pass  " : "FAIL  ") + m + (c ? "" : "\n      " + (t || ""))); if (!c) process.exitCode = 1; };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const go = async (r) => { dom.window.location.hash = r; await sleep(30); };
(async () => {
  await sleep(100);
  const st = E(`(() => { const eq = api.equipment(); return { items: eq.length, out: eq.filter(q => q.holder && q.status !== 'lost').length,
     overdue: eq.filter(q => q.is_overdue).length, ext: eq.filter(q => q.is_extended).length, lost: eq.filter(q => q.status === 'lost').length,
     txns: DB.txns.length, forOther: api.activity().filter(a => a.forOther).length, late: api.activity().filter(a => a.flags.includes('returned_after_extended')).length,
     open: api.alerts().filter(a => !a.resolved_at).length, closed: api.alerts().filter(a => a.resolved_at).length,
     reports: api.shiftReports().length, withMissing: api.shiftReports().filter(r => r.outstanding && !r.inProgress).length }; })()`);
  console.log("demo data:", JSON.stringify(st));
  check(st.txns > 100 && st.out > 0 && st.lost === 1 && st.forOther > 0 && st.late > 0 && st.open > 0 && st.closed > 0 && st.withMissing > 0,
        "a week of realistic activity: items out, a lost item, late returns, returns for others, open + closed alerts, reports with missing items");
  // no item is double-booked: two checkouts in a row without a return
  const dbl = E(`(() => { let bad = 0; for (const q of DB.equipment) { const ev = DB.txns.filter(t => t.eq === q.id); for (let i = 1; i < ev.length; i++) if (ev[i].action === ev[i-1].action) bad++; } return bad; })()`);
  check(dbl === 0, "history is consistent: every item alternates checkout / return");
  check(/Good (morning|afternoon|evening), Morgan/.test(text()) && /Checked out/.test(text()) && /Recent activity/.test(text()) && /Taps today/.test(text()) && /Needs attention/.test(text()), "Overview renders");
  // new layout: top bar search, menus, stat shortcuts, phone menu
  const gs = doc.querySelector("#gsearch"); gs.value = "radio 0"; gs.dispatchEvent(new dom.window.Event("input", { bubbles: true })); await sleep(10);
  check(!doc.querySelector("#gsResults").hidden && doc.querySelectorAll("#gsResults button").length >= 3 && /Radio 01/.test(doc.querySelector("#gsResults").textContent), "top bar search finds equipment");
  doc.querySelector("#gsResults button").click(); await sleep(20);
  check(E("S.drawer && S.drawer.kind") === "equipment" && doc.querySelector("#gsResults").hidden && doc.querySelector("#gsearch").value === "", "picking a result opens it and clears the search");
  E("S.drawer = null; renderLayer()");
  gs.value = "zzzz"; gs.dispatchEvent(new dom.window.Event("input", { bubbles: true })); await sleep(10);
  check(/Nothing matches/.test(doc.querySelector("#gsResults").textContent), "search says when nothing matches");
  gs.value = ""; gs.dispatchEvent(new dom.window.Event("input", { bubbles: true })); await sleep(10);
  const acct = doc.querySelector("[data-act=acctMenu]"); acct.click(); await sleep(10);
  check(!acct.nextElementSibling.hidden && acct.getAttribute("aria-expanded") === "true" && /Preview as/.test(acct.nextElementSibling.textContent), "account menu opens");
  check(doc.documentElement.dataset.theme === "light", "light by default, even on a device set to dark");
  doc.querySelector('[data-act=theme][data-v=dark]').click(); await sleep(10);
  check(doc.documentElement.dataset.theme === "dark" && dom.window.localStorage.getItem("sp.theme") === "dark" && doc.querySelector('[data-act=theme][data-v=dark]').getAttribute("aria-pressed") === "true", "pick dark from the account menu (remembered)");
  doc.querySelector('[data-act=theme][data-v=auto]').click(); await sleep(10);
  check(!doc.documentElement.hasAttribute("data-theme"), "or match the device");
  doc.querySelector('[data-act=theme][data-v=light]').click(); await sleep(10);
  doc.querySelector(".wrap").click(); await sleep(10);
  check(doc.querySelector("[data-act=acctMenu]").nextElementSibling.hidden, "clicking elsewhere closes it");
  check(doc.querySelector(".iconbtn .badge")?.textContent === String(st.open - E("api.alerts().filter(a => !a.resolved_at && a.ack_at).length") + E("api.problems().filter(p => !p.cleared_at).length")), "bell shows open alerts not yet seen, plus reported problems");
  doc.querySelector('a.stat[data-filter="out"]').click(); await go("equipment");
  check(E("S.f.eqStatus") === "out", "Checked out card opens equipment filtered to what's out");
  await go("overview");
  doc.querySelector("[data-act=navOpen]").click(); await sleep(10);
  check(doc.querySelector("#app").classList.contains("navopen") && doc.querySelector(".navscrim"), "phone menu opens");
  await go("activity"); check(!doc.querySelector("#app").classList.contains("navopen") && E("S.route") === "activity", "picking a section closes it");
  await go("overview");
  for (const r of ["equipment", "employees", "activity", "alerts", "shifts", "stations", "settings"]) { await go(r); check(doc.querySelector(".head h1") && errors.length === 0, `${r} renders`, errors.join(";")); }
  await go("equipment");
  doc.querySelector('[data-seg="eqStatus:lost"]').click(); await sleep(20);
  check(doc.querySelectorAll("tbody tr").length === 1 && /Lost/.test(doc.querySelector("tbody").textContent), "filter: Lost shows the one lost item");
  doc.querySelector('[data-seg="eqStatus:all"]').click(); await sleep(20);
  const id = E("DB.equipment.find(q => q.status === 'available').id");
  doc.querySelector(`[data-open="equipment:${id}"]`).click(); await sleep(20);
  check(/History/.test(doc.querySelector(".drawer").textContent), "item details open with history");
  doc.querySelector('[data-act="askLost"]').click(); await sleep(10);
  doc.querySelector('[data-act="doStatus"][data-s="lost"]').click(); await sleep(10);
  check(E(`DB.equipment.find(q => q.id === '${id}').status`) === "lost", "mark lost from the dashboard (with confirm)");
  doc.querySelector('[data-act="doStatus"][data-s="available"]').click(); await sleep(10);
  check(E(`DB.equipment.find(q => q.id === '${id}').status`) === "available", "back in service");
  const form = doc.querySelector(`[data-form="limits:${id}"]`);
  form.elements.mode.value = "hours"; form.elements.hours.value = "3"; form.elements.ext.value = "5";
  form.dispatchEvent(new dom.window.Event("submit", { bubbles: true, cancelable: true })); await sleep(10);
  check(E(`(() => { const q = DB.equipment.find(q => q.id === '${id}'); return q.mode === 'hours' && q.hours === 3 && q.extended === 5; })()`), "per-item time limit + alert threshold saved");
  doc.querySelector('.drawer [data-act="close"]').click();
  await go("alerts");
  const aid = E("api.alerts().find(a => !a.resolved_at && !a.ack_at)?.id");
  if (aid) {
    doc.querySelector(`[data-act="ackStart"][data-id="${aid}"]`).click(); await sleep(10);
    const f = doc.querySelector(`[data-form="ack:${aid}"]`); f.elements.note.value = "Called him";
    f.dispatchEvent(new dom.window.Event("submit", { bubbles: true, cancelable: true })); await sleep(10);
    check(E(`DB.alerts.find(a => a.id === '${aid}').notes`) === "Called him", "mark an alert seen with a note");
  }
  await go("shifts");
  const key = E("api.shiftReports().find(r => !r.inProgress && r.outstanding)?.key");
  doc.querySelector(`[data-open="report:${key}"]`).click(); await sleep(10);
  check(/Not back by/.test(doc.querySelector(".drawer").textContent), "shift report lists what wasn't back");
  const rf = doc.querySelector(`.drawer form`); rf.elements.note.value = "Found in van 4";
  rf.dispatchEvent(new dom.window.Event("submit", { bubbles: true, cancelable: true })); await sleep(10);
  check(E(`DB.reportAcks['${key}'].note`) === "Found in van 4", "sign off a shift report");
  doc.querySelector('.drawer [data-act="close"]').click();
  await go("stations");
  doc.querySelector('[data-act="addStation"]').click(); await sleep(10);
  const sf = doc.querySelector('[data-form="station"]'); sf.elements.name.value = "Equipment Room 03";
  sf.dispatchEvent(new dom.window.Event("submit", { bubbles: true, cancelable: true })); await sleep(10);
  check(/^[A-Z2-9]{4}-[A-Z2-9]{4}$/.test(doc.querySelector(".codebox").textContent.trim()), "add a station -> one-time activation code");
  await go("activity");
  doc.querySelector('[data-seg="actType:for"]').click(); await sleep(10);
  check([...doc.querySelectorAll("tbody tr:not(.dayrow)")].every((tr) => /Returned for/.test(tr.textContent)) && doc.querySelectorAll("tbody tr:not(.dayrow)").length > 0, "activity filter: returned for someone");
  doc.querySelector('[data-seg="actType:all"]').click(); doc.querySelector('[data-seg="actRange:7d"]').click(); await sleep(10);
  check(doc.querySelectorAll("tr.dayrow").length >= 2 && ((t) => /Today|Yesterday/.test(t) || [0, 1].some((d) => t.includes(new Date(Date.now() - d * 86400000).toLocaleDateString("en-US", { weekday: "long", timeZone: "America/Phoenix" }))))(doc.querySelector("tr.dayrow").textContent), "activity is grouped by day, newest first", [...doc.querySelectorAll("tr.dayrow")].map((r) => r.textContent).join("|"));
  { const dp = doc.querySelector("#actDay"); const y = E("dayKey(addDays(localDay(Date.now(), tz()), -1))"); dp.value = y; dp.dispatchEvent(new dom.window.Event("change", { bubbles: true })); await sleep(10);
    check(doc.querySelectorAll("tr.dayrow").length === 1 && !/Today/.test(doc.querySelector("tr.dayrow")?.textContent || "Today") && doc.querySelector("[data-act=clearDay]"), "picking a day shows just that day");
    doc.querySelector("[data-act=clearDay]").click(); await sleep(10); }
  { let csv = "";
    dom.window.URL.createObjectURL = () => "blob:x"; dom.window.URL.revokeObjectURL = () => {};
    csv = E("downloadCsv('t', ['A','B'], [['x, y', '=1+1'], ['say \"hi\"', 2]])");
    check(csv.includes('"x, y"') && csv.includes(`"'=1+1"`) && csv.includes('"say ""hi"""'), "CSV quotes commas and quotes, and defuses formulas");
    doc.querySelector("[data-act=csvActivity]").click(); await sleep(10);
    check(/Downloaded \d+ row/.test(doc.body.textContent), "activity downloads as CSV"); }
  await go("equipment"); check(doc.querySelector("[data-act=csvEquipment]") && doc.querySelector("table.cardify td[data-label=With]"), "equipment has CSV download and phone card labels");
  await go("employees"); check(/On file/.test(doc.querySelector("table.cardify tbody").textContent) && !/([0-9A-F]{2}:){3}/.test(doc.querySelector("table.cardify tbody").textContent), "badges show as 'On file' with a short code, not the raw number");
  await go("overview"); check(!doc.querySelector(".setup"), "the set-up checklist is hidden once the demo company is set up");
  E("window._st = api.stations; api.stations = () => []; render()"); await sleep(10);
  check(/1 of 4|2 of 4|3 of 4/.test(doc.querySelector(".setup")?.textContent || "") && doc.querySelector('.setup a[href="#stations"]'), "a company still setting up sees the checklist with a link to each step");
  doc.querySelector("[data-act=hideSetup]").click(); await sleep(10);
  check(!doc.querySelector(".setup"), "the checklist can be hidden");
  E("api.stations = window._st; localStorage.clear(); render()");
  // logo in Settings
  await go("settings");
  check(doc.querySelector("#logoFile") && /No logo yet: stations show your name/.test(doc.querySelector(".logo-row").textContent), "settings offers a logo upload, their name shown until then");
  const lf = doc.querySelector("#logoFile"); Object.defineProperty(lf, "files", { value: [new dom.window.File(["hi"], "notes.txt", { type: "text/plain" })] });
  lf.dispatchEvent(new dom.window.Event("change", { bubbles: true })); await sleep(50);
  check(/Pick a PNG, JPG, SVG or WebP image/.test(doc.querySelector("#layer").textContent) && !E("DB.org.logo_url"), "a non-image file is refused");
  E("api.saveSettings({ logo_url: 'https://example.test/logo.png' }); render()"); await sleep(10);
  check(doc.querySelector(".logo-prev img").getAttribute("src") === "https://example.test/logo.png" && doc.querySelector("[data-act=rmLogo]"), "an uploaded logo shows with Remove");
  doc.querySelector("[data-act=rmLogo]").click(); await sleep(10);
  check(!E("DB.org.logo_url"), "remove the logo");
  check(errors.length === 0, "no script errors " + errors.join(";"));
  process.exit();
})();
