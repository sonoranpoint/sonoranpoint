const { JSDOM } = require("jsdom");
const fs = require("fs");
const { start } = require("./backend");
const UMD = fs.readFileSync(require.resolve("@supabase/supabase-js/dist/umd/supabase.js"), "utf8");
const src = fs.readFileSync(process.argv[2], "utf8");
const check = (c, m, t) => { console.log((c ? "pass  " : "FAIL  ") + m + (c ? "" : "\n      " + (t ?? "").slice(0, 400))); if (!c) process.exitCode = 1; };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
(async () => {
  const b = await start();
  const open = (url = "https://console.sonoranpoint.test/") => {
    const errors = [];
    const dom = new JSDOM("<!doctype html><html><body>" + src + "</body></html>", { runScripts: "dangerously", pretendToBeVisual: true, url,
      beforeParse(w) { w.SP_CONFIG = { url: b.url, key: b.key, appUrl: "https://app.sonoranpoint.com" }; w.fetch = fetch; w.Headers = Headers; w.Request = Request; w.Response = Response;
        w.matchMedia = () => ({ matches: false, addEventListener() {} }); w.scrollTo = () => {}; Object.defineProperty(w, "crypto", { value: require("crypto").webcrypto });
        w.supabase = require("@supabase/supabase-js"); } });
    dom.window.addEventListener("error", (e) => errors.push(e.message));
    const doc = dom.window.document, E = (s) => dom.window.eval(s);
    const text = () => (doc.querySelector("#app").textContent + " " + doc.querySelector("#layer").textContent).replace(/\s+/g, " ");
    const until = async (fn, ms = 6000) => { const t0 = Date.now(); while (Date.now() - t0 < ms) { try { if (fn()) return true; } catch {} await sleep(50); } return false; };
    const type = (sel, v) => { const el = doc.querySelector(sel); el.value = v; el.dispatchEvent(new dom.window.Event("input", { bubbles: true })); };
    const submit = (sel) => doc.querySelector(sel).dispatchEvent(new dom.window.Event("submit", { bubbles: true, cancelable: true }));
    const click = (sel) => { const el = doc.querySelector(sel); if (!el) throw new Error("missing " + sel + " :: " + text().slice(0, 200)); el.click(); };
    return { dom, doc, E, text, until, type, submit, click, errors };
  };
  // not signed in -> sign-in screen; customer can't use it
  let P = open();
  check(await P.until(() => /Sign in/.test(P.text()) && P.doc.querySelector('[data-form="signin"]')), "live console asks you to sign in");
  P.type('[name=email]', "morgan@demoair.example"); P.type('[name=password]', "wrong"); P.submit('[data-form="signin"]');
  check(await P.until(() => /don't match/.test(P.text())), "wrong password -> clear message");
  P.type('[name=email]', "morgan@demoair.example"); P.type('[name=password]', "pass1234"); P.submit('[data-form="signin"]');
  check(await P.until(() => /isn't on the team/.test(P.text())), "a customer's account is turned away");
  // operator
  P = open();
  await P.until(() => P.doc.querySelector('[data-form="signin"]'));
  P.type('[name=email]', "g.ryan@sonoranpoint.com"); P.type('[name=password]', "pass1234"); P.submit('[data-form="signin"]');
  check(await P.until(() => /Demo Air Services/.test(P.text()) && /Customers/.test(P.text())), "operator signs in and sees real customers", P.text());
  check(/Dez/.test(P.text()) && /Sign out/.test(P.text()) && !/Demo data/.test(P.text()), "shows who's signed in, no demo label", P.E("JSON.stringify({ready: S.ready, view: AUTH.view, route: S.route})") + " || " + P.doc.querySelector("#app").textContent.slice(0, 300));
  // create a customer
  P.dom.window.location.hash = "new"; await P.until(() => P.doc.querySelector('[data-new="name"]'));
  P.type('[data-new="name"]', "Cactus Air Logistics"); P.type('[data-new="owner_email"]', "Boss@CactusAir.example");
  P.click('[data-act="addStationRow"]'); await sleep(50); P.type('[data-station="1"]', "Ramp Office");
  P.submit('[data-form="new"]');
  check(await P.until(() => /Cactus Air Logistics is set up/.test(P.text())), "create customer in the real database", P.text());
  const codes = [...P.doc.querySelectorAll(".shipcard .codebox")].map((x) => x.textContent);
  check(codes.length === 2 && codes.every((c) => /^[A-Z2-9]{4}-[A-Z2-9]{4}$/.test(c)), "two real activation codes " + codes.join(" "));
  const mail = b.outbox.find((m) => m.email === "boss@cactusair.example");
  check(mail && /^https:\/\/app\.sonoranpoint\.com\/\?invite=[0-9a-f]{48}$/.test(mail.redirect_to), "owner gets an email with the invite link: " + mail?.redirect_to);
  check(/Emailed to boss@cactusair.example/.test(P.text()), "screen says it was emailed");
  const org = b.psql("select id from organizations where slug = 'cactus-air-logistics'");
  check(org && b.psql(`select count(*) from stations where org_id = '${org}'`) === "2", "company + 2 stations exist in the database");
  // customer page loads detail
  P.dom.window.location.hash = "customer/" + org;
  check(await P.until(() => /Owner invite sent/.test(P.text()) && /Ramp Office/.test(P.text())), "customer page loads stations and the pending invite", P.text());
  // pause / resume
  P.click('[data-act="askPause"]'); await sleep(30); P.click('[data-act="doPause"]');
  check(await P.until(() => b.psql(`select status from organizations where id = '${org}'`) === "paused" && /This station is paused/.test(P.text())), "pause saves to the database");
  P.click('[data-act="resume"]');
  check(await P.until(() => b.psql(`select status from organizations where id = '${org}'`) === "active"), "resume saves");
  // look
  P.type('[data-form="brand"] [name=accent]', "#cc3300"); P.submit('[data-form="brand"]');
  check(await P.until(() => b.psql(`select accent_color from organizations where id = '${org}'`) === "#CC3300"), "look saves");
  // account (notes are private); wait for the look save to finish first
  await P.until(() => !P.E("S.busy"));
  P.doc.querySelector('[data-form="account"] [name=notes]').value = "Pilot at PHX"; P.doc.querySelector('[data-form="account"] [name=station_limit]').value = "3";
  P.submit('[data-form="account"]');
  check(await P.until(() => b.psql(`select notes from private.customer_notes where org_id = '${org}'`) === "Pilot at PHX" && b.psql(`select station_limit from organizations where id = '${org}'`) === "3"), "account + private notes save", P.E("JSON.stringify(S.formErr)") + " " + b.psql(`select coalesce(notes,'-') from private.customer_notes where org_id = '${org}'`) + " " + b.psql(`select station_limit from organizations where id = '${org}'`));
  // add station, new code, disconnect
  P.type('[data-form="addStation"] [name=name]', "Bag Room"); P.submit('[data-form="addStation"]');
  check(await P.until(() => /Activation code for Bag Room/.test(P.text())), "add a station -> code");
  const sid = b.psql(`select id from stations where org_id = '${org}' and name = 'Ramp Office'`);
  P.click(`[data-act="askCode"][data-id="${sid}"]`); await sleep(30); P.click(`[data-act="doCode"][data-id="${sid}"]`);
  check(await P.until(() => /Activation code for Ramp Office/.test(P.text())), "new code for a station");
  P.click(`[data-act="askRevoke"][data-id="${sid}"]`); await sleep(30); P.click(`[data-act="doRevoke"][data-id="${sid}"]`);
  check(await P.until(() => b.psql(`select revoked_at is not null from stations where id = '${sid}'`) === "t" && /Disconnected.*Ramp Office/.test(P.text()) && !!P.doc.querySelector(`[data-act="askRemove"][data-id="${sid}"]`)), "disconnect a station");
  P.click(`[data-act="askRemove"][data-id="${sid}"]`); await sleep(30); P.click(`[data-act="doRemove"][data-id="${sid}"]`);
  check(await P.until(() => b.psql(`select removed_at is not null from stations where id = '${sid}'`) === "t" && !P.doc.querySelector(`[data-id="${sid}"]`)), "remove it for good (live)");
  // resend invite
  P.type('[data-form="invite"] [name=email]', "second@cactusair.example"); P.submit('[data-form="invite"]');
  check(await P.until(() => /Invite for second@cactusair.example/.test(P.text()) && b.outbox.some((m) => m.email === "second@cactusair.example")), "invite another owner (email sent)");
  // fleet + log
  P.dom.window.location.hash = "fleet"; await sleep(100); P.click('[data-seg="fleet:all"]'); await sleep(50);
  check(/Bag Room/.test(P.text()) && /Cactus Air Logistics/.test(P.text()), "fleet shows the real stations");
  P.dom.window.location.hash = "log"; await sleep(100);
  check(/created customer/.test(P.text()) && /status: paused/.test(P.text()) && /Dez/.test(P.text()), "your activity log from the database", P.text());
  check(/Station limit: 3/.test(P.text()) && /Notes changed/.test(P.text()) && !/T23:59/.test(P.text()), "activity details are readable", P.text().slice(0, 1500));
  // team
  P.dom.window.location.hash = "team";
  check(await P.until(() => /Invite someone/.test(P.text()) && /Dez/.test(P.text()) && /\(you\)/.test(P.text())), "team page for the owner", P.text());
  P.type('[data-form="opinvite"] [name=name]', "Casey"); P.type('[data-form="opinvite"] [name=email]', "Casey@SonoranPoint.example"); P.submit('[data-form="opinvite"]');
  const om = await P.until(() => b.outbox.some((m) => m.email === "casey@sonoranpoint.example"));
  const omail = b.outbox.find((m) => m.email === "casey@sonoranpoint.example");
  check(om && /^https:\/\/console\.sonoranpoint\.test\/\?opinvite=[0-9a-f]{48}$/.test(omail.redirect_to), "operator invite emailed with a console link: " + omail?.redirect_to);
  check(await P.until(() => /Invited as Operator/.test(P.text()) && /Invite emailed to casey/.test(P.text())), "pending invite shows", P.text());
  check(b.psql("select raw_user_meta_data->>'full_name' from auth.users where email = 'casey@sonoranpoint.example'") === "Casey", "their name goes with the invite");
  // Casey opens the link
  const Q = open(omail.redirect_to);
  await Q.until(() => Q.doc.querySelector('[data-form="signin"]'));
  Q.type('[name=email]', "casey@sonoranpoint.example"); Q.type('[name=password]', "pass1234"); Q.submit('[data-form="signin"]');
  check(await Q.until(() => /Demo Air Services/.test(Q.text()) && /Welcome, Casey/.test(Q.text())), "invited person signs in and is in", Q.text());
  check(/Casey/.test(Q.doc.querySelector(".me").textContent) && /Operator/.test(Q.doc.querySelector(".me").textContent) && !/opinvite/.test(Q.dom.window.location.href), "rail shows their name and role; link cleaned up");
  Q.dom.window.location.hash = "team";
  check(await Q.until(() => Q.doc.querySelector('[data-form="myname"]') && !/Invite someone/.test(Q.text()) && !Q.doc.querySelector("[data-oprole]")), "operators can't invite or change roles");
  Q.type('[data-form="myname"] [name=name]', "Casey Nguyen"); Q.submit('[data-form="myname"]');
  check(await Q.until(() => b.psql("select name from private.platform_operators po join auth.users u on u.id = po.user_id where u.email = 'casey@sonoranpoint.example'") === "Casey Nguyen"
    && /Casey Nguyen/.test(Q.doc.querySelector(".me").textContent)), "operator sets their own name");
  const R = open(omail.redirect_to);   // used link
  await R.until(() => R.doc.querySelector('[data-form="signin"]'));
  R.type('[name=email]', "nobody@example.com"); R.type('[name=password]', "pass1234"); R.submit('[data-form="signin"]');
  check(await R.until(() => /already been used/.test(R.text())), "a used invite link is refused", R.text());
  // owner changes role and removes
  P.dom.window.location.hash = "customers"; await sleep(50); P.dom.window.location.hash = "team";
  await P.E("live.refresh()"); P.E("render()");
  check(await P.until(() => /Casey Nguyen/.test(P.text())), "owner sees the new name", P.text());
  const cid = b.psql("select id from auth.users where email = 'casey@sonoranpoint.example'");
  const sel = P.doc.querySelector(`[data-oprole="${cid}"]`); sel.value = "owner"; sel.dispatchEvent(new P.dom.window.Event("change", { bubbles: true }));
  check(await P.until(() => b.psql(`select role from private.platform_operators where user_id = '${cid}'`) === "owner"), "owner promotes someone");
  P.click(`[data-act="askRmOp"][data-id="${cid}"]`); await sleep(30); P.click(`[data-act="doRmOp"][data-id="${cid}"]`);
  check(await P.until(() => b.psql(`select count(*) from private.platform_operators where user_id = '${cid}'`) === "0" && !/Casey Nguyen/.test(P.doc.querySelector(".list").textContent)), "owner removes someone");
  P.dom.window.location.hash = "log"; await sleep(150);
  check(/invited operator/.test(P.text()) && /removed operator/.test(P.text()) && /casey@sonoranpoint.example, as Operator/.test(P.text()), "team changes in the activity log", P.text().slice(0, 800));
  check(Q.errors.length === 0 && R.errors.length === 0, "no script errors (invitee) " + Q.errors.join(";"));
  // hardware
  P.dom.window.location.hash = "hardware";
  check(await P.until(() => /No hardware yet/.test(P.text())), "hardware page (empty)", P.text().slice(0, 300));
  P.dom.window.location.hash = "unit/new"; await P.until(() => P.doc.querySelector('[data-form="hwnew"]'));
  P.type('[data-form="hwnew"] [name=pi_serial]', "10000000cafe0001"); P.submit('[data-form="hwnew"]');
  check(await P.until(() => /SP-0001/.test(P.text()) && /added this unit/.test(P.text())), "add a unit to the database", P.text().slice(0, 400));
  const hid = b.psql("select id from private.hardware_units where serial = 'SP-0001'");
  const bag = b.psql(`select id from stations where org_id = '${org}' and name = 'Bag Room'`);
  const cs = P.doc.querySelector('[data-form="hwship"] [name=org_id]'); cs.value = org; cs.dispatchEvent(new P.dom.window.Event("change", { bubbles: true })); await sleep(30);
  P.doc.querySelector('[data-form="hwship"] [name=station_id]').value = bag;
  P.type('[data-form="hwship"] [name=tracking]', "1Z999AA10000000002"); P.submit('[data-form="hwship"]');
  check(await P.until(() => b.psql(`select status || '|' || station_id || '|' || tracking from private.hardware_units where id = '${hid}'`) === `shipped|${bag}|1Z999AA10000000002`
    && /marked it shipped/.test(P.text())), "ship it to a station", P.text().slice(0, 600));
  // the customer activates the Bag Room station with its code
  b.psql(`update stations set activated_at = now() where id = '${bag}'`);
  await P.E("live.refresh()"); P.E("render()");
  check(await P.until(() => /Installed/.test(P.text()) && /Automatic/.test(P.text())), "activation marks it installed", P.text().slice(0, 600));
  P.dom.window.location.hash = "customer/" + org;
  check(await P.until(() => /SP-0001/.test(P.text())), "customer page shows the unit");
  P.dom.window.location.hash = "log"; await sleep(150);
  check(/hardware shipped/.test(P.text()) && /SP-0001/.test(P.text()), "shipping shows in activity");
  // sign out
  P.click('[data-act="signOut"]');
  check(await P.until(() => P.doc.querySelector('[data-form="signin"]')), "sign out");
  check(P.errors.length === 0, "no script errors " + P.errors.join(";"));
  b.pg.kill(); b.server.close(); process.exit();
})();
