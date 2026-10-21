# Sonoran Point — notes for Claude

White-label NFC equipment checkout. Owner: Dez (Sonoran Point Technologies). Pilot: PHX Terminal 3.
See README.md for the full product description.

## Layout
- `dashboard/dashboard.html` — customer dashboard, app.sonoranpoint.com (single file, demo + live modes)
- `platform/console.html` — operator console, console.sonoranpoint.com (customers, stations, hardware, team, activity)
- `station/station.html` — the kiosk screen on each Pi; `station/pi/` — PN532 reader service, Wi-Fi helper
- `supabase/migrations/` — database, applied in filename order; `supabase/tests/smoke_test.sql` — DB tests
- `brand/` — logos (`source-logo.png` is the official logo; `logo.png`/`logo@2x.png` are made from it — no SVG), icons, `sp-theme.css` (injected between `SP-THEME:start/end` in dashboard + console)
- `deploy/build.py` — builds `deploy/dist/{app,console,station}`; `deploy/email-templates/` — Supabase auth emails
- `tests/run.sh` — runs everything; `tests/ui/` — jsdom screen tests

## How changes ship
- Push to `main` → GitHub Actions runs `tests/run.sh db` + `ui`, then deploys app + console to Cloudflare Pages
  (projects `sonoranpoint-app`, `sonoranpoint-console`).
- Database changes are NOT automatic. Add a new migration file (never edit one already run on the live
  project), then tell Dez to run it in the Supabase SQL editor. Migrations 1–14 have been run, 15–17 handed over (2026-10-21;
  ask if unsure). Alert emails are live (Resend key in Vault, first send
  confirmed 2026-10-20).
- Station changes reach the Pis by copying `deploy/dist/station` onto each Pi (not automatic yet).

## Contracts
- A company's work is split into contracts (customer's own word: `terminology.contract`), a tree in `public.contracts`.
  Stations, employees, equipment and shifts have `contract_id` (null = whole company). Two contracts share when one
  is inside the other or the group they meet in has `share_children` (top level: `settings.share_contracts`).
  `station_tap` enforces it; the sync cache carries `reach` so stations enforce it offline too.
- Loans (`equipment_loans`, migration 16): an item lent to another contract is usable there until tapped back at an owner station.
- Who sees what (migration 17): `member_contracts` limits a dashboard user to contracts (plus everything under and the
  groups above; things with no contract always show; owners see all). Enforced in RLS (`private.can_see`,
  `can_see_equipment`, `can_see_txn`) and in every dashboard function; alert emails follow it. The dashboard's
  "Show" switcher (`S.view`, `wrapViews`) filters further on screen only.

## Email
- Sign-in and invite emails: Supabase Auth sends through Resend SMTP (smtp.resend.com, from no-reply@sonoranpoint.com,
  set up 2026-10-20); templates in `deploy/email-templates/` are pasted into Supabase by hand.
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
