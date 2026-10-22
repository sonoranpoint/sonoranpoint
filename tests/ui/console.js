const { JSDOM } = require("jsdom");
const fs = require("fs");
const src = fs.readFileSync(process.argv[2], "utf8");
const errors = [];
const dom = new JSDOM("<!doctype html><html><body>" + src + "</body></html>", { runScripts: "dangerously", pretendToBeVisual: true, url: "https://example.test/",
  beforeParse(w) { w.matchMedia = () => ({ matches: false, addEventListener() {} }); w.scrollTo = () => {}; w.print = () => { w.__printed = true; };
    Object.defineProperty(w, "crypto", { value: require("crypto").webcrypto }); } });
dom.window.addEventListener("error", (e) => errors.push(e.message + " @" + e.lineno));
const E = (s) => dom.window.eval(s), doc = dom.window.document;
const check = (c, m, t) => { console.log((c ? "pass  " : "FAIL  ") + m + (c ? "" : "\n      " + (t || page().slice(0, 300)))); if (!c) process.exitCode = 1; };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const go = async (r) => { dom.window.location.hash = r; await sleep(30); };
const click = async (sel) => { const el = doc.querySelector(sel); if (!el) throw new Error("missing " + sel + " :: " + page().slice(0, 200)); el.click(); await sleep(15); };
const page = () => doc.querySelector(".main").textContent.replace(/\s+/g, " ");
const type = async (sel, v) => { const el = doc.querySelector(sel); el.value = v; el.dispatchEvent(new dom.window.Event("input", { bubbles: true })); await sleep(10); };
const submit = async (sel) => { doc.querySelector(sel).dispatchEvent(new dom.window.Event("submit", { bubbles: true, cancelable: true })); await sleep(20); };
const api_set = async (id) => { E(`api.updateCustomer('${id}', { logo_dark_url: 'data:image/png;base64,AAA' }); render()`); await sleep(30); };
(async () => {
  await sleep(100);
  check(/Customers/.test(page()) && /Demo Air Services/.test(page()) && /Copper State Cargo/.test(page()), "customer list");
  check(/Needs attention/.test(page()) && /Bag Room offline/.test(page()) && /Trial 5 days left/.test(page()) && /Commissary: activation code expired/.test(page()), "needs attention: offline station, trial ending, expired code");
  check(/Stations online/.test(page()) && /Trials ending soon/.test(page()) && /Owner invites/.test(page()) && /System health/.test(page()) && /New customers/.test(page()), "overview cards, health and charts");
  await click("tr[data-preview]"); check(/Quick actions/.test(doc.querySelector("#layer").textContent) && /Open customer/.test(doc.querySelector("#layer").textContent), "clicking a customer opens its preview");
  await click('[data-act="pvAskPause"]'); await click('[data-act="pvPause"]'); const pcust = E("S.preview");
  check(E(`custOf('${pcust}').status`) === "paused" && /Resume account/.test(doc.querySelector("#layer").textContent), "pause from the preview");
  await click('[data-act="pvResume"]'); check(E(`custOf('${pcust}').status`) === "active", "and resume");
  await click('[data-act="closePreview"]'); check(!doc.querySelector(".preview"), "close the preview");
  const gs = doc.querySelector("#gsearch"); gs.value = "bag"; gs.dispatchEvent(new dom.window.Event("input", { bubbles: true })); await sleep(10);
  check(/Stations/.test(doc.querySelector("#gsResults").textContent) && /Bag Room/.test(doc.querySelector("#gsResults").textContent), "top bar search finds stations");
  gs.value = "SP-0009"; gs.dispatchEvent(new dom.window.Event("input", { bubbles: true })); await sleep(10);
  check(/Hardware/.test(doc.querySelector("#gsResults").textContent), "and hardware");
  gs.value = ""; gs.dispatchEvent(new dom.window.Event("input", { bubbles: true })); await sleep(10);
  check(doc.documentElement.dataset.theme === "light", "light by default");
  await click('[data-seg="status:paused"]');
  check(/Mesa Ramp/.test(page()) && !/Copper State/.test(page().split("Every company")[1]), "filter paused");
  await click('[data-seg="status:all"]'); await type('[data-f="q"]', "tasha");
  check(/Desert Ground/.test(page().split("Every company")[1]) && !/Copper/.test(page().split("Every company")[1]), "search by contact");
  await type('[data-f="q"]', "");

  // new customer
  await go("new");
  check(/New customer/.test(page()) && doc.querySelector(".pv"), "new customer form with preview");
  await type('[data-new="name"]', "Cactus Air Logistics");
  check(doc.querySelector('[data-new="slug"]').value === "cactus-air-logistics" && /Cactus Air Logistics/.test(doc.querySelector(".pv").textContent), "short ID and preview follow the name");
  await type('[data-new="primary"]', "#225533");
  check(/#225533/i.test(doc.querySelector(".pv-top").getAttribute("style")), "preview takes the color");
  await type('[data-new="t_equipment"]', "Radio");
  check(/Radio/.test(doc.querySelector(".pv-steps").textContent), "preview uses their word");
  await submit('[data-form="new"]');
  check(/owner's email/.test(page()), "needs owner email");
  await type('[data-new="slug"]', "demo"); await type('[data-new="owner_email"]', "Boss@CactusAir.example");
  await submit('[data-form="new"]');
  check(/already used/.test(page()), "short ID taken");
  await type('[data-new="slug"]', "cactusair");
  await click('[data-act="addStationRow"]'); await type('[data-station="1"]', "Ramp Office");
  await submit('[data-form="new"]');
  check(/Cactus Air Logistics is set up/.test(page()) && doc.querySelectorAll(".shipcard").length === 2, "created: one card per station");
  const codes = [...doc.querySelectorAll(".shipcard .codebox")].map((x) => x.textContent);
  check(codes.every((c) => /^[A-Z2-9]{4}-[A-Z2-9]{4}$/.test(c)) && codes[0] !== codes[1], "each station has its own code " + codes.join(" "));
  check(/boss@cactusair.example/.test(page()) && /app\.sonoranpoint\.com\/\?invite=[0-9a-f]{48}/.test(page()), "owner invite link shown, in the form the dashboard reads (?invite=)");
  check(/Blank admin tag/.test(page()) && /Quick-start card/.test(page()), "packing checklist");
  await click('[data-act="print"]'); check(dom.window.__printed, "print setup sheets");
  const id = E("DB.customers.find(c => c.slug === 'cactusair').id");
  check(E(`JSON.stringify(custOf('${id}').terms.equipment)`) === '"Radio"' && E(`custOf('${id}').status`) === "trial" && E(`custOf('${id}').modules.includes('shifts')`), "saved with terms, trial, modules");
  await click('a[href="#new"]');
  check(/New customer/.test(page()) && doc.querySelector('[data-new="name"]').value === "", "New customer again gives a blank form");

  // customer page
  await go("customer/" + id);
  check(/Waiting for setup/.test(page()) && /Owner invite sent/.test(page()), "customer page: stations waiting, invite pending");
  await type('[data-form="addStation"] [name=name]', "Bag Room"); await submit('[data-form="addStation"]');
  check(/Activation code for Bag Room/.test(page()) && E(`custOf('${id}').stations.length`) === 3, "add a station -> code shown");
  const sid = E(`custOf('${id}').stations[0].id`); const old = E(`custOf('${id}').stations[0].code`);
  await click(`[data-act="askCode"][data-id="${sid}"]`); await click(`[data-act="doCode"][data-id="${sid}"]`);
  check(E(`custOf('${id}').stations[0].code`) !== old, "new code for a station");
  await click(`[data-act="askRevoke"][data-id="${sid}"]`); await click(`[data-act="doRevoke"][data-id="${sid}"]`);
  check(!!doc.querySelector(`[data-act="askRemove"][data-id="${sid}"]`), "disconnect a station");
  await type('[data-form="invite"] [name=email]', "nope"); await submit('[data-form="invite"]');
  check(/full email/.test(page()), "bad invite email");
  await type('[data-form="invite"] [name=email]', "second@cactusair.example"); await submit('[data-form="invite"]');
  check(/Invite for second@cactusair.example/.test(page()), "invite another owner");
  // brand
  await type('[data-form="brand"] [name=primary]', "#FF0000");
  check(/#FF0000/i.test(doc.querySelector('[data-form="brand"] .pv-top').getAttribute("style")), "brand preview updates live");
  await type('[data-form="brand"] [name=accent]', "red"); await submit('[data-form="brand"]');
  check(/Colors must look like/.test(page()), "bad color refused");
  await type('[data-form="brand"] [name=accent]', "#cc3300"); await submit('[data-form="brand"]');
  check(E(`custOf('${id}').accent`) === "#CC3300", "look saved");
  // account
  doc.querySelector('[data-form="account"] [name=status]').value = "active"; doc.querySelector('[data-form="account"] [name=station_limit]').value = "2";
  await submit('[data-form="account"]');
  check(E(`custOf('${id}').status`) === "active" && E(`custOf('${id}').station_limit`) === 2 && /2 of 2 allowed/.test(page()) || /of 2 allowed/.test(page()), "account saved (status, limit)");
  // modules
  const mod = doc.querySelector('[data-mod="shifts"]'); mod.checked = false; mod.dispatchEvent(new dom.window.Event("change", { bubbles: true })); await sleep(20);
  check(!E(`custOf('${id}').modules.includes('shifts')`), "module off");
  // pause / resume
  await click('[data-act="askPause"]'); await click('[data-act="doPause"]');
  check(E(`custOf('${id}').status`) === "paused" && /This station is paused/.test(page()), "pause account (explains what happens)");
  await click('[data-act="resume"]');
  check(E(`custOf('${id}').status`) === "active", "resume");
  // fleet + log
  await go("fleet");
  check(/Needs a look/.test(page()) && /Bag Room/.test(page()) && /Commissary/.test(page()), "fleet: problems first");
  await click('[data-seg="fleet:all"]');
  check(doc.querySelectorAll("tbody tr:not(.grp)").length === E("api.fleet(true).length"), "fleet: All lists every station, disconnected ones too");
  check(doc.querySelectorAll("tbody tr.grp").length === new Set(E("api.fleet(true).map(s => s.org)")).size, "stations are grouped under each customer");
  doc.querySelector("tbody tr:not(.grp)").click(); await sleep(30);
  check(E("!!S.preview"), "clicking a station opens its customer's quick view");
  E("S.preview = null; renderLayer()");
  await go("log");
  check(/created customer/.test(page()) && /Cactus Air Logistics/.test(page()) && /status: paused/.test(page()), "activity log");
  // customer page polish
  const demoId = E("DB.customers.find(c => c.slug === 'demo').id");
  await go("customer/" + demoId);
  check(/Morgan Reyes/.test(doc.querySelector(".main").textContent) && /morgan@demoair.example/.test(doc.querySelector(".main").textContent), "their team shows names with emails");
  check(doc.querySelector("#trialEnds").hidden, "no trial date box for a paying customer");
  const stSel = doc.querySelector('[data-form="account"] [name=status]'); stSel.value = "trial"; stSel.dispatchEvent(new dom.window.Event("change", { bubbles: true })); await sleep(10);
  check(!doc.querySelector("#trialEnds").hidden, "it appears when you switch them to trial");
  check(doc.querySelector("#logoFile") && !doc.querySelector(".pv-logo img") && /Copper State Cargo|Demo Air Services/.test(doc.querySelector(".pv-logo").textContent), "logo upload on the customer page; preview shows their name until they have a logo");
  // team
  await go("team");
  check(/Jordan Ellis/.test(page()) && /\(you\)/.test(page()) && /Invited as Operator/.test(page()) && /Invite someone/.test(page()), "team page (demo)");
  await type('[data-form="opinvite"] [name=email]', "nope"); await submit('[data-form="opinvite"]');
  check(/full email address/.test(page()), "bad invite email");
  await type('[data-form="opinvite"] [name=name]', "Riley"); await type('[data-form="opinvite"] [name=email]', "riley@sonoranpoint.com"); await submit('[data-form="opinvite"]');
  check(/Riley/.test(page()) && /opinvite=[0-9a-f]{48}/.test(page()), "invite shows with its link");
  const me = doc.querySelector('[data-oprole="op-me"]'); check(!me, "can't change your own role");
  await click('[data-act="askRmOp"][data-id="op-2"]'); await click('[data-act="doRmOp"][data-id="op-2"]');
  check(!/Jordan Ellis/.test(page().split("Invite someone")[0]), "remove an operator");
  await type('[data-form="myname"] [name=name]', "Dez Ryan"); await submit('[data-form="myname"]');
  check(/Dez Ryan/.test(doc.querySelector(".me").textContent) && /Owner/.test(doc.querySelector(".me").textContent), "rename yourself; rail shows name and role");
  await go("log");
  check(/Dez removed operator/.test(page()) && /riley@sonoranpoint.com, as Operator/.test(page()), "team changes logged", page().slice(0, 500));
  // hardware
  await go("hardware");
  check(/In stock/.test(page()) && /SP-0009/.test(page()) && /Sky Harbor Catering/.test(page()), "hardware list (demo)");
  await click('[data-seg="hw:fix"]'); check(/In repair/.test(page()) && !/SP-0009/.test(page()), "filter repairs");
  await click('[data-seg="hw:all"]'); await type('[data-f="hwq"]', "794698123499"); check(/SP-0009/.test(page()) && !/SP-0002/.test(page()), "search by tracking");
  await type('[data-f="hwq"]', "");
  await go("unit/new"); await type('[data-form="hwnew"] [name=pi_serial]', "10000000feedbeef"); await submit('[data-form="hwnew"]'); await sleep(40);
  const nid = E("DB.hw[0].id"); check(E("DB.hw[0].serial") === "SP-0015" && dom.window.location.hash === "#unit/" + nid, "add unit gets next ID and opens it", E("DB.hw[0].serial"));
  await sleep(40); await click('[data-act="hwStatus"][data-status="ready"]'); check(E("DB.hw[0].status") === "ready", "mark in stock");
  const cat = E("DB.customers.find(c => c.slug === 'copperstate').id");
  const csel = doc.querySelector('[data-form="hwship"] [name=org_id]'); csel.value = cat; csel.dispatchEvent(new dom.window.Event("change", { bubbles: true })); await sleep(20);
  check(doc.querySelectorAll('[data-form="hwship"] [name=station_id] option').length === 4 && /Rafael Montoya/.test(doc.querySelector('[data-form="hwship"] [name=ship_to]').value), "picking a customer lists their stations and fills ship-to");
  doc.querySelector('[data-form="hwship"] [name=station_id]').value = E("custOf('" + cat + "').stations[2].id");
  await type('[data-form="hwship"] [name=tracking]', "1Z999AA10000000001"); await submit('[data-form="hwship"]'); await sleep(20);
  check(E("DB.hw[0].status") === "shipped" && E("DB.hw[0].org_id") === cat && E("DB.hw[0].carrier") === "UPS", "ship to a customer's station");
  check(/ups\.com\/track\?tracknum=1Z999AA10000000001/.test(doc.querySelector(".main").innerHTML) && /marked it shipped/.test(page()), "tracking link and history");
  await type('[data-form="hwnote"] [name=note]', "Swapped the reader"); await submit('[data-form="hwnote"]'); check(/Swapped the reader/.test(page()), "add a note");
  await go("customer/" + cat); check(/SP-0015/.test(page()) && /Hardware/.test(page()), "customer page lists their hardware");
  await go("fleet"); await click('[data-seg="fleet:all"]'); check(doc.querySelectorAll('a[href^="#unit/"]').length >= 9, "stations page links each unit");
  await go("unit/" + nid); await click('[data-act="askHwDelete"]'); await click('[data-act="hwDelete"]'); await sleep(40);
  check(!E("DB.hw.some(u => u.serial === 'SP-0015')"), "owner deletes a mistake");
  // Contracts on the customer page
  dom.window.location.hash = "customer/" + E("DB.customers.find(c => c.name === 'Demo Air Services').id"); await sleep(60);
  check([...doc.querySelectorAll("tr.grp")].map((r) => r.textContent.trim()).join("|") === "Delta BW|United BW", "a customer's stations are grouped by contract");
  check(/what's under it never crosses/.test(doc.body.textContent) && /shares badges and gear/.test(doc.body.textContent), "their contract tree shows with its sharing rules");
  // The bell opens a short list
  doc.querySelector("[data-act=bellMenu]").click(); await sleep(20);
  check(!doc.querySelector(".bellpop").hidden && doc.querySelectorAll(".bellpop .bellrow").length > 0 && /offline/.test(doc.querySelector(".bellpop").textContent), "the bell opens a list of what needs attention");
  doc.querySelector(".bellpop .bellrow").click(); await sleep(30);
  check(E("!!S.preview") && doc.querySelector(".bellpop").hidden, "picking one opens that customer's quick view and closes the list");
  E("S.preview = null; renderLayer()");
  // Customer search finds stations and serials
  await go("customers");
  const sq = doc.querySelector('[data-f="q"]'); sq.value = "commissary"; sq.dispatchEvent(new dom.window.Event("input", { bubbles: true })); await sleep(20);
  check(/Sky Harbor Catering/.test(doc.querySelector(".ctable").textContent) && doc.querySelectorAll(".ctable tbody tr[data-preview]").length === 1, "search finds a customer by one of their stations");
  const serial = E("(DB.hw || []).find(u => u.org_id)?.serial"), owner = E("custOf((DB.hw || []).find(u => u.org_id).org_id).name");
  const sq2 = doc.querySelector('[data-f="q"]'); sq2.value = serial; sq2.dispatchEvent(new dom.window.Event("input", { bubbles: true })); await sleep(20);
  check(doc.querySelector(".ctable").textContent.includes(owner), "...or by a hardware serial (" + serial + ")");
  const sq3 = doc.querySelector('[data-f="q"]'); sq3.value = ""; sq3.dispatchEvent(new dom.window.Event("input", { bubbles: true })); await sleep(20);
  // Disconnected stations show under All, greyed out
  E("const c0 = DB.customers.find(c => c.name === 'Copper State Cargo'); api.revokeStation(c0.id, c0.stations[0].id)");
  await go("fleet"); await click('[data-seg="fleet:all"]');
  check(doc.querySelectorAll("tbody tr.gone").length === E("api.fleet(true).filter(s => s.revoked).length") && /Copper State Cargo · 3 stations, 1 disconnected/.test(page()), "disconnected stations are listed under All, greyed out");
  await click('[data-seg="fleet:online"]');
  check(doc.querySelectorAll("tbody tr.gone").length === 0, "...but not under Online");
  // Remove a disconnected station for good
  const cc = E("DB.customers.find(c => c.name === 'Copper State Cargo').id"), goneId = E(`custOf('${cc}').stations[0].id`), goneName = E(`custOf('${cc}').stations[0].name`);
  E(`DB.hw.push({ id: "hwgone", serial: "SP-0901", kind: "station", status: "installed", org_id: "${cc}", station_id: "${goneId}", events: [] })`);
  await go("customer/" + cc); check(/Disconnected/.test(page()) && page().includes(goneName), "disconnected stations are listed on the customer page");
  await click(`[data-act="askRemove"][data-id="${goneId}"]`); check(/Remove for good\? Their taps stay in history/.test(page()), "removing asks first");
  await click(`[data-act="doRemove"][data-id="${goneId}"]`);
  check(!E(`custOf('${cc}').stations.some(s => s.id === '${goneId}')`) && !E(`api.fleet(true).some(s => s.id === '${goneId}')`), "removed: gone from the customer and the Stations page");
  check(E(`(() => { const u = DB.hw.find(x => x.id === "hwgone"); return u.status === "returned" && !u.station_id && !u.org_id && u.events[0].details.reason === "station removed"; })()`), "its box shows as returned");
  // Replace a station's hardware
  const live1 = E(`custOf('${cc}').stations.find(s => !s.revoked).id`);
  E(`DB.hw.push({ id: "hwold", serial: "SP-0902", kind: "station", status: "installed", org_id: "${cc}", station_id: "${live1}", events: [] }, { id: "hwnew", serial: "SP-0903", kind: "station", status: "ready", org_id: null, station_id: null, events: [] })`);
  await go("customer/" + cc); await click(`[data-act="askReplace"][data-id="${live1}"]`);
  check([...doc.querySelectorAll("#replUnit option")].some((o) => o.value === "hwnew") && ![...doc.querySelectorAll("#replUnit option")].some((o) => o.value === "hwold"), "replace offers units in stock only");
  doc.querySelector("#replUnit").value = "hwnew"; await click(`[data-act="doReplace"][data-id="${live1}"]`); await sleep(20);
  check(/Ship SP-0903 with this code/.test(page()) && /old box is marked for repair/.test(page()) && /^[A-Z0-9]{4}-[A-Z0-9]{4}$/.test(E("S.lastCode.code")), "replace gives a code to ship with the new box");
  check(E(`(() => { const o = DB.hw.find(x => x.id === "hwold"), n = DB.hw.find(x => x.id === "hwnew"), s = custOf('${cc}').stations.find(x => x.id === '${live1}');
    return o.status === "repair" && !o.station_id && n.station_id === s.id && n.org_id === '${cc}' && !s.activated_at && !!s.replaced; })()`), "old box to repair, new box on the same station, waiting for setup");
  // Station history and editing from the console
  await click(`[data-act="stHist"][data-id="${live1}"]`);
  check(/Hardware replaced \(new box SP-0903\)/.test(doc.querySelector("tr.histrow").textContent) && /Added/.test(doc.querySelector("tr.histrow").textContent), "click a station's name for its history");
  await click(`[data-act="stHist"][data-id="${live1}"]`); check(!doc.querySelector("tr.histrow"), "click again to hide it");
  const other = E(`custOf('${cc}').stations.find(s => !s.revoked && s.id !== '${live1}').name`);
  await click(`[data-act="askEditStation"][data-id="${live1}"]`);
  doc.querySelector(`[data-form="stEdit:${live1}"] [name=name]`).value = other; await submit(`[data-form="stEdit:${live1}"]`);
  check(/already have a station with that name/.test(doc.querySelector("tr.editrow").textContent), "two stations can't share a name");
  doc.querySelector(`[data-form="stEdit:${live1}"] [name=name]`).value = "  Ramp   Office B "; doc.querySelector(`[data-form="stEdit:${live1}"] [name=location]`).value = "Gate B";
  await submit(`[data-form="stEdit:${live1}"]`);
  check(E(`(() => { const s = custOf('${cc}').stations.find(x => x.id === '${live1}'); return s.name === "Ramp Office B" && s.location === "Gate B"; })()`) && !doc.querySelector("tr.editrow"), "rename and move to another location");
  check(E(`custOf('${cc}').locations.includes("Gate B")`) && /Renamed from .* to Ramp Office B/.test(E(`api.stationHistory('${cc}', '${live1}').map(stEventText).join("|")`))
        && /Moved .*to Gate B/.test(E(`api.stationHistory('${cc}', '${live1}').map(stEventText).join("|")`)), "both are in its history, and the new place is offered next time");
  const da = E("DB.customers.find(c => c.name === 'Demo Air Services').id"), dst = E(`custOf('${da}').stations.find(s => !s.revoked).id`);
  await go("customer/" + da); await click(`[data-act="askEditStation"][data-id="${dst}"]`);
  check(!!doc.querySelector(`[data-form="stEdit:${dst}"] select[name=contract_id]`) && /past taps stay with the one it had/.test(doc.querySelector("tr.editrow").textContent), "customers with contracts get a contract picker, with what a move means");
  doc.querySelector(`[data-form="stEdit:${dst}"] [name=contract_id]`).value = "uaw"; await submit(`[data-form="stEdit:${dst}"]`);
  check(E(`custOf('${da}').stations.find(x => x.id === '${dst}').contract_id`) === "uaw" && /to United AW/.test(E(`stEventText(api.stationHistory('${da}', '${dst}')[0])`)), "move a station to another contract");
  // Light logo from the console
  await go("customer/" + da);
  check(/Light logo/.test(page()) && !!doc.querySelector("#logoDarkFile"), "customer page offers a light logo");
  await api_set(da);
  check(!!doc.querySelector('[data-act="rmLogoDark"]'), "it shows once set");
  await click('[data-act="rmLogoDark"]'); await sleep(20);
  check(E(`custOf('${da}').logo_dark_url`) === "" && !doc.querySelector('[data-act="rmLogoDark"]'), "and can be removed");
  // Station preview follows the same color rules
  E(`Object.assign(custOf('${da}'), { primary: "#FFFFFF", logo_url: "data:image/png;base64,AAA", logo_dark_url: "" })`); await go("customers"); await go("customer/" + da);
  check(/background:#ffffff/i.test(doc.querySelector(".pv-top").getAttribute("style")) && !doc.querySelector('[data-pair="accent"]'), "preview: white top bar with their logo; no accent color to pick");
  E(`Object.assign(custOf('${da}'), { primary: "#FBFAFF", logo_dark_url: "data:image/png;base64,BBB" })`); await go("customers"); await go("customer/" + da);
  check(doc.querySelector(".pv-top img")?.getAttribute("src") === "data:image/png;base64,AAA", "preview: a light main color keeps the normal logo even with a light one uploaded");
  check(E("stContrast(stUi('#FFFFFF'), '#f7f8fa')") >= 3, "preview rings use a color that shows on the screen");
  await go("fleet"); await click('[data-seg="fleet:all"]');
  check(/Newest: station-0\.1\.0 · 1 not on it yet/.test(page()), "Stations shows the newest station version and how many aren't on it");
  // Closing out a customer
  const sky = E("DB.customers.find(c => c.name === 'Sky Harbor Catering').id");
  E(`DB.hw.push({ id: "hwsky", serial: "SP-0950", kind: "station", status: "installed", org_id: "${sky}", station_id: custOf("${sky}").stations[0].id, events: [] })`);
  await go("customer/" + sky); await click('[data-act="askClose"]');
  check(/Close out Sky Harbor Catering\? Their account is cancelled, \d+ stations? disconnects? for good and \d+ units? (is|are) marked as coming back/.test(page()), "closing out asks first and says what will happen", doc.querySelector(".confirm")?.textContent);
  await click('[data-act="doClose"]'); await sleep(20);
  check(E(`custOf("${sky}").status`) === "cancelled" && E(`custOf("${sky}").stations.every(s => s.revoked)`) && E(`DB.hw.find(u => u.id === "hwsky").status`) === "returning",
        "closed out: cancelled, every station disconnected, its unit coming back");
  check(/Closed out: their stations are disconnected/.test(page()) && !!doc.querySelector('[data-act="reopen"]'), "the customer page says so, with a way to reopen");
  await go("hardware"); await click('[data-seg="hw:fix"]'); check(/SP-0950/.test(page()) && /Coming back/.test(page()), "Hardware lists units coming back under Repairs and returns");
  await go("customers"); await click('[data-seg="status:cancelled"]'); check(/Sky Harbor Catering/.test(page().split("Every company")[1] || page()), "the customer list has a Closed filter");
  await click('[data-seg="status:all"]');
  await go("customer/" + sky); await click('[data-act="reopen"]'); await sleep(20);
  check(E(`custOf("${sky}").status`) === "active", "reopen sets them back to active");
  check(errors.length === 0, "no script errors " + errors.join(";"));
  process.exit();
})();
