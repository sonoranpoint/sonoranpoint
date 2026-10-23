const { JSDOM } = require("jsdom");
const fs = require("fs");
const { start } = require("./backend");
const src = fs.readFileSync(process.argv[2], "utf8");
const check = (c, m, t) => { console.log((c ? "pass  " : "FAIL  ") + m + (c ? "" : "\n      " + String(t ?? "").slice(0, 400))); if (!c) process.exitCode = 1; };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
(async () => {
  const b = await start(); const psql = b.psql;
  const errors = [];
  const dom = new JSDOM("<!doctype html><html><body>" + src + "</body></html>", { runScripts: "dangerously", pretendToBeVisual: true, url: "http://localhost/station.html",
    beforeParse(w) { w.SP_CONFIG = { url: b.url, key: b.key }; w.fetch = fetch; w.crypto.randomUUID ??= () => require("crypto").randomUUID(); } });
  dom.window.addEventListener("error", (e) => errors.push(e.message));
  const doc = dom.window.document, E = (s) => dom.window.eval(s);
  const text = () => doc.querySelector("#screen").textContent.replace(/\s+/g, " ");
  const until = async (fn, ms = 8000) => { const t0 = Date.now(); while (Date.now() - t0 < ms) { try { if (fn()) return true; } catch {} await sleep(60); } return false; };
  await sleep(300);
  check(E("KIOSK") && doc.documentElement.classList.contains("kiosk"), "on the Pi: full-screen station, no test panel");
  check(E("link() !== demo"), "talks to the real server, not the demo");
  E("piDevice.status = async () => ({ ssid: null, wired: true }); piDevice.scan = async () => [];");
  E("wizStart(); S.wiz.step = 'code'; S.wiz.code = 'DEMO0001'"); await E("activate()");
  check(await until(() => E("!!S.saved.deviceKey")), "activation code works against the server", text());
  check(E("S.saved.config.organization.name") === "Demo Air Services", "loads the company's name and colors from the server");
  E("finishSetup()"); await sleep(200);
  await E("refreshData(true)"); await sleep(300);
  check(E("S.saved.cache.employees.length") > 0, "downloads badges and tags for offline use");
  const badge = psql("select badge_uid from employees where first_name='Alex'"), tag = psql("select nfc_uid from equipment where status='available' and nfc_uid is not null order by name limit 1");
  E(`handleTag('${badge}')`); await sleep(500); E(`handleTag('${tag}')`);
  check(await until(() => psql(`select count(*) from transactions t join equipment q on q.id = t.equipment_id where q.nfc_uid='${tag}' and t.action='checkout' and t.source='station'`) === "1"), "a badge + item tap is recorded in the database");
  check(await until(() => /Checked out/i.test(text())), "station shows the checkout");
  psql("update organizations set status='paused' where slug='demo'");
  await E("call('station_heartbeat', { p_device_key: S.saved.deviceKey })").catch(() => {});
  check(await until(() => /This station is paused/.test(text())), "pausing the company from your console pauses the station");
  psql("update organizations set status='active' where slug='demo'");
  await E("call('station_heartbeat', { p_device_key: S.saved.deviceKey })").catch(() => {});
  check(await until(() => !/paused/i.test(text())), "and it comes back on its own");
  // Report a problem against the real database; a blocking one stops the next checkout
  check(E("reasons().length") === 4, "the station gets the company's problem reasons");
  E("endSession()"); await sleep(100);
  E(`handleTag('${badge}')`); await sleep(400); E("$('#reportBtn').click()"); await sleep(100); E(`handleTag('${tag}')`); await sleep(200);
  E("$('.rbtn[data-reason]').click()");
  check(await until(() => psql(`select count(*) from equipment_problems p join equipment q on q.id = p.equipment_id where q.nfc_uid='${tag}' and p.reason='Damaged' and p.cleared_at is null`) === "1"),
    "reporting it damaged at the station is saved in the database");
  check(await until(() => /Problem reported/.test(text())), "station confirms the report");
  E(`handleTag('${tag}')`); await until(() => /Returned/.test(text()));
  E("$('#doneBtn').click()"); check(await until(() => /Any problems with what you returned/.test(text())), "after a return the station asks about problems");
  E("$('#ckYes').click()"); await sleep(100); E("$('.ckchip[data-ck-reason]:nth-child(2)').click()"); await sleep(50); E("$('#ckSend').click()");
  check(await until(() => psql(`select count(*) from equipment_problems p join equipment q on q.id = p.equipment_id where q.nfc_uid='${tag}' and p.cleared_at is null`) === "2")
        && await until(() => /Checked in/.test(text())), "reporting from the returns screen is saved, then the green Checked in screen", text());
  const jordan = psql("select badge_uid from employees where first_name='Jordan'");
  E("endSummary()"); await sleep(100); E(`handleTag('${jordan}')`); await sleep(400); E(`handleTag('${tag}')`);
  check(await until(() => /Checked out/.test(text()) && /Look it over before you use it/.test(text())), "a damaged item can still be checked out, with a heads-up", text());
  check(await until(() => psql(`select count(*) from transactions t join equipment q on q.id = t.equipment_id where q.nfc_uid='${tag}' and 'reported_problem' = any(t.flags)`) === "1"), "and the checkout is flagged in the database");
  // Add an item at the station with its NFC tag and its barcode (live)
  E("endSummary && endSummary(); S.session && endSession()"); await sleep(200);
  E("handleTag('04BA0000000A')"); await sleep(500);
  E("$('#staffBtn').click()"); await sleep(150);
  for (const d of "2468") { E(`$('#screen [data-pin="${d}"]').click()`); await sleep(10); }
  E(`$('#screen [data-pin="OK"]').click()`);
  check(await until(() => E("S.screen") === "staff" && /Add employee/.test(text())), "manager fob + PIN opens the admin menu (live)", text());
  E(`$('#screen [data-act="addEq"]').click()`); await sleep(100);
  E(`$('#screen [data-pick^="cat:"]').click()`); await sleep(100); E(`$('#screen [data-act="primary"]').click()`); await sleep(100);
  const nm = E("S.staff.form.name");
  E("handleTag(scanToUid('LIVE-BC-1'))"); await sleep(150); E("handleTag('04DE0000BC01')");
  check(await until(() => psql(`select nfc_uid || '|' || barcode from equipment where name = '${nm}'`) === "04DE0000BC01|LIVE-BC-1" && /Added/.test(text())),
        "tag + barcode: saved with both on the server (live)", text());
  check(errors.length === 0, "no script errors " + errors.join(";"));
  b.pg.kill(); b.server.close(); process.exit();
})().catch((e) => { console.log("CRASH", e.stack); process.exit(1); });
