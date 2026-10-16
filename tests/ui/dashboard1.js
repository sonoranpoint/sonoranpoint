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
  check(/Good (morning|afternoon|evening), Morgan/.test(text()) && /Out right now/.test(text()) && /Needs attention/.test(text()), "Overview renders");
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
  check([...doc.querySelectorAll("tbody tr")].every((tr) => /Returned for/.test(tr.textContent)) && doc.querySelectorAll("tbody tr").length > 0, "activity filter: returned for someone");
  check(errors.length === 0, "no script errors " + errors.join(";"));
  process.exit();
})();
