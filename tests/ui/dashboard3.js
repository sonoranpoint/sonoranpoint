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
(async () => {
  await sleep(100);
  await go("shifts");
  check(/Shifts/.test(page()) && /AM/.test(page()) && /5:00 AM to 1:30 PM/.test(page()) && /Every day/.test(page()) && /9:00 PM to 5:30 AM \(next day\)/.test(page()), "Shifts page lists shifts with times and days");
  check(/Shift reports/.test(page()) && doc.querySelectorAll('[data-open^="report:"]').length > 10, "shift reports still below");
  // edit AM
  await click('[data-open="shiftForm:s1"]');
  check(/Edit AM shift/.test(drawer()), "edit drawer opens");
  setChecks("days", ["1","2","3","4","5"]);
  await submit('[data-form="shift:s1"]', { name: "Morning", start: "04:30", end: "13:00", grace: "20", early: "45" });
  const s1 = E("JSON.stringify(DB.shifts[0])");
  check(/"name":"Morning"/.test(s1) && /"start":"04:30"/.test(s1) && /"days":\[1,2,3,4,5\]/.test(s1) && /"grace":20/.test(s1), "AM saved as Morning, 4:30–1:00, Mon–Fri, 20 min", s1);
  check(/Morning/.test(page()) && /Mon–Fri/.test(page()), "list shows new name and Mon–Fri");
  // validation
  await click('[data-open="shiftForm:s2"]');
  await submit('[data-form="shift:s2"]', { name: "morning" });
  check(/already a shift with that name/.test(drawer()), "duplicate name refused");
  await submit('[data-form="shift:s2"]', { name: "PM", start: "13:00", end: "13:00" });
  check(/can't be the same time/.test(drawer()), "same start/end refused");
  setChecks("days", []);
  await submit('[data-form="shift:s2"]', { name: "PM", start: "13:00", end: "21:30" });
  check(/Pick at least one day/.test(drawer()), "no days refused");
  await click('[data-act="close"]');
  // add a shift with crew
  await click('[data-open="shiftForm:"]');
  setChecks("crew", ["e1", "e5"]);
  await submit('[data-form="shift:"]', { name: "Swing", start: "10:00", end: "18:30", grace: "15", early: "60" });
  const sw = E("DB.shifts.find(s => s.name === 'Swing')");
  check(sw && E("DB.employees.find(e => e.id === 'e1').shifts.includes(DB.shifts.find(s => s.name === 'Swing').id)") && E("DB.employees.find(e => e.id === 'e5').shifts.length") === 2, "Swing added with Alex and Marcus on it");
  check(/Swing/.test(page()) && /10:00 AM to 6:30 PM/.test(page()), "Swing listed");
  // stop using
  const swid = E("DB.shifts.find(s => s.name === 'Swing').id");
  await click(`[data-open="shiftForm:${swid}"]`); await click('[data-act="askStopShift"]'); await click('[data-act="doShiftActive"]');
  check(E("DB.shifts.find(s => s.name === 'Swing').active") === false && /Not in use/.test(page()), "stop using a shift");
  await go("employees"); await click('[data-act="newEmp"]');
  check(!/Swing/.test(drawer()) && /Morning/.test(drawer()), "stopped shift hidden when adding an employee");
  await click('[data-act="close"]');
  // supervisor: crew only
  E("DB.me.role = 'supervisor'; render()"); await go("shifts");
  check(!doc.querySelector('[data-open="shiftForm:"]'), "supervisor: no Add a shift");
  await click('[data-open="shiftForm:s2"]');
  check(doc.querySelector('.drawer [name="name"]').matches(':disabled') && /An admin changes its times/.test(drawer()), "supervisor: times locked");
  setChecks("crew", ["e5", "e6"]);
  await submit('[data-form="shift:s2"]', {});
  check(E("DB.employees.filter(e => e.shifts.includes('s2')).map(e => e.id).join()") === "e5,e6" && E("DB.shifts[1].name") === "PM", "supervisor can change crew; times unchanged");
  // viewer
  E("DB.me.role = 'viewer'; render()"); await go("shifts");
  await click('[data-open="shiftForm:s2"]');
  check(!doc.querySelector('.drawer button.primary') && /View only/.test(drawer()), "viewer: read only");
  check(errors.length === 0, "no script errors " + errors.join(";"));
  process.exit();
})();
