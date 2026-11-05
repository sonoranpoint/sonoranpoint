// Local stand-in for the Supabase project: real Postgres + real PostgREST (same migrations),
// plus a small mock of Supabase Auth (password + magic-link sign-in) behind one URL like supabase.co.
//   node backend.js            -> fresh DB, listens on http://127.0.0.1:54321
const { execSync, spawn } = require("child_process");
const http = require("http");
const crypto = require("crypto");
const SECRET = "local-test-jwt-secret-local-test-jwt-secret";
const path = require("path");
const ROOT = path.resolve(__dirname, "../../supabase");
const POSTGREST = process.env.POSTGREST_BIN || path.resolve(__dirname, "../../.tools/postgrest");   // https://github.com/PostgREST/postgrest/releases
const PG = "postgres://authenticator:authpass@127.0.0.1:5432/etlive";
const b64 = (o) => Buffer.from(typeof o === "string" ? o : JSON.stringify(o)).toString("base64url");
const sign = (claims) => { const h = b64({ alg: "HS256", typ: "JWT" }), p = b64(claims);
  return `${h}.${p}.${crypto.createHmac("sha256", SECRET).update(`${h}.${p}`).digest("base64url")}`; };
const ANON = sign({ role: "anon", iss: "local", exp: 4102444800 });
const psql = (sql) => execSync(`su postgres -c "psql -v ON_ERROR_STOP=1 -q -t -A -d etlive"`, { input: sql }).toString().trim();

function resetDb() {
  execSync(`su postgres -c "dropdb --if-exists --force etlive; createdb etlive"`);
  execSync(`cat ${ROOT}/tests/local_supabase_stub.sql ${ROOT}/migrations/*.sql ${ROOT}/seed.sql | su postgres -c "psql -v ON_ERROR_STOP=1 -q -d etlive"`, { stdio: ["ignore", "ignore", "inherit"] });
  psql(`do $$ begin if not exists (select 1 from pg_roles where rolname='authenticator') then
          create role authenticator login password 'authpass' noinherit; end if; end $$;
        grant anon, authenticated, service_role to authenticator;
        insert into auth.users (id, email, raw_user_meta_data) values
          ('11111111-1111-1111-1111-111111111111', 'g.ryan@sonoranpoint.com', '{"full_name":"Dez"}'),
          ('22222222-2222-2222-2222-222222222222', 'morgan@demoair.example', '{"full_name":"Morgan Reyes"}'),
          ('33333333-3333-3333-3333-333333333333', 'kelly@demoair.example', '{"full_name":"Kelly Park"}'),
          ('44444444-4444-4444-4444-444444444444', 'nobody@example.com', '{}');
        insert into private.platform_operators (user_id, name, role) values ('11111111-1111-1111-1111-111111111111', 'Dez', 'owner');
        insert into org_members (org_id, user_id, role) values
          ('00000000-0000-0000-0000-00000000d3e0', '22222222-2222-2222-2222-222222222222', 'owner'),
          ('00000000-0000-0000-0000-00000000d3e0', '33333333-3333-3333-3333-333333333333', 'supervisor');`);
}

const outbox = [];   // emails "sent" by the mock auth (magic links, resets)
// Two-step sign-in (authenticator app): factors per user, real TOTP codes (RFC 6238, 30 s, 6 digits).
const factors = {};   // user id -> [{ id, secret, status, friendly_name }]
const B32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
const b32decode = (s) => { let bits = ""; for (const ch of s.replace(/=+$/, "")) bits += B32.indexOf(ch).toString(2).padStart(5, "0");
  return Buffer.from(bits.match(/.{8}/g).map((b) => parseInt(b, 2))); };
function totp(secret, step = Math.floor(Date.now() / 30000)) {
  const msg = Buffer.alloc(8); msg.writeBigUInt64BE(BigInt(step));
  const h = crypto.createHmac("sha1", b32decode(secret)).update(msg).digest(), o = h[h.length - 1] & 15;
  return String(((h.readUInt32BE(o) & 0x7fffffff) % 1e6)).padStart(6, "0");
}
const userFactors = (id) => (factors[id] || []).map((f) => ({ id: f.id, factor_type: "totp", status: f.status, friendly_name: f.friendly_name, created_at: f.created_at, updated_at: f.created_at }));
function userBy(field, v) {
  const row = psql(`select json_build_object('id', id, 'email', email, 'user_metadata', coalesce(raw_user_meta_data, '{}'::jsonb)) from auth.users where ${field} = '${String(v).replace(/'/g, "''")}'`);
  return row ? JSON.parse(row) : null;
}
function session(u, aal = "aal1") {
  const exp = Math.floor(Date.now() / 1000) + 3600, now = Math.floor(Date.now() / 1000);
  const user = { id: u.id, aud: "authenticated", role: "authenticated", email: u.email, user_metadata: u.user_metadata, app_metadata: {}, factors: userFactors(u.id) };
  const amr = [{ method: "password", timestamp: now }, ...(aal === "aal2" ? [{ method: "totp", timestamp: now }] : [])];
  return { access_token: sign({ sub: u.id, role: "authenticated", aud: "authenticated", email: u.email, exp, aal, amr, session_id: "s-" + u.id }), token_type: "bearer",
           expires_in: 3600, expires_at: exp, refresh_token: "r-" + u.id + "|" + aal, user };
}
const send = (res, code, body) => { res.writeHead(code, { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "*", "Access-Control-Allow-Methods": "*" }); res.end(body === undefined ? "" : JSON.stringify(body)); };

function auth(req, res, body, url) {
  const p = url.pathname.replace("/auth/v1", ""), q = url.searchParams;
  if (p === "/token" && q.get("grant_type") === "password") {
    const u = userBy("email", (body.email || "").toLowerCase());
    if (!u || body.password !== "pass1234") return send(res, 400, { error: "invalid_grant", error_description: "Invalid login credentials", code: "invalid_credentials", msg: "Invalid login credentials" });
    return send(res, 200, session(u));
  }
  if (p === "/token" && q.get("grant_type") === "refresh_token") { const [id, aal] = (body.refresh_token || "").slice(2).split("|"); const u = userBy("id", id); return u ? send(res, 200, session(u, aal || "aal1")) : send(res, 400, { error: "invalid_grant" }); }
  if (p === "/otp") {
    let u = userBy("email", (body.email || "").toLowerCase());
    if (!u && body.create_user === false) return send(res, 422, { code: "otp_disabled", msg: "Signups not allowed for otp" });
    if (!u) { psql(`insert into auth.users (email, raw_user_meta_data) values ('${body.email.toLowerCase()}', '${JSON.stringify(body.data || {}).replace(/'/g, "''")}'::jsonb)`); u = userBy("email", body.email.toLowerCase()); }
    outbox.push({ kind: "magiclink", email: u.email, redirect_to: q.get("redirect_to"), token: sign({ sub: u.id, t: Date.now() }) });
    return send(res, 200, {});
  }
  if (p === "/recover") { outbox.push({ kind: "recovery", email: body.email, redirect_to: q.get("redirect_to") }); return send(res, 200, {}); }
  const tok = (req.headers.authorization || "").replace("Bearer ", "");
  let claims = null; try { claims = JSON.parse(Buffer.from(tok.split(".")[1], "base64url")); } catch {}
  if (p === "/user" && claims?.sub) {
    if (req.method === "PUT") { if (body.data) psql(`update auth.users set raw_user_meta_data = coalesce(raw_user_meta_data, '{}'::jsonb) || '${JSON.stringify(body.data).replace(/'/g, "''")}'::jsonb where id = '${claims.sub}'`);
      return send(res, 200, session(userBy("id", claims.sub)).user); }
    return send(res, 200, session(userBy("id", claims.sub)).user);
  }
  if (p === "/logout") return send(res, 204);
  // Two-step sign-in: enroll, challenge, verify, unenroll (what supabase-js calls for mfa.*)
  const fm = p.match(/^\/factors(?:\/([^/]+))?(?:\/(challenge|verify))?$/);
  if (fm && claims?.sub) {
    const list = (factors[claims.sub] ||= []), f = fm[1] ? list.find((x) => x.id === fm[1]) : null;
    if (!fm[1] && req.method === "POST") {
      const secret = Array.from(crypto.randomBytes(20), (b) => B32[b % 32]).join(""), id = crypto.randomUUID();
      list.push({ id, secret, status: "unverified", friendly_name: body.friendly_name || "", created_at: new Date().toISOString() });
      return send(res, 200, { id, type: "totp", friendly_name: body.friendly_name, totp: { qr_code: "<svg xmlns='http://www.w3.org/2000/svg'/>", secret, uri: `otpauth://totp/x?secret=${secret}` } });
    }
    if (!f) return send(res, 404, { code: "mfa_factor_not_found", msg: "Factor not found" });
    if (fm[2] === "challenge") return send(res, 200, { id: crypto.randomUUID(), type: "totp", expires_at: Math.floor(Date.now() / 1000) + 300 });
    if (fm[2] === "verify") {
      const step = Math.floor(Date.now() / 30000);
      if (![step - 1, step, step + 1].some((s) => totp(f.secret, s) === String(body.code))) return send(res, 422, { code: "mfa_verification_failed", msg: "Invalid TOTP code entered" });
      f.status = "verified"; return send(res, 200, session(userBy("id", claims.sub), "aal2"));
    }
    if (req.method === "DELETE") { factors[claims.sub] = list.filter((x) => x !== f); return send(res, 200, { id: f.id }); }
  }
  if (p === "/verify") { const u = userBy("id", JSON.parse(Buffer.from((q.get("token") || "..").split(".")[1], "base64url")).sub); return send(res, 200, session(u)); }
  send(res, 404, { msg: "not mocked: " + p });
}

function start(port = 54321) {
  resetDb();
  // A PostgREST left over from a crashed run would still hold the port with the old database's functions.
  try { execSync("pkill -f '[.]tools/postgrest'"); } catch {}
  const pg = spawn(POSTGREST, [], { env: { ...process.env, PGRST_DB_URI: PG, PGRST_DB_SCHEMAS: "public",
    PGRST_DB_ANON_ROLE: "anon", PGRST_JWT_SECRET: SECRET, PGRST_SERVER_PORT: "54322", PGRST_LOG_LEVEL: "crit" }, stdio: "inherit" });
  process.on("exit", () => { try { pg.kill(); } catch {} });
  const server = http.createServer((req, res) => {
    let data = ""; req.on("data", (c) => (data += c)); req.on("end", () => {
      const url = new URL(req.url, "http://x");
      if (req.method === "OPTIONS") return send(res, 204);
      if (url.pathname.startsWith("/auth/v1")) { let b = {}; try { b = JSON.parse(data || "{}"); } catch {} return auth(req, res, b, url); }
      if (url.pathname.startsWith("/rest/v1")) {
        const fwd = http.request({ host: "127.0.0.1", port: 54322, method: req.method, path: url.pathname.replace("/rest/v1", "") + url.search,
          headers: { ...req.headers, host: "127.0.0.1:54322" } }, (r) => { res.writeHead(r.statusCode, { ...r.headers, "access-control-allow-origin": "*" }); r.pipe(res); });
        fwd.on("error", (e) => send(res, 502, { message: String(e) })); fwd.end(data); return;
      }
      send(res, 404, {});
    });
  });
  return new Promise((ok) => server.listen(port, "127.0.0.1", () => setTimeout(() => ok({ server, pg, url: `http://127.0.0.1:${port}`, key: ANON, outbox, psql, sign, factors, totp }), 1200)));
}
module.exports = { start, resetDb, outbox, psql, ANON, factors, totp };
if (require.main === module) start().then((b) => console.log("backend up", b.url));
