// The public site's "Try it" copies (station and dashboard; the console isn't public) stay on demo data on sonoranpoint.com, and the site's own links point at real files.
const { JSDOM } = require("jsdom");
const fs = require("fs"), path = require("path");
const ROOT = path.resolve(__dirname, "../..");
let fails = 0; const check = (c, m) => { console.log((c ? "pass  " : "FAIL  ") + m); if (!c) { fails++; process.exitCode = 1; } };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const open = (file, pre, url) => new JSDOM("<!doctype html><html><body>" + pre + fs.readFileSync(path.join(ROOT, file), "utf8") + "</body></html>", { runScripts: "dangerously", pretendToBeVisual: true, url,
  beforeParse(w) { w.matchMedia = () => ({ matches: false, addEventListener() {} }); w.scrollTo = () => {}; Object.defineProperty(w, "crypto", { value: require("crypto").webcrypto }); } });
(async () => {
  const app = open("dashboard/dashboard.html", "<script>window.SP_DEMO = true;</script>", "https://sonoranpoint.com/try/app/"); await sleep(300);
  check(app.window.eval("LIVE") === false && /Demo data/i.test(app.window.document.body.textContent), "the demo dashboard on sonoranpoint.com runs on demo data, not the real database");
  const st = open("station/station.html", "<script>window.SP_DEMO = true; window.SP_TRY = true;</script>", "https://sonoranpoint.com/try/station/"); await sleep(1800);
  const sd = st.window.document;
  check(/Tap your badge/.test(sd.querySelector("#screen").textContent) && sd.querySelector("#boxSetup").style.display === "none" && /Try the station/.test(sd.querySelector(".bench-head").textContent),
        "the demo station starts already set up, with the setup panel hidden");
  const shown = (id) => sd.getElementById(id).closest(".ctrl").style.display !== "none";
  check(!shown("acct") && !shown("timeSel") && shown("wifi") && sd.getElementById("btnReset").closest(".box").style.display === "none" && !/04:BA|04:DE/.test(sd.querySelector(".panel").textContent) && !/Admin tag/.test(sd.getElementById("badgeList").textContent),
        "the demo station leaves out what customers don't have: account switch, time travel, the setup admin tag, server log, tag IDs");
  st.window.eval("S.overlay = 'menu'; renderLayer()");
  check(sd.querySelector(".overlay") && !/Server|Unpair/.test(sd.querySelector(".overlay").textContent), "the demo station menu has no server or unpair");
  // A second visit (same browser, so the last visit's demo data and activation are still stored) starts set up again.
  const kept = {}; for (let i = 0; i < st.window.localStorage.length; i++) { const k = st.window.localStorage.key(i); if (k !== "station.v2") kept[k] = st.window.localStorage.getItem(k); }
  const st2 = open("station/station.html", `<script>Object.entries(${JSON.stringify(kept)}).forEach(([k, v]) => localStorage.setItem(k, v)); window.SP_DEMO = true; window.SP_TRY = true;</script>`, "https://sonoranpoint.com/try/station/"); await sleep(1800);
  check(Object.keys(kept).includes("demoServer.v2") && /Tap your badge/.test(st2.window.document.querySelector("#screen").textContent) && /Northwind/.test(st2.window.document.querySelector("#screen").textContent)
        && !/Not set up/.test(st2.window.document.querySelector("#screen").textContent), "coming back to the demo station: set up again, not stuck on \"Not set up yet\"");
  // Links between the site's pages and to its images all exist.
  const site = path.join(ROOT, "site"); const pages = ["index.html", "help/index.html", "try/index.html", "contact/index.html"];
  const missing = [];
  for (const p of pages) {
    const html = fs.readFileSync(path.join(site, p), "utf8");
    for (const [, ref] of html.matchAll(/(?:href|src)="([^"#:?]+)(?:[?#][^"]*)?"/g)) {
      if (/^(mailto|https?):/.test(ref) || ref.startsWith("//")) continue;
      let t = ref.startsWith("/") ? path.join(site, ref) : path.join(site, path.dirname(p), ref);
      if (/\/try\/(app|console|station)\/?$/.test(t)) continue;   // made by the build
      if (/brand\//.test(t)) { if (!fs.existsSync(path.join(ROOT, "brand", path.basename(t)))) missing.push(p + " -> " + ref); continue; }
      if (fs.existsSync(t) && fs.statSync(t).isDirectory()) t = path.join(t, "index.html");
      if (!fs.existsSync(t)) missing.push(p + " -> " + ref);
    }
  }
  check(!missing.length, "every link and image on the site exists" + (missing.length ? ": " + missing.join(", ") : ""));
  // Contact form: checks the fields, sends to submit_contact, then says it's sent; a failure points to the email address.
  const cform = (reply) => { const calls = []; const dom = new JSDOM(fs.readFileSync(path.join(site, "contact/index.html"), "utf8").replace('<script src="../theme.js"></script>', ""),
    { runScripts: "dangerously", url: "https://sonoranpoint.com/contact/?topic=A%20pilot", beforeParse(w) { w.fetch = (u, o) => { calls.push([u, o]); return Promise.resolve(reply); }; } });
    return { dom, calls, doc: dom.window.document, F: dom.window.document.getElementById("contactForm").elements,
      send() { this.doc.getElementById("contactForm").dispatchEvent(new dom.window.Event("submit", { cancelable: true })); } }; };
  const c1 = cform({ ok: true, json: async () => ({ ok: true }) });
  check(c1.F.topic.value === "A pilot", "contact: a link can pick the topic");
  c1.F.name.value = "Pat Lee"; c1.F.email.value = "pat"; c1.send();
  check(/full email/.test(c1.doc.getElementById("formErr").textContent) && !c1.calls.length, "contact: a bad email is caught before sending");
  c1.F.email.value = "pat@example.com"; c1.F.message.value = "40 radios"; c1.F.company.value = "Acme"; c1.send(); await sleep(30);
  const sentBody = c1.calls.length && JSON.parse(c1.calls[0][1].body);
  check(/\/rest\/v1\/rpc\/submit_contact$/.test(c1.calls[0]?.[0] || "") && /^sb_publishable_/.test(c1.calls[0][1].headers.apikey) && sentBody.p_email === "pat@example.com" && sentBody.p_topic === "A pilot"
        && c1.doc.getElementById("contactForm").hidden && !c1.doc.getElementById("sent").hidden && /pat@example.com/.test(c1.doc.getElementById("sent").textContent),
        "contact: sends with the publishable key and says it's sent");
  const c2 = cform({ ok: false, json: async () => ({}) });
  c2.F.name.value = "Pat"; c2.F.email.value = "pat@example.com"; c2.F.message.value = "hi"; c2.send(); await sleep(30);
  check(/support@sonoranpoint.com/.test(c2.doc.getElementById("formErr").textContent) && !c2.doc.getElementById("contactForm").hidden, "contact: if it can't send, it says so and gives the email address");
  // Light/dark switch: follows the device until clicked, then remembers (same key as the dashboard).
  const home = new JSDOM(fs.readFileSync(path.join(site, "index.html"), "utf8").replace('<script src="theme.js"></script>', "<script>" + fs.readFileSync(path.join(site, "theme.js"), "utf8") + "</script>"),
    { runScripts: "dangerously", url: "https://sonoranpoint.com/", beforeParse(w) { w.matchMedia = () => ({ matches: true, addEventListener() {} }); } });
  await sleep(50);
  const hw = home.window, btn = hw.document.querySelector("[data-theme-toggle]");
  check(!hw.document.documentElement.dataset.theme && btn.getAttribute("aria-label") === "Switch to light mode", "theme: follows a dark device until someone picks");
  btn.click();
  check(hw.document.documentElement.dataset.theme === "light" && hw.localStorage.getItem("sp.theme") === "light" && btn.getAttribute("aria-label") === "Switch to dark mode", "theme: the switch picks light and remembers it");
  btn.click();
  check(hw.document.documentElement.dataset.theme === "dark" && hw.localStorage.getItem("sp.theme") === "dark", "theme: and back to dark");
  process.exit();
})();
