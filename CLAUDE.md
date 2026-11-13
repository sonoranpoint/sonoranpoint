# Sonoran Point — notes for Claude

White-label NFC equipment checkout. Owner: Dez (Sonoran Point Technologies). Pilot: PHX Terminal 3.
See README.md for the full product description.

## Layout
- `dashboard/dashboard.html` — customer dashboard, app.sonoranpoint.com (single file, demo + live modes)
- `platform/console.html` — operator console, console.sonoranpoint.com (customers, stations, hardware, team, activity)
- `station/station.html` — the kiosk screen on each Pi; `station/pi/` — PN532 reader service, Wi-Fi helper
- `supabase/migrations/` — database, applied in filename order; `supabase/tests/smoke_test.sql` — DB tests
- `brand/` — logos (`source-logo.png` is the official logo; `logo.png`/`logo@2x.png` are made from it; `logo-light*.png` are the same with the navy SONORAN/TECHNOLOGIES lettering made white, for dark backgrounds — no SVG), icons, `sp-theme.css` (injected between `SP-THEME:start/end` in dashboard + console)
- `site/` — sonoranpoint.com (home, help, try): pitched broadly as asset checkout/tracking, not airport-only. The build adds demo
  copies of the station and dashboard under `try/` (no console: customers never see it). `window.SP_DEMO` forces demo data and
  swaps in a neutral company (Northwind Logistics, departments); `window.SP_TRY` starts the station set up. No real names or emails there.
  The home page's company tree mirrors the demo's departments and stations. Light/dark switch: `site/theme.js` (data-theme, saved as
  `sp.theme`, the dashboard's key; nothing saved = follow the device).
  Contact form: `site/contact/` posts to `public.submit_contact` (migration 27; anon, honeypot + hourly limits), saved in
  `private.contact_requests` and emailed to every operator with reply-to = sender. The try station clears its own storage on every visit.
  `site/security/` explains how data is protected (keep it true when security changes); `/.well-known/security.txt` (expires 2027-11-11).
- `deploy/build.py` — builds `deploy/dist/{app,console,station,site}`; `deploy/email-templates/` — Supabase auth emails
- `tests/run.sh` — runs everything; `tests/ui/` — jsdom screen tests

## How changes ship
- Push to `main` → GitHub Actions runs `tests/run.sh db`, `ui` and `live` (PostgREST downloaded in CI), then deploys app + console to Cloudflare Pages
  (projects `sonoranpoint-app`, `sonoranpoint-console`, `sonoranpoint-site`).
- Database changes are NOT automatic. Add a new migration file (never edit one already run on the live
  project), then tell Dez to run it in the Supabase SQL editor. Migrations 1–40 and 42 have been run, 41 not confirmed (checked 2026-11-12;
  ask if unsure). Alert emails are live (Resend key in Vault, first send
  confirmed 2026-10-20).
- Station changes reach the Pis by themselves: every deploy publishes `app.sonoranpoint.com/station-release/latest.json` + a zip
  (version = `VERSION` in station.html + a content hash, so only station changes count). `station/pi/station_updater.py` on each
  Pi serves the app at http://localhost/, downloads/verifies/stages new versions, and the page switches when idle
  (`updater` in station.html; rollback if the page doesn't POST /update/ok within 5 min). Pis set up before the updater was
  installed still need the folder copied by hand once.
- Signed releases: `deploy/build.py` signs latest.json (Ed25519 over `release_message`, field `sig`) with the `STATION_SIGNING_KEY`
  GitHub secret (PEM, via openssl). The public half is `station/pi/release_key.pub` (installed on Pis at /opt/sp-station/release_key.pub);
  with it present the updater refuses unsigned/badly signed releases, and CI fails if the secret is missing or doesn't match.
- No physical station hardware yet (as of 2026-10-22): the Pi side (updater, NFC service, Wi-Fi helper) is tested only in simulation.

## Contracts
- A company's work is split into contracts (customer's own word: `terminology.contract`), a tree in `public.contracts`.
  Stations, employees, equipment and shifts have `contract_id` (null = whole company). Two contracts share when one
  is inside the other or the group they meet in has `share_children` (top level: `settings.share_contracts`).
  `station_tap` enforces it; the sync cache carries `reach` so stations enforce it offline too.
- Loans (`equipment_loans`, migration 16): an item lent to another contract is usable there until tapped back at an owner station.
- Who sees what (migration 33, replacing 17's rules): in a company with contracts, everyone but its whole-company Admins (role owner, no contracts) sees only
  their `member_contracts` and everything under them — not the groups above, not things with no contract; no contracts = nothing.
  Companies without contracts: everyone sees all. Enforced in RLS (`private.scope_of`/`sees`/`can_see`, `can_see_txn`, `can_see_tap`) and
  in every dashboard function; alert emails follow it. The dashboard's "Show" switcher (`S.view`, `wrapViews`) filters further on screen only.
- Setup is Sonoran Point's (migration 33): `save_contract`/`delete_contract` and the sharing switches (`platform_contract_settings`;
  a trigger keeps customers from changing `settings.share_contracts`/`move_on_return`) are operator-only; customers get `ask_us` and
  send `request_contract_change` (a support request, source 'dashboard', in console Requests). Console: "Contracts and leads" panel
  (`contractsPanel(c, true)`, `ctForm`) and "Their team" (`teamPanel`: invite any role with contracts, change role/contracts, remove).
  A lead = a Manager limited to contracts (can be several). Leads (`private.my_scope` not null) only invite/change/remove people inside
  their branch (`private.in_my_branch`, `contracts_problem`), invites carry `org_invites.contracts`, and they can't change company-wide
  things (`private.unscoped`: org row, logo, renaming/deleting categories and locations). Dashboard: `myScopeIds()`, `canCompany()`.
- Locations (migration 35): each tree entry has `contracts.kind` 'location' (a site or terminal, like PHX or T3) or 'contract'
  (like Delta BW). Labels only; scope and sharing work the same. Set in the console form (`isLoc`).
- Admin optional (migration 36): some companies are run and billed contract by contract with only leads. `platform_create_customer`
  takes no `owner_email` (console New customer: optional); operators may change/remove a company's last Admin (customers can't).
  Console says "Nobody has signed in yet" (`nobodyIn`, from `member_count`) instead of chasing an admin.
- Admins per contract (migration 37): an Admin (role owner) given contracts runs only those (scope like anyone else's) with full
  admin powers there, including other Admins in their branch; given several, all of them. An Admin with no contracts = whole company.
  Only a whole-company person or an operator can make a whole-company Admin (`contracts_problem`). Promoting keeps contracts.
  `members_write` RLS now needs a whole-company Admin. Dashboard `myScopeIds()` treats an Admin with contracts as limited.
- Defaults for leads (migration 38): a trigger puts stations, equipment, employees and shifts that a contract-limited user adds
  without a contract into their first contract. Dashboard forms start on `myDefaultContract()` (the Show switcher's contract, else
  your own); `contractOptions(..., filter=true)` keeps "All" in list filters.
- Guard (migration 39): a contract with people (`member_contracts`) or open invites on it can't be deleted, and an invite whose
  contracts are all gone is refused (`invite_outdated`): otherwise an Admin could be left with none = whole company.
- Visitors (migration 34): `public.visitor_passes` (functions only, no RLS policies) let someone into another contract's stations.
  Station: their badge is refused -> `S.visit` screen ("Manager: tap your fob") -> a manager from that station (+PIN) ->
  `station_visitor_pass` (until midnight, `private.end_of_today`); sync cache `visitors` {employee id: ends_at} so it works offline
  (`visitingUntil`/`servesEmp`). `station_tap` checks `private.on_pass` and flags checkouts 'visitor'. Dashboard Employees ->
  "Visitors" (supervisors+): `find_visitors` (whole company), `create_visitor_pass` (into your contracts, up to 31 days),
  `end_visitor_pass`, `list_visitor_passes` (in and out of your contracts). Hosts can read the visitor's employee row
  (`private.visited_me`, 60 days) for names in history; the dashboard marks those `e.visitor` and leaves them off the Employees list.

## Custom roles (migration 40)
- Nine permissions (`private.all_perms()`): people, status, alerts, visitors, equipment, stations, fobs, shifts, team. Checks use
  `private.has_perm(org, perm)` (from `perms_of`: Admin = all, built-in Manager = all, Supervisor = people/status/alerts/visitors,
  View Only = none, custom role = its `perms`). Company-wide settings still need a whole-company Admin or built-in Manager (`has_org_role` admin + unscoped).
- `public.custom_roles` (functions only): `save_custom_role` / `delete_custom_role` (Admins; a contract Admin's roles get their
  contract and are only seen in it), `list_custom_roles`. A member with a custom role is stored as `role = 'viewer'` +
  `org_members.custom_role_id`; invites carry `custom_role_id`. `set_member_role(..., p_custom_role)`, `invite_member(..., p_custom_role)`.
  No escalation: `can_give_custom` / `can_manage_role` / `can_manage_member` only allow roles whose boxes you have.
- Migration 41 (Dez's split): eleven boxes — people, remove_people (deactivate/reactivate; trigger `guard_employee_active` on dashboard
  requests), status, reports (sign off shift reports), alerts (mark seen), visitors, equipment, stations, fobs, shifts, team.
  Supervisor = people, status, reports, visitors. Manager = that + remove_people, equipment, alerts, shifts, team (limited: only roles
  below Manager whose boxes they have). Admin = everything (stations and fobs are Admin-only among built-ins).
- Migration 42: Admins (role owner) are made, changed and removed only by operators (`can_manage_role` never lets a customer give
  owner; dashboard `canManageRole`, `ADMIN_NOTE`). Employee <-> dashboard account: `employees.user_id`, `org_invites.employee_id`;
  `set_employee_access(employee, role?, custom_role?, email?)`: both null = Agent (badge only: invites cancelled, member removed),
  linked = change role, else links an existing member with that email or invites them (employee's contract). `accept_invite` links.
  Dashboard employee form "Dashboard role" (`empAccess`, `S.formAccess`, `api.setEmployeeAccess`), Team-box holders only.
- Dashboard: `PERMS`, `ROLE_PERMS`, `has(perm)`, `roleLabel`, `roleOptions` ("role:<id>" values), Team page "Your roles" (`vRoles`).
  Console team panel lists the customer's roles in its role picker (`roleName`, `splitRole`).

## Stations
- Removing a station (`remove_station` / `platform_remove_station`, migration 20) sets `removed_at` (and `revoked_at`); the row stays so
  history keeps its name. Lists leave removed stations out (`api.stations()`, `platform_fleet`, `platform_customer`); its hardware goes to "returned".
- Replacing (`platform_replace_station(station, unit)`) keeps the station, gives a new code, sets `replaced_at`; old unit -> "repair",
  new unit (must be a ready/returned station unit) -> assigned and "ready".
- History (migration 21): `public.station_events`, written by triggers on `stations` (added, set up, disconnected, replaced,
  removed, renamed, moved location/contract) plus `private.station_event()` for new codes; `by_name` is "Sonoran Point" for operators.
  Console edits go through `platform_update_station`. Taps store `station_contract_id` at insert, so moving a station
  doesn't move its past taps (RLS: `private.can_see_tap`). `station_overview` must be recreated when `stations` gets columns.

## Import (no migration)
- Dashboard `#import-equipment` (managers+) / `#import-employees` (supervisors+): paste rows or pick .csv/.xlsx (SheetJS loaded from
  jsdelivr only when an Excel file is picked). `parseTable` -> `impGuess` (columns by heading aliases in `IMP_FIELDS`) -> `impCheck`
  (same checks as the Add forms plus duplicates within the file; bad rows left out with the reason) -> `api.importEquipment/importEmployees`
  (REMOTE: bulk inserts in chunks of 200; unknown categories are created with no time limit; employees' shifts via shift_assignments).

## Labels (no migration)
- Dashboard `#labels` (`vLabels`, `S.lab`; from "Print labels" on Equipment/Employees, supervisors+): Code 128 set B (`code128Bits`,
  checked against python-barcode) or QR (qrcode-generator@1.4.4 from jsdelivr, loaded on first use; tests inject it from tests/ui/node_modules).
  Sheets in `SHEETS` (Avery 5160, 5163, 2.25x1.25 label printer), start-at position. `labelCodes` gives things without a barcode their
  asset tag / employee # if usable and free, else EQ-/EMP- + 6 chars; `printLabels` saves them first (`api.setBarcodes`; equipment needs
  managers+) then prints `#printRoot` with an @page size.

## Requests (migration 28)
- Console "Requests" (`vRequests`/`vRequest`): every contact form message (`private.contact_requests`) plus ones added by hand
  (`platform_add_request`, email optional). kind lead/support ("Help with my account" = support; sender matched to a customer -> `org_id`).
  Status new/open/waiting/won/lost/closed/spam; `assigned_to` = an operator. History in `private.contact_events`
  (created, note, reply, status, kind, assigned, customer, details). `platform_request_reply` emails from no-reply@ with reply-to = the
  operator. "Make them a customer" prefills New customer (`S.fromRequest`); creating it marks the lead won and links it.
- Console live loads use `loadSeq`/`detailSeq` so an older refresh finishing late can't put old data back.
- Live tests: `tests/ui/backend.js` kills any leftover PostgREST first (a stale one on port 54322 serves an old schema and makes tests flaky).

## Two-step sign-in for the console (migration 30)
- Console: after password sign-in, `mfaGate()` uses Supabase Auth MFA (TOTP): no verified factor -> `mfa-setup` (QR + key), else `mfa-code`;
  `mfaVerify` -> `challengeAndVerify` -> `finishSignIn()`. Server: `private.mfa_ok()` (JWT `aal` = aal2, or no JWT at all = SQL editor/tests);
  `is_platform_operator()` and `require_platform_owner()` need it; `am_platform_operator()` uses `is_platform_member()` so the console
  can ask for the code. Lost phone: remove the person's MFA factor in the Supabase dashboard (Authentication -> Users).
- Test auth mock (`tests/ui/backend.js`) does /factors enroll/challenge/verify/unenroll with real TOTP (`b.totp(secret)`).

## Moving hardware between customers (migration 31)
- `platform_move_hardware(unit, org, station?, new_station?, old 'disconnect'|'remove')`: the station it leaves is disconnected (key gone,
  so the box stops working there; it shows the setup screen on its next contact) or removed; the unit goes to the new customer as 'ready'
  (shipping fields cleared) on one of their free stations or a new one; that station gets a fresh code (returned once). Hardware event
  'moved', logs 'hardware moved out' / 'moved in'. Console: "Move to another customer" on the unit page (`moveForm`, `S.moved`).

## Closing out a customer (migration 25)
- `platform_close_customer(org)`: status cancelled, stations revoked (not removed), invites deleted, units ready/shipped/installed ->
  hardware status `returning` ("Coming back"). Members and history stay; the dashboard shows `accountNote()`. Reopen = status active + new codes.

## Uptime (migration 26)
- `public.station_outages`: a trigger on `stations.last_seen_at` saves a gap of more than 5 minutes between heartbeats (not while
  disconnected or at activation). A station offline now = open stretch since `last_seen_at`, worked out on read
  (console `uptimeOf`/`fleetHours`, dashboard `api.uptime`). Console reads `platform_outages()`.

## Barcodes (migration 24)
- `employees.barcode`, `equipment.barcode` (trimmed, upper case, unique per company). Something with only a barcode gets a tag ID
  made from it (`private.barcode_uid`: "B0C0DE" + hex of the code), so station functions take scans unchanged. Station: a
  scanner types like a keyboard; `scanToUid` maps the code to the record's NFC uid via the cache (offline too), else
  `barcodeUid`. Dashboard hides made-up IDs (`realTag`) and shows the barcode; `DB.hasBarcode` hides the fields before 24 runs.
- Adding at the station (migration 29): the capture screen takes an NFC tap, a barcode scan, or both (`saveCapture`; saves on its own once
  it has both, else the Save button). Barcode only is sent as the made-up tag ID (works on any server version); both sends
  `p_new_barcode` / `p_barcode` to `station_add_employee` / `station_add_equipment` (`private.barcode_owner` checks clashes).

## Dashboard roles
- Stored as viewer/supervisor/admin/owner (`org_members.role`, RLS, functions) but shown as View Only / Supervisor / Manager / Admin
  (`ROLE_NAME` in the dashboard; the console's customer pages say "admin" for the customer's top role). Copy follows the shown names.
  Station fob roles (employee/manager/admin) are separate. The trial-reminder email says "admin or manager" since migration 27.

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
  every operator; once per end date (`private.trial_reminders`).
- Trial pause (migration 32): `private.end_trials()` (run first by `send_trial_reminders()`, so every minute) sets a trial to
  `paused` with `paused_reason = 'trial_ended'` one day after `trial_ends_at`, emails the same people + operators, logs
  'trial ended: paused'. Per customer `organizations.pause_at_trial_end` (default on; console Account checkbox). A trigger clears
  `paused_reason` when the status changes (a pause by hand has none). Console: `pauseAt(c)` / `trialPaused(c)`; dashboard
  `accountNote()` says so (and warns managers+ in the trial's last week).

## Rules
- Run `tests/run.sh db` and `tests/run.sh ui` before pushing; add tests for new behaviour.
- Every screen works in demo mode (built-in data) and live mode (Supabase). Keep both paths in sync:
  the demo `api` object and `liveApi` / `live` in each HTML file.
- Only the Supabase publishable key may appear in code. Never commit the secret/service_role key, DB password,
  or Cloudflare token.
- Private tables live in schema `private`; customers reach data only through RLS and SECURITY DEFINER functions.
  Operator functions start with `perform private.require_operator()` (owner-only: `require_platform_owner()`).
- Plain, user-facing copy (Dez's customers are ramp/ground-handling crews). Sentence case, no jargon.
