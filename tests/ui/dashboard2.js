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
(async () => {
  await sleep(100);
  // Equipment
  await go("equipment"); await click('[data-act="newEq"]');
  await submit('[data-form^="eq:"]', { name: "Radio 07", cat: "c5", asset: "RAD-007", tag: "04:DE:00:05:01" });
  check(/already on Radio 01/.test(drawer()), "add equipment: a tag ID already in use is refused, names the item");
  await submit('[data-form^="eq:"]', { name: "Radio 07", cat: "c5", asset: "RAD-001", tag: "" });
  check(/asset tag is already used/.test(drawer()), "duplicate asset tag refused");
  await submit('[data-form^="eq:"]', { name: "Radio 07", cat: "c5", asset: "RAD-007", tag: "" });
  check(/Radio 07/.test(drawer()) && /Not tagged yet/.test(drawer()) && E("DB.equipment.some(q => q.name === 'Radio 07')"), "Radio 07 added (no tag yet), its panel opens");
  await click('[data-act="editEq"]'); await submit('[data-form^="eq:"]', { name: "Radio 07 (spare)", cat: "c5", asset: "RAD-007", tag: "04DE00000507" });
  check(E("DB.equipment.some(q => q.name === 'Radio 07 (spare)' && q.tag === '04DE00000507')"), "edit equipment: rename + add its tag ID");
  // Employees
  await click('.drawer [data-act="close"]'); await go("employees"); await click('[data-act="newEmp"]');
  await submit('[data-form^="emp:"]', { first: "Nina", last: "Okafor", number: "E1001", badge: "" });
  check(/already used by Alex Rivera/.test(drawer()), "add employee: duplicate employee # refused, names who has it");
  const f = doc.querySelector('[data-form^="emp:"]'); f.elements.role.value = "manager"; f.elements.role.dispatchEvent(new dom.window.Event("change", { bubbles: true })); await sleep(20);
  check(doc.querySelector('[data-form^="emp:"]').elements.pin && doc.querySelector('[data-form^="emp:"]').elements.first.value === "Nina", "choosing Manager fob shows a PIN field and keeps what was typed");
  await submit('[data-form^="emp:"]', { first: "Nina", last: "Okafor", number: "E1013", badge: "04BA0000000C", pin: "" });
  check(/needs a PIN/.test(drawer()), "manager fob without a PIN refused");
  await submit('[data-form^="emp:"]', { first: "Nina", last: "Okafor", number: "E1013", badge: "04BA0000000C", pin: "4826" });
  check(E("DB.employees.some(e => e.name === 'Nina Okafor' && e.role === 'manager' && e.badge === '04BA0000000C')"), "Nina added as a manager fob with her badge");
  await click('[data-act="editEmp"]'); doc.querySelector('[data-form^="emp:"] input[name="shifts"][value="s2"]').checked = true;
  await submit('[data-form^="emp:"]', { first: "Nina", last: "Okafor-Lee", number: "E1013", badge: "04BA0000000C" });
  check(E("(() => { const e = DB.employees.find(e => e.first === 'Nina'); return e.last === 'Okafor-Lee' && e.shifts.includes('s2'); })()"), "edit employee: name + shift");
  await click('.drawer [data-act="close"]');
  // Categories
  await go("settings");
  await submit('[data-form="newCat"]', { name: "Radio", rule: "none", hours: "" });
  check(/already a category/.test(doc.querySelector("#catErr").textContent), "duplicate category name refused");
  await submit('[data-form="newCat"]', { name: "Headsets", rule: "hours", hours: "" });
  check(/number of hours/.test(doc.querySelector("#catErr").textContent), "hours limit needs hours");
  await submit('[data-form="newCat"]', { name: "Headsets", rule: "hours", hours: "6" });
  const hid = E("DB.categories.find(c => c.name === 'Headsets').id");
  const nameIn = doc.querySelector(`[data-cat="${hid}"][data-k="name"]`); nameIn.value = "Headsets & Mics"; nameIn.dispatchEvent(new dom.window.Event("change", { bubbles: true })); await sleep(15);
  check(E("DB.categories.some(c => c.name === 'Headsets & Mics' && c.hours === 6)"), "category added (6 h) and renamed");
  check(!doc.querySelector(`[data-act="askDelCat"][data-id="c5"]`), "categories with equipment have no Delete button");
  await click(`[data-act="askDelCat"][data-id="${hid}"]`); await click(`[data-act="delCat"][data-id="${hid}"]`);
  check(!E("DB.categories.some(c => c.id === '" + hid + "')"), "empty category deleted (after confirm)");
  // Team access
  await go("team");
  await submit('[data-form="invite"]', { email: "nope", role: "viewer" });
  check(/full email/.test(doc.querySelector("#invErr").textContent), "invite: bad email caught");
  doc.querySelector('.inv-scopes input[value="bw"]').checked = true;
  await submit('[data-form="invite"]', { email: "Payroll@DemoAir.example", role: "viewer" });
  check(/payroll@demoair.example/.test(doc.body.textContent) && /Waiting to accept \(2\)/.test(doc.body.textContent), "invite a view-only person -> waiting to accept");
  check(!doc.querySelector('[data-member="u1"]') && E("api.setMemberRole('u1', 'admin').ok") === false && E("DB.members.find(m => m.id === 'u1').role") === "owner", "the only admin can't change their own role");
  // Custom roles (migration 40): make one from boxes, then give it to someone
  check(/Your roles/.test(doc.body.textContent) && /Ramp lead/.test(doc.body.textContent), "roles section lists the company's roles");
  await click('[data-act="roleNew"]');
  { const f = doc.querySelector('[data-form="role:"]'), tpl = f.querySelector("[data-roletpl]"); tpl.value = "supervisor"; tpl.dispatchEvent(new dom.window.Event("change", { bubbles: true })); await sleep(10);
    check([...f.querySelectorAll("input[name=perm]:checked")].map((c) => c.value).join() === "people,status,alerts,visitors", "start from Supervisor ticks its boxes");
    f.querySelector('input[name=perm][value="alerts"]').checked = false; f.querySelector('input[name=perm][value="equipment"]').checked = true; }
  await submit('[data-form="role:"]', { name: "Supervisor" });
  check(/built-in role/.test(doc.querySelector("#roleErr").textContent), "a role can't take a built-in name");
  await submit('[data-form="role:"]', { name: "Gear lead" });
  const gl = E("DB.roles.find(r => r.name === 'Gear lead')");
  check(gl && gl.perms.join() === "people,status,visitors,equipment" && /Gear lead/.test(doc.querySelector(".roles-t thead").textContent), "save it; it shows in the table");
  { const s2 = doc.querySelector('[data-member="u3"]'); check([...s2.options].some((o) => o.value === "role:" + gl.id), "it's in the role list");
    s2.value = "role:" + gl.id; s2.dispatchEvent(new dom.window.Event("change", { bubbles: true })); await sleep(15); }
  check(E("DB.members.find(m => m.id === 'u3').custom") === gl.id && E("DB.members.find(m => m.id === 'u3').role") === "viewer", "give Kelly the Gear lead role");
  await click(`[data-act="roleAskDel"][data-id="${gl.id}"]`); await click(`[data-act="roleDel"][data-id="${gl.id}"]`);
  check(!!E(`roleOf('${gl.id}')`) && /1 person has this role/.test(doc.body.textContent), "a role someone has can't be deleted");
  // As Kelly (Gear lead): People and Equipment yes, Alerts and Stations no, Team no
  E(`DB.me.role = 'viewer'; DB.me.custom = '${gl.id}'; render()`); await sleep(20);
  check(E("has('equipment') && has('people') && !has('alerts') && !has('stations') && !has('team')") && !/Team access/.test(doc.querySelector(".snav").textContent), "a custom role gets exactly its boxes");
  await go("equipment"); check(!!doc.querySelector('[data-act="newEq"]'), "Gear lead: can add equipment");
  await go("stations"); check(!doc.querySelector('[data-act="addStation"]'), "Gear lead: can't add stations");
  E("DB.me.role = 'owner'; DB.me.custom = null; DB.members.find(m => m.id === 'u3').custom = null; render()"); await go("team");
  const sel3 = doc.querySelector('[data-member="u3"]'); sel3.value = "viewer"; sel3.dispatchEvent(new dom.window.Event("change", { bubbles: true })); await sleep(15);
  check(E("DB.members.find(m => m.id === 'u3').role") === "viewer", "change Kelly to View only");
  await click('[data-act="askRm"][data-id="u4"]'); await click('[data-act="rmMember"][data-id="u4"]');
  check(!E("DB.members.some(m => m.id === 'u4')"), "remove someone (after confirm)");
  // Preview as View only
  const va = doc.querySelector("#viewAs"); va.value = "viewer"; va.dispatchEvent(new dom.window.Event("change", { bubbles: true })); await sleep(20);
  check(!/Team access/.test(doc.querySelector(".snav").textContent) && E("S.route") === "overview", "View only: no Team access page");
  await go("equipment"); check(!doc.querySelector('[data-act="newEq"]'), "View only: no Add equipment");
  await click('[data-open^="equipment:"]'); check(!/Mark lost|Edit details|Limits for this item/.test(drawer()), "View only: item panel has no actions"); await click('.drawer [data-act="close"]');
  await go("settings"); check(doc.querySelector("fieldset").disabled && /Ask a manager or admin/.test(doc.body.textContent), "View only: settings are read-only");
  await go("alerts"); check(!doc.querySelector('[data-act="ackStart"]'), "View only: can't mark alerts seen");
  va.value = "supervisor"; doc.querySelector("#viewAs").value = "supervisor"; doc.querySelector("#viewAs").dispatchEvent(new dom.window.Event("change", { bubbles: true })); await sleep(20);
  await go("employees"); check(!!doc.querySelector('[data-act="newEmp"]'), "Supervisor: can add employees");
  await go("equipment"); check(!doc.querySelector('[data-act="newEq"]'), "Supervisor: can't add equipment");
  await click('[data-open^="equipment:"]'); check(/Mark lost/.test(drawer()) && !/Limits for this item/.test(drawer()), "Supervisor: can mark lost, can't change limits");
  check(errors.length === 0, "no script errors " + errors.join(";"));
  process.exit();
})();
