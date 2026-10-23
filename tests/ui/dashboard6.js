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
const change = async (el, v) => { if (typeof v === "boolean") el.checked = v; else el.value = v; el.dispatchEvent(new dom.window.Event("change", { bubbles: true })); await sleep(15); };
// Import from a spreadsheet: paste, check the columns, see which rows are left out and why, add the rest.
(async () => {
  await sleep(100);
  await go("equipment"); await click('a[href="#import-equipment"]'); await sleep(30);
  check(E("S.route") === "import-equipment" && !!doc.getElementById("impText"), "Equipment has an Import button that opens the import page");
  const nEq = E("DB.equipment.length"), nCat = E("DB.categories.length");
  const paste = ["Item Name\tType\tAsset #\tBarcode\tDepartment\tWhatever",
    "Radio 21\tRadio\tRAD-021\t\tDelta BW\tx",
    "Ladder 01\tLadders\tLAD-001\tLAD001\t\t",
    "\tRadio\tRAD-022\t\t\t",                       // no name
    "Radio 23\tRadio\tRAD-021\t\t\t",                // same asset tag as row 2
    "Radio 24\tRadio\t\t\tNowhere\t",                // no such contract
    `"Vacuum, big"\tVacuum\tVAC-099\t\t\t`].join("\n");
  doc.getElementById("impText").value = paste; doc.getElementById("impText").dispatchEvent(new dom.window.Event("input", { bubbles: true }));
  doc.querySelector('[data-form="impPaste"]').dispatchEvent(new dom.window.Event("submit", { bubbles: true, cancelable: true })); await sleep(30);
  check(JSON.stringify(E("S.imp.map")) === JSON.stringify(["name", "category", "asset", "barcode", "contract", ""]), "columns are matched by their headings; unknown ones are skipped", JSON.stringify(E("S.imp.map")));
  check(/3 ready/.test(page()) && /3 left out/.test(page()), "it says how many rows are ready and how many are left out", page().slice(0, 400));
  check(/no name/.test(page()) && /asset tag RAD-021 is already on Radio 21/.test(page()) && /no contract called “Nowhere”/.test(page()), "each left-out row says why");
  check(/New categories will be added with no time limit: Ladders/.test(page()), "a category that doesn't exist yet will be added");
  await click('[data-act="impGo"]');
  check(E("DB.equipment.length") === nEq + 3 && E("DB.categories.length") === nCat + 1 && /3 items added/.test(page()) && /3 rows were left out/.test(page()), "Add: three items and the new category are added");
  check(E("DB.equipment.find(q => q.name === 'Vacuum, big')?.asset") === "VAC-099" && E("contractName(DB.equipment.find(q => q.name === 'Radio 21').contract)") === "Delta BW"
        && E("DB.equipment.find(q => q.name === 'Ladder 01').barcode") === "LAD001", "quoted names, departments and barcodes come through");
  // Importing the same list again skips what's already there
  await click('[data-act="impAgain"]'); doc.getElementById("impText").value = paste;
  doc.querySelector('[data-form="impPaste"]').dispatchEvent(new dom.window.Event("submit", { bubbles: true, cancelable: true })); await sleep(30);
  check(/0 ready/.test(page()) && doc.querySelector('[data-act="impGo"]').disabled, "importing the same file again adds nothing twice");
  // Change a column by hand
  await click('[data-act="impAgain"]'); doc.getElementById("impText").value = "Thing\tStuff\nTorque Wrench\tTools"; 
  doc.querySelector('[data-form="impPaste"]').dispatchEvent(new dom.window.Event("submit", { bubbles: true, cancelable: true })); await sleep(30);
  check(/Pick which column is the name/.test(page()), "no name column: it asks which one is the name");
  await change(doc.querySelector('[data-impcol="0"]'), "name"); await change(doc.querySelector('[data-impcol="1"]'), "category");
  check(/1 ready/.test(page()), "picking the columns by hand works");
  // Employees, with full names, shifts and a bad badge
  await go("employees"); await click('a[href="#import-employees"]'); await sleep(30);
  const nEmp = E("DB.employees.length");
  doc.getElementById("impText").value = ["Name,Employee #,Badge ID,Shift,Department", "\"Nguyen, Linh\",2001,04:AA:BB:CC:DD:01,AM,United BW", "Sam Okoro,2002,,PM; Overnight,", "Pat Doe,2001,,,", "Lee Wu,2003,hello,,", "Jo Ray,2004,,Brunch,"].join("\n");
  doc.querySelector('[data-form="impPaste"]').dispatchEvent(new dom.window.Event("submit", { bubbles: true, cancelable: true })); await sleep(30);
  check(/2 ready/.test(page()) && /employee # 2001 is already Linh Nguyen/.test(page()) && /badge ID “hello” doesn't look right/.test(page()) && /no shift called “Brunch”/.test(page()), "employee rows are checked: numbers, badge IDs, shifts", page().slice(0, 600));
  await click('[data-act="impGo"]');
  const linh = E("JSON.stringify((() => { const e = DB.employees.find(x => x.number === '2001'); return [e.first, e.last, e.badge, contractName(e.contract), e.shifts.length]; })())");
  check(E("DB.employees.length") === nEmp + 2 && linh === JSON.stringify(["Linh", "Nguyen", "04AABBCCDD01", "United BW", 1]) && E("DB.employees.find(x => x.number === '2002').shifts.length") === 2,
        "people are added with their names, badge, department and shifts", linh);
  // Template, and who can import
  const tpl = E("(() => { let got; const o = downloadCsv; downloadCsv = (n, h, r) => (got = [n, h, r]); impTemplate('employees'); downloadCsv = o; return JSON.stringify(got); })()");
  check(/"First name","Last name","Employee #"/.test(tpl) && /employees-import-template/.test(tpl), "Download a template gives a CSV with the right headings", tpl);
  E("DB.me.role = 'viewer'"); await go("equipment"); await go("import-equipment");
  check(!doc.querySelector('a[href="#import-equipment"]') && /Ask a manager or admin to import equipment/.test(page()), "View Only users can't import");
  check(errors.length === 0, "no script errors " + errors.join(";"));
  process.exit();
})();
