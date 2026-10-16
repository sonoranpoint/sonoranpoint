# Equipment Tracker (working name)

A white-label NFC equipment checkout system. Employees tap their badge, then tap the
equipment, and supervisors see who has what — live, on a web dashboard.

One codebase serves every customer company. Each company gets its own branding,
terminology, employees, equipment, locations and stations, and can never see
another company's data.

## Pieces

| Folder | What it is | Status |
|---|---|---|
| `supabase/` | Database schema, security rules, station functions, Shifts module, demo data | **Started** |
| `platform/` | **Your** operator console (`console.html`): customers, new-customer setup, stations across all customers, pause/resume, your activity log. Demo data; each `api` function names its database call | **Demo version** |
| `dashboard/` | Manager web dashboard (`app.sonoranpoint.com`). `dashboard.html` runs on a week of built-in demo data; every read/change goes through one `api` object mapped to the database views and functions | **Demo version** |
| `station/` | Touchscreen app for the Pi (setup wizard, NFC taps, offline queue + sync, branding, admin menu). `station.html` is the browser test version with a built-in demo server; `pi/` has the Wi-Fi helper | **Test version** |
| `installer/` | Pi OS image + first-boot setup wizard | Not started |
| `docs/` | Product and setup docs | Not started |

## Manager dashboard

`dashboard/dashboard.html`, one page with these sections:

- **Overview**: out now, overdue, out too long, lost, stations online; "Needs attention" (one line per item); last shift report; latest activity.
- **Equipment**: search and filter (out, overdue, out too long, available, lost, maintenance). **Add** and **edit** items (name, category, asset number, NFC tag, location, time limit, alert threshold). The tag is optional: an item added without one shows up at the station under *Tag an item that has no tag*. Item panel: who has it, due time, history, mark lost / maintenance / back in service.
- **Employees**: **add** and **edit** (name, employee number, badge, shift, station fob role + PIN). Role, shift, badge, what they have out, late returns. Deactivate / reactivate (badge stops working).
- **Team access**: invite people by email as View only, Supervisor, Admin or Owner; change roles; remove people; cancel invites. Admins manage everyone except owners; a company always keeps one owner.
- **Activity**: every tap in plain language, including "Returned for …" and late returns; filter by type and time.
- **Alerts**: open and closed overdue / out-too-long alerts; mark seen with a note.
- **Shifts**: add and edit shifts (name, start/end time, days of the week, grace period, early-checkout window) and who's on each one; stop using a shift (past reports are kept). Admins edit shift times; supervisors change who's on them. Below that, the **shift reports**: per shift and day, what wasn't back and what happened next; sign off with a note.
- **Stations**: online/offline, add a station (shows its one-time activation code), new code, disconnect.
- **Settings**: name, colors, out-too-long hours, checkout rules. **Categories**: add, rename, set time limits, delete (only when no equipment uses it).

Going live = replace the demo `api` functions with Supabase queries (each function's comment names the
view or RPC it maps to: `equipment_overview`, `activity_log`, `equipment_alerts`, `shift_reports`,
`station_overview`, `set_equipment_status`, `acknowledge_alert`, `acknowledge_shift_report`,
`create_station`, `revoke_station`, `reset_station_activation`, `list_members`, `invite_member`,
`set_member_role`, `remove_member`, `cancel_invite`, `delete_category`) and add sign-in.

### Who can do what on the dashboard

| | View only | Supervisor | Admin | Owner |
|---|---|---|---|---|
| See everything (equipment, activity, alerts, reports) | ✓ | ✓ | ✓ | ✓ |
| Add / edit employees, choose who's on each shift, mark lost or maintenance, sign off alerts and shift reports | | ✓ | ✓ | ✓ |
| Add / edit equipment, categories, shifts (times and days), stations, settings | | | ✓ | ✓ |
| Invite and manage team members | | | ✓ (not owners) | ✓ |

These are separate from station fob roles. The demo has a **Preview as** switch to try each role.
Invites (`supabase/migrations/20261015000004_team_access.sql`): `invite_member` returns a one-time
token (only its hash is stored, valid 14 days); the API layer emails the link through Supabase Auth,
and `accept_invite` only works when signed in with the invited email.

## Operator console (your side)

`platform/console.html` is for you, not customers. Database: `supabase/migrations/20261015000005_platform.sql`.

- **Customers:** every company with status (trial, active, paused, cancelled), plan, stations online, people, equipment,
  taps this week, last tap. *Needs attention* lists offline stations, expired or unused activation codes, trials ending,
  and owners who haven't signed in.
- **New customer:** company name, short ID, time zone, colors, logo, their words for things (with a live preview of their
  station), trial or active, plan, station limit, modules, owner's email, and the stations you're shipping. Creates the
  company, emails the owner an invite, and makes one activation code per station. Then shows a printable setup sheet per
  box (code + packing checklist: Pi, reader, power, blank admin tag, quick-start card).
- **Customer page:** stations (new code, disconnect, add), their team and invites, usage counts, account (status, plan,
  trial end, station limit, contact, your private notes), look on their station, modules, history.
- **Pause:** their stations show *This station is paused*, record nothing, and keep their pairing. Resume and they come
  back on their own within 10 seconds; taps saved offline before the pause sync then.
- **Stations:** every station at every customer, problems first, plus which software versions are out there.
- **Privacy:** you see counts and station health, not customers' equipment, people or history.
- **Who's an operator:** the first one (you) is added once in the Supabase SQL editor:
  `insert into private.platform_operators (user_id, name, role) select id, 'Dez', 'owner' from auth.users where email = 'g.ryan@sonoranpoint.com';`
  After that, use the console's **Team** page: owners invite people by email (as Owner or Operator), change roles and
  remove people; everyone sets their own name, which is what the activity log shows. Operators do everything except
  manage the team. There's always at least one owner.
- **Only operators can create companies** (`create_organization` is operator-only). Customers can't change their own
  status, plan or station limit, and can't add stations past the limit.
- Functions: `platform_customers`, `platform_customer`, `platform_create_customer`, `platform_update_customer`,
  `platform_invite_owner`, `platform_add_station`, `platform_station_code`, `platform_revoke_station`, `platform_fleet`,
  `platform_log`, `am_platform_operator`, and for the team `platform_me`, `platform_team`, `platform_invite_operator`,
  `platform_accept_invite`, `platform_set_operator_role`, `platform_remove_operator`, `platform_cancel_operator_invite`,
  `platform_set_my_name`.
- **Hardware:** every unit you build (station kits, spare readers, screens) with its unit ID, Pi serial, parts, who built
  it, carrier and tracking, and the customer and station it went to. Status runs Building → In stock → Shipped →
  Installed, plus In repair / Returned / Retired, and each unit keeps a history with notes. A shipped unit linked to a
  station turns Installed by itself when that station is activated. Functions: `platform_hardware`,
  `platform_hardware_unit`, `platform_save_hardware`, `platform_delete_hardware` (owners only).
- Set your product name, domain, support contact and plan names at the top of `console.html` (`VENDOR`, `PLANS`) and
  `station.html` (`SUPPORT`).

## Live mode (going live)

The dashboard, console and station each run in two modes from the same file:

- **Demo** (anywhere else, like the artifact previews): built-in sample data.
- **Live** (on `*.sonoranpoint.com`, on the Pi, or with `?live`): real sign-in (Supabase Auth: password,
  emailed sign-in link, forgot password) and the real database. Every screen reads the same shapes in both
  modes; in live mode each change is applied on screen, saved to the database in order, then everything is
  reloaded. A save the database refuses is reported and the screen goes back to the database's version.
- **Invites:** the console and dashboard create the invite in the database, then Supabase emails a one-time
  sign-in link to `app.sonoranpoint.com/?invite=…`. Opening it signs the person in and accepts the invite.
- **Station on the Pi:** served from the Pi itself, it uses the hosted server (your Supabase project) and runs full screen.

**Publishing:** pushing to `main` on GitHub runs the tests and then publishes app.sonoranpoint.com and
console.sonoranpoint.com (`.github/workflows/deploy.yml`; needs the `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`
repository secrets). Database changes in `supabase/migrations/` are **not** applied automatically: run each new file
once, in order, in the Supabase SQL editor.

To build by hand: `python3 deploy/build.py` → `deploy/dist/app`, `deploy/dist/console`, `deploy/dist/station`
(each page gets a proper HTML head, plus a `_headers` file with security headers for Cloudflare Pages).
Email templates for Supabase: `deploy/email-templates.md`.

Project: `https://qzzukfjefqwifnqzxhhu.supabase.co` (publishable key in the three HTML files; it's meant to be public).
Never put the secret / service_role key in any of these files.

## Hosting plan

- **Domain:** `sonoranpoint.com`
  - `sonoranpoint.com` — public website (product info, help at `/help`)
  - `app.sonoranpoint.com` — customer dashboard (and invite links: `app.sonoranpoint.com/invite/...`)
  - `console.sonoranpoint.com` — your operator console (sign-in required; operators only)
  - `api.sonoranpoint.com` — optional custom domain for the Supabase API the stations call
  - Email: `support@sonoranpoint.com` (shown on stations), invites sent from e.g. `no-reply@sonoranpoint.com`
- **Cloudflare** — DNS, hosts the dashboard, console and website
- **Supabase** — Postgres database, logins, file storage (logos)
- Stations make **outbound HTTPS only** to the API — no port forwarding at customer sites

## How the data is organized

```
organization (a customer company: name, logo, colors, terminology)
 ├── org_members        dashboard users + role (owner / admin / supervisor / viewer)
 ├── locations          airport → terminal → equipment room (nested)
 ├── equipment_categories   Vacuum, Blower, Battery, PDA, Radio, Van Keys…
 ├── equipment          each physical item + its NFC tag + who has it right now
 ├── employees          people who check things out + their badge NFC ID
 ├── stations           each Raspberry Pi kiosk (activation code, device key)
 ├── transactions       every checkout / return — append-only history
 ├── equipment_alerts   out too long / overdue, until returned + signed off
 └── audit_log          who changed what in the dashboard
```

### Security model

- **Row-level security** on every table: a dashboard user only sees rows for
  companies they belong to. Enforced by the database, not the app.
- Roles: `viewer` (read only) < `supervisor` (manual check-ins, edit employees) <
  `admin` (equipment, stations, settings) < `owner` (everything + members).
- **Stations never log in as a user.** At activation each station gets its own
  random device key; the database stores only a hash. A lost or stolen station is
  cut off by revoking it from the dashboard.
- Transactions are **append-only** — nobody can edit or delete checkout history.

### Offline sync

Each station queues taps locally when the network is down and uploads later.
Every event carries a `client_txn_id` generated on the station, so re-uploading
the same event twice is harmless. Events also carry the time they *actually*
happened (`occurred_at`); an old event arriving late is recorded in history but
doesn't overwrite newer custody info. Conflicts (e.g. an item checked out by
someone while the system thought someone else had it) are recorded and flagged
rather than rejected — the physical tap is the truth.

### Checkout rules at the station

What tapping an item means (decided by the server, same rules offline):

| Item is… | Tap with your badge | Tap with no badge |
|---|---|---|
| In the room | Checked out to you | Shows **Available**, asks for a badge to check it out |
| Checked out to you | Returned | Shows who has it, since when, due time |
| Checked out to someone else | **Returned for them** (company setting, on by default); tap again to take it. If that setting is off: refused, it must be returned first | Shows who has it; badge to return it |
| Lost | **Returned as found**, back to available | Shows **Lost**, "Found it? Tap your badge" |
| In maintenance / retired | Refused | Shows it can't be checked out |

- Company settings: `allow_return_by_other` (default on) and `allow_checkout_while_held`
  (default **off**, so nobody can take an item someone else has).
- Refused taps aren't recorded. Taps a station saved while offline are always
  recorded (they already happened) and flagged if they broke a rule.
- Supervisors mark items lost, send them to maintenance, or put them back in
  service with `set_equipment_status`. Admins can retire items.
- `station_item_status` powers the tap-with-no-badge lookup.

### Activity log

Every checkout and return records **who tapped** (`employee_id`) and **who had the
item at that moment** (`previous_employee_id`). The `activity_log` view turns that
into plain language for the dashboard:

| By | Description |
|---|---|
| Jordan Lee | Checked out |
| Sam Patel | Returned for Jordan Lee |
| Sam Patel | Returned as found |
| Alex Rivera | Checked out (was still with Sam Patel) |

…plus the item, category, time, and place (station name, or "Dashboard" with the
supervisor who made a correction). History can't be edited or deleted.

### Checkout time limits

Every **category** picks one rule, and every **item** can follow its category or
pick its own:

| Rule | Due time |
|---|---|
| **Hours** | A set number of hours after checkout |
| **End of shift** | When the employee's shift ends (needs the Shifts module) |
| **No limit** | Never due |

Item setting options: *Follow category* (default), *Hours* (its own number),
*End of shift*, or *No limit*. An item's own setting wins over its category.

**End of shift details**
- Uses the shift the employee is working when they check out, including up to
  60 min before it starts (adjustable per shift), so grabbing a radio before
  clock-in counts. Overnight shifts work. On a double shift, the later end wins.
- If they aren't on a shift, the item falls back to a number of hours (if one is
  set) and the checkout is marked `no_active_shift`. No hours set = no due time.
- If the Shifts module is off, end-of-shift items use their fallback hours.

The due time is set at checkout, so changing a rule affects the next checkout,
not items already out. Each tap returns `due_rule` so the station can say
"Due at end of your shift (1:30 PM)". `equipment_overview` shows each item's rule.

### Out-too-long alerts (extended checkout)

Separate from due times: flags anything that has simply been out a long time.

- Threshold: **9 hours** by default per company (can be changed or turned off),
  overridable per category and per item. Item beats category beats company.
- Every 5 minutes the system raises alerts for items past that threshold
  (`extended_checkout`) and items past their due time (`overdue`). One alert per
  checkout, no duplicates.
- Alerts close themselves when the item is returned or changes hands, and the
  return is marked `returned_after_extended` in the history.
- Supervisors sign off on alerts with a note (`acknowledge_alert`).
- `equipment_overview` shows `hours_out` and `is_extended` for each item.

## First-time setup (what a new customer sees)

The station walks the customer through everything on screen. Each station ships with an
**admin tag** in the box.

0. **Welcome**: what to have ready (Wi-Fi password or cable, activation code, admin tag).
1. **Wi-Fi**: pick a network and type the password on screen, or *Skip* (network cable / later).
2. **Activation code**: connects the station to the company and loads its name, logo and colors.
3. **Admin tag**: tap the tag from the box, enter a name and PIN (twice). It becomes an admin fob.
   If nothing is read within 20 seconds, the screen shows how to hold the tag to the reader.
   Allowed once per activation, within 60 minutes (`station_claim_admin_tag`); skippable only if
   the company already has an admin fob (`activate_station` returns `has_admin_fob`).
4. **Get started checklist**: add employees, add equipment (opens those Admin menu screens
   directly, no second PIN), and a 3-screen "how checkout works" tour. Each item ticks off. Optional.

- **Need help?** on every step shows tips for that step plus your support contact. Set it in
  the `SUPPORT` constant at the top of `station.html` before shipping.
- **Unplugged mid-setup?** The station resumes at the step it was on.
- Wi-Fi and server settings later: **Admin menu › Station** (admins only): change Wi-Fi, switch
  between the hosted server (default) and a company's own server (re-activation required), sync,
  unpair. On the Pi, Wi-Fi goes through `station/pi/wifi_helper.py` (see `station/pi/README.md`).

## Manager and admin fobs (admin menu at the station)

A fob is an employee badge with a **station role** of `manager` or `admin`. It works like
a normal badge (tap it, check equipment in and out). Their session screen has an extra
**Admin menu** button; tapping it asks for the PIN, then opens the admin menu. No laptop needed.

| Can do | Manager | Admin |
|---|---|---|
| Add an employee, then tap their new badge to register it | ✓ | ✓ |
| Add equipment (pick category, name auto-numbered), then tap its new tag | ✓ | ✓ |
| Tap an item: mark lost, send to maintenance, back in service, give it a new tag | ✓ | ✓ |
| Tag an item that was added on the dashboard without a tag | ✓ | ✓ |
| Replace a lost badge (regular employees) | ✓ | ✓ |
| Check out equipment with their own fob | ✓ | ✓ |
| Make someone a manager or admin, set fob PINs, deactivate / reactivate | | ✓ |
| Replace a manager's or admin's fob, retire equipment, unpair the station | | ✓ |

- **PINs:** 4–8 digits, stored hashed in `private.staff_pins` (unreachable from the API).
  5 wrong tries lock that fob for 15 minutes. NFC badge IDs can be copied, which is
  why staff fobs need a PIN.
- **Safety checks:** a badge or tag can't be registered twice (the station says who or
  what already has it), a badge can't be used as an equipment tag or vice versa, and
  an admin can't demote or deactivate themselves by accident.
- **Logged:** every change is in `audit_log` with `actor_employee_id` = the fob holder.
- Admin menu needs a connection, has an on-screen keyboard (the Pi runs as a kiosk),
  and closes after 90 seconds without a tap.
- Functions: `station_staff_login`, `station_add_employee`, `station_add_equipment`,
  `station_set_item_status`, `station_replace_uid`, `station_update_employee`;
  dashboard: `set_employee_station_role`.
- Demo fobs: **Dana Brooks** (manager, PIN 2468), **Morgan Reyes** (admin, PIN 1357).

## Optional module: Shifts

Switched on per company (`'shifts'` in `organizations.enabled_modules`). Modules are
turned on by us, not by customers, since they can be sold as add-ons.

- **Shifts:** name, start/end time in the company's timezone (overnight shifts that
  cross midnight work), which days they run, and a grace period (default 15 min).
- **Assignments:** supervisors put employees on one or more shifts.
- **End-of-shift report:** everything checked out by that shift's employees that
  wasn't back by shift end + grace. Each item shows who had it and what happened next:
  `not_returned` (still out), `returned_late` (when, by whom), or `taken_by_other`.
  Built from the full history, so it's accurate for past dates and late station uploads.
- **Saved reports:** generated automatically every 5 minutes after each shift ends
  (via `pg_cron` on Supabase), so the record doesn't change afterwards.
  Supervisors sign off with a note (`acknowledge_shift_report`).
- `shift_report(shift, date)` gives any report on demand, including a live preview of
  a shift still in progress.

## Station workflow (database functions)

| Function | Called by | Purpose |
|---|---|---|
| `create_organization(name, slug)` | Signed-in user | New company; caller becomes owner |
| `create_station(org, name, location)` | Admin | Registers a station, returns a one-time activation code |
| `activate_station(code)` | Station setup wizard | Swaps the code for the station's permanent device key |
| `station_config(key)` | Station | Branding, terminology, settings to display |
| `station_tap(key, txn_id, badge, item, when)` | Station | Records a checkout or return (auto-detects which) |
| `station_item_status(key, item)` | Station | Tap an item with no badge: in or out, and who has it |
| `set_equipment_status(item, status)` | Supervisor | Mark lost, maintenance, or back in service |
| `station_heartbeat(key)` | Station | "I'm online" for the dashboard |
| `revoke_station(station)` | Admin | Kills a station's key |

## Running it locally

With the [Supabase CLI](https://supabase.com/docs/guides/cli):

```bash
supabase init        # once
supabase start
supabase db reset    # applies migrations + seed.sql
```

The demo company ("Demo Air Services") gets a station with activation code `DEMO-0001`.

### Tests

`supabase/tests/smoke_test.sql` runs 243 scenarios against plain Postgres 15+
(activation, checkout/return, duplicate uploads, conflicts, late offline sync,
clock skew, time limits, extended/overdue alerts, lost & found, checkout rules, activity log, manager/admin fobs and PINs, shipped admin tag setup, shift reports, company-to-company isolation, role permissions, team invites and roles, category delete, operator console (create customer, pause/resume, station limits, privacy, operator team and roles, hardware tracking), revoking a station):

```bash
tests/run.sh db     # database: migrations + smoke test on a scratch database
tests/run.sh ui     # every screen in demo mode (jsdom; no database needed)
tests/run.sh        # both, plus the screens against a real database if .tools/postgrest exists
```

The screen tests live in `tests/ui/` (`console.js`, `dashboard1-3.js`, `station1-9.js`, and `*_live.js`, which start
Postgres + PostgREST + a small Supabase Auth stand-in from `tests/ui/backend.js`). GitHub runs `db` and `ui` on every push.

### Notes for the API layer (next step)

- Add rate limiting in front of `activate_station` (codes are ~40 bits and expire in 7 days, but guessing should still be throttled).
- Stations call the `station_*` functions with the project's public anon key + their own device key.
