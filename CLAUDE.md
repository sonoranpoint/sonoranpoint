# Sonoran Point — notes for Claude

White-label NFC equipment checkout. Owner: Dez (Sonoran Point Technologies). Pilot: PHX Terminal 3.
See README.md for the full product description.

## Layout
- `dashboard/dashboard.html` — customer dashboard, app.sonoranpoint.com (single file, demo + live modes)
- `platform/console.html` — operator console, console.sonoranpoint.com (customers, stations, hardware, team, activity)
- `station/station.html` — the kiosk screen on each Pi; `station/pi/` — PN532 reader service, Wi-Fi helper
- `supabase/migrations/` — database, applied in filename order; `supabase/tests/smoke_test.sql` — DB tests
- `brand/` — logos (`source-logo.png` is the official logo; `logo.png`/`logo@2x.png` are made from it; `logo-light*.png` are the same with the navy SONORAN/TECHNOLOGIES lettering made white, for dark backgrounds — no SVG), icons, `sp-theme.css` (injected between `SP-THEME:start/end` in dashboard + console)
- `deploy/build.py` — builds `deploy/dist/{app,console,station}`; `deploy/email-templates/` — Supabase auth emails
- `tests/run.sh` — runs everything; `tests/ui/` — jsdom screen tests

## How changes ship
- Push to `main` → GitHub Actions runs `tests/run.sh db` + `ui`, then deploys app + console to Cloudflare Pages
  (projects `sonoranpoint-app`, `sonoranpoint-console`).
- Database changes are NOT automatic. Add a new migration file (never edit one already run on the live
  project), then tell Dez to run it in the Supabase SQL editor. Migrations 1–22 have been run (checked 2026-10-22); 23 handed over
  (ask if unsure). Alert emails are live (Resend key in Vault, first send
  confirmed 2026-10-20).
- Station changes reach the Pis by themselves: every deploy publishes `app.sonoranpoint.com/station-release/latest.json` + a zip
  (version = `VERSION` in station.html + a content hash, so only station changes count). `station/pi/station_updater.py` on each
  Pi serves the app at http://localhost/, downloads/verifies/stages new versions, and the page switches when idle
  (`updater` in station.html; rollback if the page doesn't POST /update/ok within 5 min). Pis set up before the updater was
  installed still need the folder copied by hand once.

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

## Stations
- Removing a station (`remove_station` / `platform_remove_station`, migration 20) sets `removed_at` (and `revoked_at`); the row stays so
  history keeps its name. Lists leave removed stations out (`api.stations()`, `platform_fleet`, `platform_customer`); its hardware goes to "returned".
- Replacing (`platform_replace_station(station, unit)`) keeps the station, gives a new code, sets `replaced_at`; old unit -> "repair",
  new unit (must be a ready/returned station unit) -> assigned and "ready".
- History (migration 21): `public.station_events`, written by triggers on `stations` (added, set up, disconnected, replaced,
  removed, renamed, moved location/contract) plus `private.station_event()` for new codes; `by_name` is "Sonoran Point" for operators.
  Console edits go through `platform_update_station`. Taps store `station_contract_id` at insert, so moving a station
  doesn't move its past taps (RLS: `private.can_see_tap`). `station_overview` must be recreated when `stations` gets columns.

## Dashboard sidebar
- Dark blue with the company's light logo (`organizations.logo_dark_url`, migration 22) when they have one; otherwise `.side.light`
  (white, their normal logo or name). Dark appearance keeps it dark either way. Sonoran Point's logo sits at the bottom (`.sp-foot`).
- Station colors (`applyBrand` in station.html, mirrored by `stationPreview` in the console): top bar uses the logo that fits the main color
  (dark main + light logo -> light logo on it; light main -> normal logo on it; dark main with only a normal logo -> white bar; no logo = main + name). Rings/buttons use the main
  color darkened to 3:1 against the screen (`uiColor`). The accent color is no longer offered (kept in the DB; manager tag is fixed).

## Email
- Sign-in and invite emails: Supabase Auth sends through Resend SMTP (smtp.resend.com, from no-reply@sonoranpoint.com,
  set up 2026-10-20); templates in `deploy/email-templates/` are pasted into Supabase by hand.
- Alert emails go out from the database: `private.send_emails()` runs every minute (pg_cron) and posts to Resend
  with pg_net. The Resend key lives in Supabase Vault as `resend_api_key` (never in code). Check sends with
  `select status, error, to_email, subject from private.email_batches order by id desc limit 20;`
- Trial reminder (migration 19): 3 days before `trial_ends_at`, `private.send_trial_reminders()` (run from
  `send_emails()`) emails the customer's owners, admins and contact email (reply-to: operator owners) and copies
  every operator; once per end date (`private.trial_reminders`). Nothing pauses automatically when a trial ends.

## Rules
- Run `tests/run.sh db` and `tests/run.sh ui` before pushing; add tests for new behaviour.
- Every screen works in demo mode (built-in data) and live mode (Supabase). Keep both paths in sync:
  the demo `api` object and `liveApi` / `live` in each HTML file.
- Only the Supabase publishable key may appear in code. Never commit the secret/service_role key, DB password,
  or Cloudflare token.
- Private tables live in schema `private`; customers reach data only through RLS and SECURITY DEFINER functions.
  Operator functions start with `perform private.require_operator()` (owner-only: `require_platform_owner()`).
- Plain, user-facing copy (Dez's customers are ramp/ground-handling crews). Sentence case, no jargon.
