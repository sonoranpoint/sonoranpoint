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
// An employee's dashboard role from their page (migration 42): Agent = badge only; a role needs their email for the invite.
(async () => {
  await sleep(100);
  await go("employees");
  const luis = E("DB.employees.find(e => e.name === 'Luis Ortega').id");
  E(`openDrawer('employee', '${luis}')`); await sleep(20);
  check(/Dashboard ?Agent ?Badge only/.test(drawer()), "an employee starts as an Agent: badge only", drawer().slice(0, 400));
  E(`S.formErr = null; openDrawer('empForm', '${luis}')`); await sleep(20);
  const opts = [...access().options].map((o) => o.value);
  check(opts[0] === "" && opts.includes("viewer") && opts.includes("supervisor") && opts.includes("admin") && opts.includes("role:rl") && !opts.includes("owner"),
        "the role list: Agent, the built-in roles and the company's own, but not Admin", opts.join());
  check(/Admins are added and changed by Sonoran Point/.test(drawer()), "says Admins come from Sonoran Point");
  check(!doc.querySelector('.drawer input[name=email]'), "no email needed for an Agent");
  await change(access(), "supervisor");
  check(!!doc.querySelector('.drawer input[name=email]') && doc.querySelector('.drawer input[name=first]').value === "Luis", "picking a role asks for their email (and keeps the form)");
  await submit('[data-form^="emp:"]', { email: "" });
  check(/Enter their email/.test(drawer()) && !E("DB.invites.some(i => i.employee)"), "no email, no invite");
  await submit('[data-form^="emp:"]', { email: "Luis.Ortega@crew.example" });
  const inv = E(`JSON.stringify(DB.invites.find(i => i.employee === '${luis}'))`);
  check(inv && JSON.parse(inv).email === "luis.ortega@crew.example" && JSON.parse(inv).role === "supervisor" && JSON.parse(inv).contracts.join() === E(`empOf('${luis}').contract`),
        "an invite goes out for Supervisor, for their contract", inv);
  check(E("S.drawer.kind") === "employee" && /Supervisor ?Invite sent to luis.ortega@crew.example/.test(drawer()), "their page shows the invite waiting", drawer().slice(0, 500));
  E(`openDrawer('empForm', '${luis}')`); await sleep(20);
  check(access().value === "supervisor" && doc.querySelector('.drawer input[name=email]').value === "luis.ortega@crew.example", "editing again shows the role and the email it went to");
  await change(access(), "");
  await submit('[data-form^="emp:"]', {});
  check(!E(`DB.invites.some(i => i.employee === '${luis}')`) && /Agent/.test(drawer()), "back to Agent cancels the invite");
  // Someone already on the dashboard: entering their email links them.
  E(`openDrawer('empForm', '${luis}')`); await sleep(20);
  await change(access(), "viewer");
  await submit('[data-form^="emp:"]', { email: E("DB.members.find(m => m.id === 'u4').email") });
  check(E(`empOf('${luis}').user`) === "u4" && E("DB.members.find(m => m.id === 'u4').role") === "viewer", "an email already on the team links that account");
  E(`openDrawer('empForm', '${luis}')`); await sleep(20);
  check(!doc.querySelector('.drawer input[name=email]'), "once linked, no email needed");
  await change(access(), "role:rl");
  await submit('[data-form^="emp:"]', {});
  check(E("DB.members.find(m => m.id === 'u4').custom") === "rl", "change their role to Ramp lead from their page");
  E(`openDrawer('empForm', '${luis}')`); await sleep(20); await change(access(), ""); await submit('[data-form^="emp:"]', {});
  check(!E("DB.members.some(m => m.id === 'u4')") && !E(`empOf('${luis}').user`), "Agent takes dashboard access away");
  // Dana's badge is linked to her Manager account in the demo.
  const dana = E("DB.employees.find(e => e.name === 'Dana Brooks').id");
  E(`openDrawer('employee', '${dana}')`); await sleep(20);
  check(/Dashboard ?Manager ?dana.brooks@/.test(drawer()), "a linked employee shows their dashboard role and email", drawer().slice(0, 400));
  // Morgan's own Admin account can't be changed here.
  E(`empOf('${dana}').user = 'u1'; openDrawer('empForm', '${dana}')`); await sleep(20);
  check(!access() && /Admin\. Admins are added and changed by Sonoran Point/.test(drawer()), "an Admin's role is shown, not changeable");
  E(`empOf('${dana}').user = 'u2'`);
  // A Manager can give only roles below Manager; a Supervisor (no Team box) doesn't see the field.
  E("S.drawer = null; DB.me.role = 'admin'; render()"); E(`openDrawer('empForm', '${luis}')`); await sleep(20);
  const mopts = [...access().options].map((o) => o.value);
  check(!mopts.includes("admin") && mopts.includes("supervisor"), "a Manager can't make Managers here", mopts.join());
  E("S.drawer = null; DB.me.role = 'supervisor'; render()"); E(`openDrawer('empForm', '${luis}')`); await sleep(20);
  check(!access() && !!doc.querySelector('.drawer input[name=first]'), "a Supervisor edits the employee but not dashboard access");
  check(/Sonoran Point/.test(E(`api.setEmployeeAccess('${luis}', 'supervisor', 'x@y.example').error`) || "") || /manager or admin/.test(E(`api.setEmployeeAccess('${luis}', 'supervisor', 'x@y.example').error`)), "and the api refuses them");
  E("DB.me.role = 'owner'");
  check(/Sonoran Point/.test(E(`api.setEmployeeAccess('${luis}', 'owner', 'x@y.example').error`)), "nobody makes an Admin from the employee page");
  check(errors.length === 0, "no script errors " + errors.join(";"));
  process.exit();
})();
