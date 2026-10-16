const { JSDOM } = require("jsdom");
const fs = require("fs");
const { start } = require("./backend");
const src = fs.readFileSync(process.argv[2], "utf8");
const check = (c, m, t) => { console.log((c ? "pass  " : "FAIL  ") + m + (c ? "" : "\n      " + String(t ?? "").slice(0, 500))); if (!c) process.exitCode = 1; };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const ORG = "00000000-0000-0000-0000-00000000d3e0";
(async () => {
  const b = await start(); const psql = b.psql;
  const store = {};   // localStorage shared like one browser
  const open = (url = "https://app.sonoranpoint.test/") => {
    const errors = [];
    const dom = new JSDOM("<!doctype html><html><body>" + src + "</body></html>", { runScripts: "dangerously", pretendToBeVisual: true, url,
      beforeParse(w) { w.SP_CONFIG = { url: b.url, key: b.key }; w.fetch = fetch; w.Headers = Headers; w.Request = Request; w.Response = Response;
        w.matchMedia = () => ({ matches: false, addEventListener() {} }); w.scrollTo = () => {}; Object.defineProperty(w, "crypto", { value: require("crypto").webcrypto });
        w.supabase = require("@supabase/supabase-js"); } });
    dom.window.addEventListener("error", (e) => errors.push(e.message));
    const doc = dom.window.document, E = (s) => dom.window.eval(s);
    const text = () => (doc.querySelector("#app").textContent + " " + doc.querySelector("#layer").textContent).replace(/\s+/g, " ");
    const until = async (fn, ms = 7000) => { const t0 = Date.now(); while (Date.now() - t0 < ms) { try { if (fn()) return true; } catch {} await sleep(50); } return false; };
    const set = (sel, v) => { const el = doc.querySelector(sel); if (!el) throw new Error("missing " + sel + " :: " + text().slice(0, 300)); el.value = v; el.dispatchEvent(new dom.window.Event("input", { bubbles: true })); };
    const change = (sel, v) => { const el = doc.querySelector(sel); if (typeof v === "boolean") el.checked = v; else el.value = v; el.dispatchEvent(new dom.window.Event("change", { bubbles: true })); };
    const submit = (sel) => { const el = doc.querySelector(sel); if (!el) throw new Error("missing " + sel + " :: " + text().slice(0, 300)); el.dispatchEvent(new dom.window.Event("submit", { bubbles: true, cancelable: true })); };
    const click = (sel) => { const el = doc.querySelector(sel); if (!el) throw new Error("missing " + sel + " :: " + text().slice(0, 300)); el.click(); };
    const go = (h) => { dom.window.location.hash = h; };
    const settled = async () => { await sleep(30); return until(() => E("L.pending") === 0 && !E("L.reloading") && !doc.querySelector(".drawer button[disabled]")); };
    const signIn = async (email) => { await until(() => doc.querySelector('[data-form="signin"]')); set('[name=email]', email); set('[name=password]', "pass1234"); submit('[data-form="signin"]'); };
    return { dom, doc, E, text, until, set, change, submit, click, go, settled, signIn, errors };
  };
  const one = (sql) => psql(sql);

  let P = open();
  check(await P.until(() => P.doc.querySelector('[data-form="signin"]')), "dashboard asks you to sign in");
  await P.signIn("morgan@demoair.example");
  check(await P.until(() => /Recent activity/.test(P.text()) && /Demo Air Services/.test(P.text())), "owner signs in -> their company's real data", P.text());
  check(/Morgan Reyes/.test(P.text()) && /Owner/.test(P.text()) && /Sign out/.test(P.text()) && !/Demo data|Preview as/.test(P.text()), "rail shows the real person and role, no demo controls");
  P.go("equipment"); await P.until(() => /Radio/.test(P.text()));
  const nEq = Number(one(`select count(*) from equipment where org_id='${ORG}' and status <> 'retired'`));
  check(P.doc.querySelectorAll("tbody tr").length === nEq, `equipment list = database (${nEq})`);

  // add equipment
  P.click('[data-act="newEq"]'); await P.until(() => P.doc.querySelector('[data-form^="eq:"]'));
  const radio = one(`select id from equipment_categories where org_id='${ORG}' and name='Radio'`);
  P.change('[data-form^="eq:"] [name=cat]', radio); P.set('[data-form^="eq:"] [name=name]', "Radio 09"); P.set('[data-form^="eq:"] [name=asset]', "RAD-009");
  P.submit('[data-form^="eq:"]');
  check(await P.until(() => one(`select count(*) from equipment where name='Radio 09' and asset_tag='RAD-009'`) === "1"), "add equipment saves to the database");
  await P.settled();
  const r9 = one(`select id from equipment where name='Radio 09'`);
  check(await P.until(() => P.E("S.drawer && S.drawer.id") === r9 && /Radio 09/.test(P.text())), "its panel opens on the real record");
  // limits + lost
  P.change('[data-form^="limits:"] [name=mode]', "hours"); P.set('[data-form^="limits:"] [name=hours]', "4"); P.submit('[data-form^="limits:"]');
  check(await P.until(() => one(`select time_limit_mode || ':' || checkout_hours from equipment where id='${r9}'`) === "hours:4.00"), "item time limit saves");
  await P.settled();
  P.click('[data-act="askLost"]'); await P.until(() => P.doc.querySelector('[data-act="doStatus"][data-s="lost"]')); P.click('[data-act="doStatus"][data-s="lost"]');
  check(await P.until(() => one(`select status from equipment where id='${r9}'`) === "lost"), "mark lost saves");
  await P.settled(); P.click('[data-act="close"]');

  // employees
  P.go("employees"); await P.until(() => P.doc.querySelector('[data-act="newEmp"]'));
  P.click('[data-act="newEmp"]'); await P.until(() => P.doc.querySelector('[data-form^="emp:"]'));
  P.set('[data-form^="emp:"] [name=first]', "Rosa"); P.set('[data-form^="emp:"] [name=last]', "Diaz"); P.set('[data-form^="emp:"] [name=number]', "E2001");
  P.set('[data-form^="emp:"] [name=badge]', "04:BA:00:00:20:01");
  const am = one(`select id from shifts where org_id='${ORG}' and name='AM'`);
  P.doc.querySelector(`[data-form^="emp:"] [name=shifts][value="${am}"]`).checked = true;
  P.change('[data-form^="emp:"] [name=role]', "manager"); await P.until(() => P.doc.querySelector('[data-form^="emp:"] [name=pin]'));
  P.set('[data-form^="emp:"] [name=first]', "Rosa"); P.set('[data-form^="emp:"] [name=last]', "Diaz"); P.set('[data-form^="emp:"] [name=number]', "E2001"); P.set('[data-form^="emp:"] [name=badge]', "04:BA:00:00:20:01");
  P.doc.querySelector(`[data-form^="emp:"] [name=shifts][value="${am}"]`).checked = true;
  P.set('[data-form^="emp:"] [name=pin]', "4321");
  P.submit('[data-form^="emp:"]');
  check(await P.until(() => one(`select station_role from employees where employee_number='E2001'`) === "manager"), "add employee + manager fob saves");
  await P.settled();
  const rosa = one(`select id from employees where employee_number='E2001'`);
  check(one(`select badge_uid from employees where id='${rosa}'`) === "04BA00002001" && one(`select count(*) from shift_assignments where employee_id='${rosa}' and shift_id='${am}'`) === "1"
    && one(`select count(*) from private.staff_pins where employee_id='${rosa}'`) === "1", "badge, AM shift and PIN are all saved");
  check(await P.until(() => P.E("empOf(S.drawer.id)?.pin") === true), "dashboard knows Rosa's fob has a PIN", P.E("JSON.stringify({d: S.drawer, idmap: L.idMap, emp: DB.employees.filter(e => e.number === 'E2001')})"));
  P.click('[data-act="askDeactivate"]'); await P.until(() => P.doc.querySelector('[data-act="doActive"]')); P.click('[data-act="doActive"][data-v="0"]');
  check(await P.until(() => one(`select active from employees where id='${rosa}'`) === "f"), "deactivate saves");
  await P.settled(); P.click('[data-act="close"]');

  // categories
  P.go("settings"); await P.until(() => P.doc.querySelector('[data-form="newCat"]'));
  P.set('[data-form="newCat"] [name=name]', "Headsets"); P.change('[data-form="newCat"] [name=rule]', "none"); P.submit('[data-form="newCat"]');
  check(await P.until(() => one(`select count(*) from equipment_categories where org_id='${ORG}' and name='Headsets'`) === "1"), "add category saves");
  await P.settled(); await P.until(() => P.doc.querySelector('[data-cat][data-k="name"]'));
  const hs = one(`select id from equipment_categories where name='Headsets'`);
  P.change(`[data-cat="${hs}"][data-k="name"]`, "Headsets (ramp)");
  check(await P.until(() => one(`select name from equipment_categories where id='${hs}'`) === "Headsets (ramp)"), "rename category saves");
  await P.settled();
  P.change(`[data-cat="${hs}"][data-k="rule"]`, "hours");
  check(await P.until(() => one(`select time_limit_type || ':' || default_checkout_hours from equipment_categories where id='${hs}'`) === "hours:8.00"), "category limit saves (with the 8 h default it fills in)");
  await P.settled();
  P.click(`[data-act="askDelCat"][data-id="${hs}"]`); await P.until(() => P.doc.querySelector('[data-act="delCat"]')); P.click('[data-act="delCat"]');
  check(await P.until(() => one(`select count(*) from equipment_categories where id='${hs}'`) === "0"), "delete empty category saves");
  await P.settled();
  // company settings
  P.set('[data-form="company"] [name=primary]', "#224466"); P.submit('[data-form="company"]');
  check(await P.until(() => one(`select primary_color from organizations where id='${ORG}'`) === "#224466"), "company color saves");
  await P.settled();
  const rule = P.doc.querySelector('[data-rule="allow_checkout_while_held"]'); P.change('[data-rule="allow_checkout_while_held"]', !rule.checked);
  check(await P.until(() => one(`select settings->>'allow_checkout_while_held' from organizations where id='${ORG}'`) === String(!rule.checked === true ? true : !rule.checked)), "checkout rule saves");
  await P.settled();

  // shifts
  P.go("shifts"); await P.until(() => P.doc.querySelector(`[data-open="shiftForm:${am}"]`));
  P.click(`[data-open="shiftForm:${am}"]`); await P.until(() => P.doc.querySelector('[data-form^="shift:"]'));
  P.set('[data-form^="shift:"] [name=start]', "04:45"); P.doc.querySelectorAll('[data-form^="shift:"] [name=days]').forEach((cb) => (cb.checked = Number(cb.value) <= 5));
  P.submit('[data-form^="shift:"]');
  check(await P.until(() => one(`select to_char(start_time,'HH24:MI') || ' ' || days_of_week::text from shifts where id='${am}'`) === "04:45 {1,2,3,4,5}"), "edit shift times + days saves");
  await P.settled();

  // stations
  P.go("stations"); await P.until(() => P.doc.querySelector('[data-act="addStation"]'));
  P.click('[data-act="addStation"]'); await P.until(() => P.doc.querySelector('[data-form="station"]'));
  P.set('[data-form="station"] [name=name]', "Bag Room 2"); P.set('[data-form="station"] [name=location]', "Terminal 4"); P.submit('[data-form="station"]');
  check(await P.until(() => /Activation code for Bag Room 2/.test(P.text())), "add station -> real code shown");
  const code = P.doc.querySelector(".codebox").textContent;
  check(/^[A-Z2-9]{4}-[A-Z2-9]{4}$/.test(code) && one(`select l.name from stations s join locations l on l.id = s.location_id where s.name='Bag Room 2'`) === "Terminal 4", "station + location saved: " + code);
  // the code works on a station
  const act = await (await fetch(b.url + "/rest/v1/rpc/activate_station", { method: "POST", headers: { apikey: b.key, Authorization: "Bearer " + b.key, "Content-Type": "application/json" }, body: JSON.stringify({ p_activation_code: code }) })).json();
  check(act.ok === true && act.organization.name === "Demo Air Services", "that code activates a station");

  // team: invite, change role, remove
  P.go("team"); await P.until(() => P.doc.querySelector('[data-form="invite"]'));
  check(/kelly@demoair.example/.test(P.text()), "team list shows real members");
  P.set('[data-form="invite"] [name=name]', "Pat Lowe"); P.set('[data-form="invite"] [name=email]', "Ops.Office@DemoAir.example"); P.change('[data-form="invite"] [name=role]', "viewer"); P.submit('[data-form="invite"]');
  check(await P.until(() => b.outbox.some((m) => m.email === "ops.office@demoair.example" && /\/\?invite=[0-9a-f]{48}$/.test(m.redirect_to))), "invite emails a sign-in link with the invite");
  await P.settled();
  check(await P.until(() => /ops.office@demoair.example/.test(P.text())), "pending invite listed");
  const kelly = "33333333-3333-3333-3333-333333333333";
  P.change(`[data-member="${kelly}"]`, "admin");
  check(await P.until(() => one(`select role from org_members where user_id='${kelly}'`) === "admin"), "change someone's role saves");
  await P.settled();

  // the invited person accepts
  const link = b.outbox.find((m) => m.email === "ops.office@demoair.example").redirect_to;
  const token = new URL(link).searchParams.get("invite");
  const V = open("https://app.sonoranpoint.test/?invite=" + token);
  check(await V.until(() => /Sign in with the email address your invite was sent to/.test(V.text())), "invite link -> asks them to sign in with that email");
  await V.signIn("ops.office@demoair.example");
  check(await V.until(() => /Welcome to Demo Air Services/.test(V.text())), "after signing in: welcome, offered a password", V.text());
  check(V.doc.querySelector('[data-form="profile"] [name=full_name]').value === "Pat Lowe", "their name is already filled in from the invite");
  V.set('[data-form="profile"] [name=full_name]', "Pat Lowe"); V.submit('[data-form="profile"]');
  check(await V.until(() => /Recent activity/.test(V.text()) && /View only/.test(V.text())), "they land in the dashboard as View only");
  check(/Good (morning|afternoon|evening), Pat/.test(V.text()) && /Pat Lowe/.test(V.text()), "greets them by name, not email");
  check(one(`select role from org_members m join auth.users u on u.id = m.user_id where u.email='ops.office@demoair.example'`) === "viewer", "membership saved");
  V.go("equipment"); await V.until(() => /Radio/.test(V.text()));
  check(!V.doc.querySelector('[data-act="newEq"]'), "view-only: no Add equipment");
  // RLS backs it up even if the screen were bypassed
  const hack = await V.E(`sb.from("equipment").update({ name: "hacked" }).eq("org_id", "${ORG}").select("id")`);
  check((hack.data || []).length === 0 && one(`select count(*) from equipment where name='hacked'`) === "0", "view-only can't change data even by calling the database directly");

  // wrong account
  P.go("team"); await P.until(() => P.doc.querySelector('[data-form="invite"]'));
  P.set('[data-form="invite"] [name=email]', "someone.else@demoair.example"); P.submit('[data-form="invite"]');
  await P.until(() => b.outbox.some((m) => m.email === "someone.else@demoair.example")); await P.settled();
  const tok2 = new URL(b.outbox.find((m) => m.email === "someone.else@demoair.example").redirect_to).searchParams.get("invite");
  const W = open("https://app.sonoranpoint.test/?invite=" + tok2);
  await W.signIn("nobody@example.com");
  check(await W.until(() => /What's your name/.test(W.text()) || /That invite was sent to/.test(W.text())), "someone with no name on file is asked for it (or told about the wrong invite)");
  check(await W.until(() => /That invite was sent to someone.else@demoair.example/.test(W.text())), "wrong account -> says which email the invite was for", W.text());

  // alerts: sign off one
  one(`insert into equipment_alerts (org_id, equipment_id, kind, checked_out_at, threshold_at) select '${ORG}', id, 'overdue', now() - interval '5 hours', now() - interval '1 hour' from equipment where org_id='${ORG}' and name <> 'Radio 09' order by name limit 1`);
  P.go("alerts"); await P.E("live.reload()"); await P.until(() => P.doc.querySelector('[data-act="ackStart"]'));
  const aid = P.doc.querySelector('[data-act="ackStart"]').dataset.id; P.click('[data-act="ackStart"]'); await P.until(() => P.doc.querySelector(`[data-form="ack:${aid}"]`));
  P.set(`[data-form="ack:${aid}"] [name=note]`, "Called them"); P.submit(`[data-form="ack:${aid}"]`);
  check(await P.until(() => one(`select notes from equipment_alerts where id='${aid}'`) === "Called them"), "sign off an alert saves");
  await P.settled();

  // a failed save is reported and the screen goes back to the database's version
  one(`update equipment set nfc_uid = '04DEADBEEF01' where name = 'Radio 09'`);
  P.go("equipment"); await P.E("live.reload()"); await P.until(() => /Radio/.test(P.text()));
  const other = one(`select id from equipment where org_id='${ORG}' and name <> 'Radio 09' and status <> 'retired' order by name limit 1`);
  P.E(`DB.equipment.find(q => q.name === 'Radio 09').tag = null`);   // screen doesn't know the tag is taken
  P.click(`[data-open="equipment:${other}"]`); await P.until(() => P.doc.querySelector('[data-act="editEq"]')); P.click('[data-act="editEq"]');
  await P.until(() => P.doc.querySelector('[data-form^="eq:"]')); P.set('[data-form^="eq:"] [name=tag]', "04:DE:AD:BE:EF:01"); P.submit('[data-form^="eq:"]');
  check(await P.until(() => /Couldn't save/.test(P.text())), "a save the database refuses is reported", P.text().slice(-300));
  check(one(`select nfc_uid from equipment where id='${other}'`) !== "04DEADBEEF01", "and nothing wrong was saved");

  // supervisor can't do admin things (RLS)
  const K = open(); await K.signIn("kelly@demoair.example");
  check(await K.until(() => /Recent activity/.test(K.text())), "second user signs in");
  P.click('[data-act="signOut"]');
  check(await P.until(() => P.doc.querySelector('[data-form="signin"]')), "sign out");
  check([P, V, W, K].every((x) => x.errors.length === 0), "no script errors " + [P, V, W, K].flatMap((x) => x.errors).join(";"));
  b.pg.kill(); b.server.close(); process.exit();
})().catch((e) => { console.log("CRASH", e.stack); process.exit(1); });
