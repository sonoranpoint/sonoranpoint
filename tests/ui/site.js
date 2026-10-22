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
  // Links between the site's pages and to its images all exist.
  const site = path.join(ROOT, "site"); const pages = ["index.html", "help/index.html", "try/index.html"];
  const missing = [];
  for (const p of pages) {
    const html = fs.readFileSync(path.join(site, p), "utf8");
    for (const [, ref] of html.matchAll(/(?:href|src)="([^"#:]+)(?:#[^"]*)?"/g)) {
      if (/^(mailto|https?):/.test(ref) || ref.startsWith("//")) continue;
      let t = ref.startsWith("/") ? path.join(site, ref) : path.join(site, path.dirname(p), ref);
      if (/\/try\/(app|console|station)\/?$/.test(t)) continue;   // made by the build
      if (/brand\//.test(t)) { if (!fs.existsSync(path.join(ROOT, "brand", path.basename(t)))) missing.push(p + " -> " + ref); continue; }
      if (fs.existsSync(t) && fs.statSync(t).isDirectory()) t = path.join(t, "index.html");
      if (!fs.existsSync(t)) missing.push(p + " -> " + ref);
    }
  }
  check(!missing.length, "every link and image on the site exists" + (missing.length ? ": " + missing.join(", ") : ""));
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
