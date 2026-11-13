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
const submit = async (sel, vals) => { const f = doc.querySelector(sel); for (const [k, v] of Object.entries(vals)) f.elements[k].value = v; f.dispatchEvent(new dom.window.Event("submit", { bubbles: true, cancelable: true })); await sleep(20); };
const drawer = () => doc.querySelector(".drawer")?.textContent.replace(/\s+/g, " ") || "";
const change = async (el, v) => { el.value = v; el.dispatchEvent(new dom.window.Event("change", { bubbles: true })); await sleep(15); };
const access = () => doc.querySelector('.drawer select[name=access]');
// One role per person (migrations 42, 43): Agent = badge only; a role sets the fob and, with an email, the dashboard. Positions and departments.
(async () => {
  await sleep(100);
  await go("employees");
  const luis = E("DB.employees.find(e => e.name === 'Luis Ortega').id");
  E(`openDrawer('employee', '${luis}')`); await sleep(20);
  check(/Role ?Agent ?Badge only/.test(drawer()) && !/Dashboard/.test(drawer()), "an employee starts as an Agent: badge only", drawer().slice(0, 400));
  E(`S.formErr = null; openDrawer('empForm', '${luis}')`); await sleep(20);
  check(!doc.querySelector('.drawer select[name=role]'), "no separate station fob setting any more");
  const opts = [...access().options].map((o) => o.value);
  check(opts[0] === "" && opts.includes("viewer") && opts.includes("supervisor") && opts.includes("admin") && opts.includes("role:rl") && !opts.includes("owner"),
        "the role list: Agent, the built-in roles and the company's own, but not Admin", opts.join());
  check(/Admins are added and changed by Sonoran Point/.test(drawer()), "says Admins come from Sonoran Point");
  check(!doc.querySelector('.drawer input[name=email]') && !doc.querySelector('.drawer input[name=pin]'), "an Agent needs no PIN or email");
  await change(access(), "supervisor");
  check(!!doc.querySelector('.drawer input[name=pin]') && !!doc.querySelector('.drawer input[name=email]') && doc.querySelector('.drawer input[name=first]').value === "Luis",
        "a Supervisor gets a PIN field and an optional email (and the form keeps what was typed)");
  await submit('[data-form^="emp:"]', { pin: "", email: "" });
  check(/Give them a PIN/.test(drawer()) && E(`empOf('${luis}').access`) === "", "a role with station powers needs a PIN when they have a badge");
  await submit('[data-form^="emp:"]', { pin: "4321", email: "" });
  check(E(`empOf('${luis}').access`) === "supervisor" && E(`empOf('${luis}').role`) === "manager" && E(`empOf('${luis}').pin`) && !E("DB.invites.some(i => i.employee)"),
        "no email: a Supervisor at the station only, no invite");
  check(/Role ?Supervisor ?Opens the station's Admin menu/.test(drawer()) && /Dashboard ?No/.test(drawer()), "their page: Supervisor, Admin menu, no dashboard", drawer().slice(0, 500));
  E(`openDrawer('empForm', '${luis}')`); await sleep(20);
  check(access().value === "supervisor" && /New PIN/.test(drawer()), "editing again: the role is kept, the PIN is optional");
  await submit('[data-form^="emp:"]', { email: "Luis.Ortega@crew.example", pin: "" });
  const inv = E(`JSON.stringify(DB.invites.find(i => i.employee === '${luis}'))`);
  check(inv && JSON.parse(inv).email === "luis.ortega@crew.example" && JSON.parse(inv).role === "supervisor" && JSON.parse(inv).contracts.join() === E(`empOf('${luis}').contract`),
        "adding an email later sends a Supervisor invite for their contract", inv);
  check(/Dashboard ?Invited ?luis.ortega@crew.example/.test(drawer()), "their page shows the invite waiting", drawer().slice(0, 500));
  E(`openDrawer('empForm', '${luis}')`); await sleep(20);
  await change(access(), "");
  await submit('[data-form^="emp:"]', {});
  check(!E(`DB.invites.some(i => i.employee === '${luis}')`) && E(`empOf('${luis}').role`) === "employee" && !E(`empOf('${luis}').pin`), "back to Agent: invite cancelled, fob back to badge only");
  // Someone already on the dashboard: entering their email links them; the role is shared.
  E(`openDrawer('empForm', '${luis}')`); await sleep(20);
  await change(access(), "viewer");
  check(!doc.querySelector('.drawer input[name=pin]'), "View Only has no station powers: no PIN");
  await submit('[data-form^="emp:"]', { email: E("DB.members.find(m => m.id === 'u4').email") });
  check(E(`empOf('${luis}').user`) === "u4" && E("DB.members.find(m => m.id === 'u4').role") === "viewer", "an email already on the team links that account");
  E(`openDrawer('empForm', '${luis}')`); await sleep(20);
  check(!doc.querySelector('.drawer input[name=email]'), "once linked, no email field");
  await change(access(), "role:rl"); await submit('[data-form^="emp:"]', { pin: "2580" });
  check(E("DB.members.find(m => m.id === 'u4').custom") === "rl" && E(`empOf('${luis}').role`) === "manager", "Ramp lead from their page: dashboard and fob both change");
  await go("team"); const sel = doc.querySelector('[data-member="u4"]'); sel.value = "viewer"; sel.dispatchEvent(new dom.window.Event("change", { bubbles: true })); await sleep(20);
  check(E(`empOf('${luis}').access`) === "viewer" && E(`empOf('${luis}').role`) === "employee", "changing them on the Team page changes their fob too");
  await go("employees");
  E(`openDrawer('empForm', '${luis}')`); await sleep(20); await change(access(), ""); await submit('[data-form^="emp:"]', {});
  check(!E("DB.members.some(m => m.id === 'u4')") && !E(`empOf('${luis}').user`), "Agent takes dashboard access away");
  // Positions: Priya is Supervisor for Cabin and for Janitorial at Delta BW.
  const pri = E("DB.employees.find(e => e.name === 'Priya Shah').id");
  E(`openDrawer('employee', '${pri}')`); await sleep(20);
  check(/Positions ?Cabin ?Janitorial/.test(drawer()), "a person can have several positions (same title as their role: just the department)", drawer().slice(0, 600));
  check(/Supervisor ?Cabin, Janitorial/.test(doc.querySelector(".main").textContent), "the Employees list shows Supervisor · Cabin, Janitorial");
  E(`openDrawer('empForm', '${pri}')`); await sleep(20);
  check(doc.querySelectorAll('.drawer [name=pos_title]').length === 2 && [...doc.querySelectorAll('.drawer [name=pos_dept]')[0].options].map((o) => o.textContent).join() === "No department,Cabin,Janitorial,Lav,Sky Club",
        "the form lists them, with Delta BW's departments to pick from");
  doc.querySelector('.drawer [name=last]').value = "Shah-Kaur";
  await (async () => { doc.querySelector('.drawer [data-act="posAdd"]').click(); await sleep(15); })();
  check(doc.querySelectorAll('.drawer [name=pos_title]').length === 3 && doc.querySelector('.drawer [name=last]').value === "Shah-Kaur", "Add a position adds a row and keeps what was typed");
  const rows = doc.querySelectorAll('.drawer .pos-row'); rows[2].querySelector("[name=pos_title]").value = "Lead"; rows[2].querySelector("[name=pos_dept]").value = "dp4";
  rows[0].querySelector('[data-act="posDel"]').click(); await sleep(15);
  check(doc.querySelectorAll('.drawer [name=pos_title]').length === 2, "Remove takes a row out");
  await submit('[data-form^="emp:"]', {});
  check(E(`posShort(empOf('${pri}')).join()`) === "Janitorial,Lead – Sky Club" && E(`empOf('${pri}').positions.map(posText).join()`) === "Supervisor – Janitorial,Lead – Sky Club" && E(`empOf('${pri}').last`) === "Shah-Kaur", "positions save with the rest",
        E(`empOf('${pri}').positions.map(posText).join()`));
  // Departments
  check(/Departments/.test(doc.querySelector(".main").textContent), "Employees has the department list");
  await submit('[data-form="dept"]', { name: "Ramp", contract: "dbw" });
  check(E("DB.departments.some(d => d.name === 'Ramp' && d.contract === 'dbw')"), "add a department to Delta BW");
  await submit('[data-form="dept"]', { name: "ramp", contract: "dbw" });
  check(/already there/.test(doc.querySelector("#deptErr").textContent), "no duplicates in one contract");
  const ramp = E("DB.departments.find(d => d.name === 'Ramp').id");
  doc.querySelector(`[data-act="delDept"][data-id="${ramp}"]`).click(); await sleep(15);
  check(!E("DB.departments.some(d => d.name === 'Ramp')"), "and remove it");
  // Dana's badge is linked to her Manager account in the demo.
  const dana = E("DB.employees.find(e => e.name === 'Dana Brooks').id");
  E(`openDrawer('employee', '${dana}')`); await sleep(20);
  check(/Role ?Manager/.test(drawer()) && /Dashboard ?Signs in ?dana.brooks@/.test(drawer()), "a linked employee shows their role and dashboard email", drawer().slice(0, 400));
  // Morgan is an Admin: not changeable here.
  const morgan = E("DB.employees.find(e => e.name === 'Morgan Reyes').id");
  E(`openDrawer('empForm', '${morgan}')`); await sleep(20);
  check(!access() && /Admin\. Admins are added and changed by Sonoran Point/.test(drawer()), "an Admin's role is shown, not changeable");
  // A Manager can give only roles below Manager; a Supervisor (no Team box) doesn't get the role list.
  E("S.drawer = null; DB.me.role = 'admin'; render()"); E(`openDrawer('empForm', '${luis}')`); await sleep(20);
  const mopts = [...access().options].map((o) => o.value);
  check(!mopts.includes("admin") && mopts.includes("supervisor"), "a Manager can't make Managers here", mopts.join());
  E("S.drawer = null; DB.me.role = 'supervisor'; render()"); E(`openDrawer('empForm', '${luis}')`); await sleep(20);
  check(!access() && !!doc.querySelector('.drawer input[name=first]') && !!doc.querySelector('.drawer [name=pos_title], .drawer [data-act="posAdd"]'),
        "a Supervisor edits the employee and positions, not roles");
  check(!/You can't|Sonoran/.test(E(`api.setEmployeeAccess('${luis}', '', '', '').error || ''`)) && /You can't give that role/.test(E(`api.setEmployeeAccess('${luis}', 'supervisor', '', '1234').error`)),
        "and the api refuses them a role");
  E("DB.me.role = 'owner'");
  check(/Sonoran Point/.test(E(`api.setEmployeeAccess('${luis}', 'owner', 'x@y.example').error`)), "nobody makes an Admin from the employee page");
  await go("team");
  check(/At the station.*Badge only.*Admin menu.*Admin menu.*Admin menu/.test(doc.querySelector(".roles-t").textContent.replace(/\s+/g, " ")), "the role table says what each role's fob does");
  check(errors.length === 0, "no script errors " + errors.join(";"));
  process.exit();
})();
