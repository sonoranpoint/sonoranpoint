const { start } = require("./backend");
const { createClient } = require("@supabase/supabase-js");
(async () => {
  const b = await start();
  const sb = createClient(b.url, b.key, { auth: { persistSession: false } });
  console.log("anon equipment:", (await sb.from("equipment").select("id")).data?.length);
  const s = await sb.auth.signInWithPassword({ email: "morgan@demoair.example", password: "pass1234" });
  console.log("signin:", s.error?.message || s.data.user.email);
  console.log("owner equipment:", (await sb.from("equipment").select("id")).data?.length);
  console.log("my_companies:", JSON.stringify((await sb.rpc("my_companies")).data));
  console.log("pins:", JSON.stringify((await sb.rpc("dashboard_pin_holders", { p_org: "00000000-0000-0000-0000-00000000d3e0" })).data));
  const s2 = createClient(b.url, b.key, { auth: { persistSession: false } });
  await s2.auth.signInWithPassword({ email: "g.ryan@sonoranpoint.com", password: "pass1234" });
  console.log("operator:", (await s2.rpc("am_platform_operator")).data, "customers:", (await s2.rpc("platform_customers")).data?.length);
  b.pg.kill(); b.server.close(); process.exit();
})();
