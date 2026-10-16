// Reproduce the reported bug: a station that had "Our server" saved from the old setup screen.
const { JSDOM } = require("jsdom");
const fs = require("fs");
const src = fs.readFileSync(process.argv[2], "utf8");
const check = (c, m, t) => { console.log((c ? "pass  " : "FAIL  ") + m + (c ? "" : "\n      " + t)); if (!c) process.exitCode = 1; };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function boot(saved) {
  const dom = new JSDOM("<!doctype html><html><body>" + src + "</body></html>", { runScripts: "dangerously", pretendToBeVisual: true, url: "https://example.test/",
    beforeParse(w) {
      w.crypto.randomUUID ??= () => require("crypto").randomUUID();
      w.localStorage.setItem("station.v2", JSON.stringify(saved));
      w.localStorage.setItem("device.v1", JSON.stringify({ ssid: null, wired: true }));
      w.fetch = async () => ({ status: 404, json: async () => { throw new Error("not json"); } });   // a web page, not a station server
    } });
  await sleep(300); return dom;
}
(async () => {
  const base = { deviceKey: null, config: null, cache: null, queue: [], lastSync: null, syncIssues: [] };
  // 1. exactly the user's state: "Our server" with no address
  let dom = await boot({ ...base, mode: "supabase", url: "", anonKey: "" });
  let E = (s) => dom.window.eval(s), text = () => dom.window.document.querySelector("#screen").textContent.replace(/\s+/g, " ");
  E("S.wiz.code='DEMO0001'"); await E("activate()"); await sleep(400);
  check(/Tap the admin tag/.test(text()), "old 'Our server' setting with no address -> uses hosted, DEMO-0001 activates", text().slice(0, 300));
  // 2. a custom server that isn't a station server
  dom = await boot({ ...base, mode: "supabase", url: "https://example.com", anonKey: "x".repeat(30) });
  E = (s) => dom.window.eval(s); text = () => dom.window.document.querySelector("#screen").textContent.replace(/\s+/g, " ");
  E("S.wiz.step='code'; renderMain()");
  check(/Server: https:\/\/example.com/.test(text()) && /Use hosted server/.test(text()), "custom server is shown on the code step, with Use hosted server", text().slice(0, 300));
  E("S.wiz.code='DEMO0001'"); await E("activate()"); await sleep(300);
  check(/isn't answering like a station server/.test(text()) && !/bad_response/.test(text()), "wrong server -> plain-language error", text().slice(0, 300));
  dom.window.document.querySelector('#screen [data-w="hosted"]').click(); await sleep(50);
  E("S.wiz.code='DEMO0001'"); await E("activate()"); await sleep(400);
  check(/Tap the admin tag/.test(text()), "Use hosted server -> activation works", text().slice(0, 300));
  process.exit();
})();
