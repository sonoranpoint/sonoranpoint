# Sonoran Point — notes for Claude

White-label NFC equipment checkout. Owner: Dez (Sonoran Point Technologies). Pilot: PHX Terminal 3.
See README.md for the full product description.

## Layout
- `dashboard/dashboard.html` — customer dashboard, app.sonoranpoint.com (single file, demo + live modes)
- `platform/console.html` — operator console, console.sonoranpoint.com (customers, stations, hardware, team, activity)
- `station/station.html` — the kiosk screen on each Pi; `station/pi/` — PN532 reader service, Wi-Fi helper
- `supabase/migrations/` — database, applied in filename order; `supabase/tests/smoke_test.sql` — DB tests
- `brand/` — logos, icons, `sp-theme.css` (injected between `SP-THEME:start/end` in dashboard + console)
- `deploy/build.py` — builds `deploy/dist/{app,console,station}`; `deploy/email-templates/` — Supabase auth emails
- `tests/run.sh` — runs everything; `tests/ui/` — jsdom screen tests

## How changes ship
- Push to `main` → GitHub Actions runs `tests/run.sh db` + `ui`, then deploys app + console to Cloudflare Pages
  (projects `sonoranpoint-app`, `sonoranpoint-console`).
- Database changes are NOT automatic. Add a new migration file (never edit one already run on the live
  project), then tell Dez to run it in the Supabase SQL editor. Migrations 1–12 have been run (checked 2026-10-20;
  ask if unsure). The Resend key is not in Vault yet, so alert emails queue but don't send.
- Station changes reach the Pis by copying `deploy/dist/station` onto each Pi (not automatic yet).

## Email
- Alert emails go out from the database: `private.send_emails()` runs every minute (pg_cron) and posts to Resend
  with pg_net. The Resend key lives in Supabase Vault as `resend_api_key` (never in code). Check sends with
  `select status, error, to_email, subject from private.email_batches order by id desc limit 20;`

## Rules
- Run `tests/run.sh db` and `tests/run.sh ui` before pushing; add tests for new behaviour.
- Every screen works in demo mode (built-in data) and live mode (Supabase). Keep both paths in sync:
  the demo `api` object and `liveApi` / `live` in each HTML file.
- Only the Supabase publishable key may appear in code. Never commit the secret/service_role key, DB password,
  or Cloudflare token.
- Private tables live in schema `private`; customers reach data only through RLS and SECURITY DEFINER functions.
  Operator functions start with `perform private.require_operator()` (owner-only: `require_platform_owner()`).
- Plain, user-facing copy (Dez's customers are ramp/ground-handling crews). Sentence case, no jargon.
