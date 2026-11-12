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
// Labels: pick items, barcode or QR, sheet layout; printing gives things without a barcode their code first.
(async () => {
  await sleep(100);
  check(E("code128Bits('RAD-001')") === "110100100001100010111010100011000101100010001001101110010011" + E("code128Bits('RAD-001')").slice(60), "Code 128 starts with the right start code");
  check(E("code128Bits('RAD-001')").length === 11 * 10 + 2, "Code 128 for 7 characters is 112 modules (start, 7, check, stop)");
  await go("equipment"); await click('[data-act="labOpen"][data-k="equipment"]'); await sleep(40);
  check(E("S.route") === "labels" && /Print labels/.test(page()) && doc.querySelector(".snav a.on")?.textContent.includes("Equipment"), "Equipment has Print labels; the page sits under Equipment");
  const n = E("api.equipment().filter(x => x.status !== 'retired').length"), noCode = E("DB.equipment.filter(x => !x.barcode && x.status !== 'retired').length");
  check(new RegExp(`${n} labels`).test(page()) && new RegExp(`${noCode} items don't have a barcode yet`).test(page()), "every item picked; says how many get a new barcode", page().slice(0, 300));
  const radio = E("DB.equipment.find(q => q.name === 'Radio 01')");
  check(E("S.labPrint.codes.get(DB.equipment.find(q => q.name === 'Radio 01').id).code") === radio.asset, "an item's asset tag becomes its barcode when it's free");
  check(doc.querySelectorAll(".lab-preview .sheet").length === 1 && doc.querySelectorAll(".lab-preview .slot svg.bc").length === Math.min(n, 30), "preview shows the sheet with a barcode on each label");
  await change(doc.querySelector('[data-act-change="labStart"]'), "5");
  check(doc.querySelectorAll(".lab-preview .slot")[3].innerHTML === "" && doc.querySelectorAll(".lab-preview .slot")[4].innerHTML !== "", "Start at label 5 leaves the first four empty");
  await click('[data-act="labNone"]'); check(/0 of \d+ picked/.test(page()) && doc.querySelector('[data-act="labPrint"]').disabled, "None: nothing to print");
  await click('[data-act="labAll"]');
  doc.getElementById("labQ").value = "radio 0"; doc.getElementById("labQ").dispatchEvent(new dom.window.Event("input", { bubbles: true })); await sleep(20);
  const radios = E("S.labPrint.picked.length");
  check(radios > 1 && E("S.labPrint.picked.every(x => /Radio/.test(x.name))"), "search narrows it to the radios");
  E("window.print = () => { window.printed = document.getElementById('printRoot').innerHTML; }");
  await click('[data-act="labPrint"]'); await sleep(120);
  check(E("DB.equipment.filter(q => /Radio 0/.test(q.name)).every(q => q.barcode)") && E("DB.equipment.find(q => q.name === 'Radio 01').barcode") === radio.asset, "printing saves each radio's barcode first");
  check(E("DB.equipment.find(q => q.name === 'Radio 01').tag") === radio.tag, "an item that had an NFC tag keeps it");
  check(/@page \{ size: 8.5in 11in/.test(E("window.printed")) && (E("window.printed").match(/class="slot/g) || []).length >= radios, "the print page is a letter sheet with the labels on it");
  check(!/0 items|items don't have/.test(page()) || !/Radio/.test(page().split("don't have")[0]), "after printing, the radios aren't new any more");
  // QR codes and the label printer size
  dom.window.qrcode = require("qrcode-generator");
  await change(doc.querySelector('[data-act-change="labType"]'), "qr"); await change(doc.querySelector('[data-act-change="labSheet"]'), "roll");
  check(doc.querySelectorAll(".lab-preview .slot svg.qr").length === 1 && /First of \d+/.test(page()) && !doc.querySelector('[data-act-change="labStart"]'), "QR on the label printer: one label per page, no start position", doc.querySelectorAll(".lab-preview .slot svg.qr").length + " " + /First label/.test(page()) + " " + !!doc.querySelector('[data-act-change="labStart"]') + " " + E("S.lab.type"));
  // Employees
  await click('[data-act="labKind"][data-k="employees"]');
  check(doc.querySelector(".snav a.on")?.textContent.includes("Employees") && /badges/.test(page()), "Employees tab: badge labels, under Employees");
  const pat = E("DB.employees.find(e => e.active && !e.barcode && e.number)");
  check(E(`S.labPrint.codes.get('${pat.id}').code`) === pat.number.toUpperCase(), "an employee's number becomes their badge barcode when it's free");
  E("DB.me.role = 'viewer'"); await go("overview"); await go("labels");
  check(/Ask a supervisor or manager to print labels/.test(page()), "View Only can't print labels");
  E("DB.me.role = 'supervisor'"); E("S.lab = labDefaults('equipment')"); await go("overview"); await go("labels");
  check(E("S.labPrint.picked.every(x => x.barcode)") && /need a manager to print their first label/.test(page()), "supervisors print labels for equipment that already has a barcode only");
  check(errors.length === 0, "no script errors " + errors.join(";"));
  process.exit();
})();
