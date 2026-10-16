-- =====================================================================
-- Equipment Tracker — core schema
-- Multi-company (multi-tenant) NFC equipment checkout.
--
-- Target: Supabase (Postgres 15+). Uses auth.uid() and the standard
-- Supabase roles: anon, authenticated, service_role.
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- Internal helpers live in "private", which Supabase does NOT expose
-- through its API. Only the public.* functions are callable remotely.
create schema if not exists private;
grant usage on schema private to anon, authenticated;

-- ---------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------
-- Order matters: comparisons like role >= 'supervisor' use this order.
create type public.member_role as enum ('viewer', 'supervisor', 'admin', 'owner');

create type public.equipment_status as enum
  ('available', 'checked_out', 'maintenance', 'retired', 'lost');

create type public.txn_action as enum ('checkout', 'checkin');
create type public.time_limit_type as enum ('none', 'hours', 'shift_end');
create type public.txn_source as enum ('station', 'dashboard');
-- What a badge can do at the station: normal checkouts, or open the staff menu.
create type public.station_role as enum ('employee', 'manager', 'admin');

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------

-- NFC UIDs arrive in many formats ("04:A2:3B…", "04a23b…").
-- Store them one way: uppercase hex, no separators.
create function private.normalize_uid(p_uid text)
returns text language sql immutable as $$
  select nullif(upper(regexp_replace(coalesce(p_uid, ''), '[^0-9A-Fa-f]', '', 'g')), '')
$$;

create function private.sha256_hex(p_text text)
returns text language sql immutable set search_path = extensions, public as $$
  select encode(extensions.digest(p_text, 'sha256'), 'hex')
$$;

-- Human-friendly activation code, e.g. "K7QM-3XPA".
-- No 0/O/1/I/L so it's easy to read off a screen and type.
create function private.new_activation_code()
returns text language plpgsql volatile set search_path = extensions, public as $$
declare
  chars constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  bytes bytea := extensions.gen_random_bytes(8);
  code  text := '';
begin
  for i in 0..7 loop
    code := code || substr(chars, (get_byte(bytes, i) % length(chars)) + 1, 1);
    if i = 3 then code := code || '-'; end if;
  end loop;
  return code;
end $$;

create function private.normalize_code(p_code text)
returns text language sql immutable as $$
  select upper(regexp_replace(coalesce(p_code, ''), '[^0-9A-Za-z]', '', 'g'))
$$;

-- ---------------------------------------------------------------------
-- Organizations (customer companies)
-- ---------------------------------------------------------------------
create table public.organizations (
  id              uuid primary key default gen_random_uuid(),
  name            text not null check (length(trim(name)) > 0),
  slug            text not null unique check (slug ~ '^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$'),
  logo_url        text,
  primary_color   text not null default '#1F4E79' check (primary_color ~ '^#[0-9A-Fa-f]{6}$'),
  accent_color    text not null default '#F2A900' check (accent_color  ~ '^#[0-9A-Fa-f]{6}$'),
  timezone        text not null default 'America/Phoenix',
  -- Alert when anything has been out longer than this, whatever its due time.
  -- null = off. Categories and items can override it.
  extended_checkout_hours numeric(6,2) default 9 check (extended_checkout_hours > 0),
  -- Words shown in the station + dashboard UI ("Equipment" vs "Tools", etc.)
  terminology     jsonb not null default '{
    "equipment": "Equipment",
    "equipment_plural": "Equipment",
    "employee": "Employee",
    "employee_plural": "Employees",
    "checkout": "Check Out",
    "checkin": "Return"
  }'::jsonb,
  settings        jsonb not null default '{
    "allow_return_by_other": true,
    "allow_checkout_while_held": false
  }'::jsonb,
  -- Optional modules switched on per customer: 'maintenance', 'battery', 'reservations', ...
  enabled_modules text[] not null default '{}',
  created_at      timestamptz not null default now()
);

-- Dashboard users and their role in each company.
create table public.org_members (
  org_id     uuid not null references public.organizations(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  role       public.member_role not null default 'viewer',
  created_at timestamptz not null default now(),
  primary key (org_id, user_id)
);
create index on public.org_members (user_id);

-- Is the signed-in user a member of this org with at least this role?
-- SECURITY DEFINER so policies on org_members don't recurse.
create function private.has_org_role(p_org uuid, p_min public.member_role default 'viewer')
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.org_members
    where org_id = p_org and user_id = auth.uid() and role >= p_min
  )
$$;
grant execute on function private.has_org_role(uuid, public.member_role) to authenticated;

-- ---------------------------------------------------------------------
-- Locations: airport → terminal → equipment room (any depth)
-- ---------------------------------------------------------------------
create table public.locations (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references public.organizations(id) on delete cascade,
  parent_id  uuid,
  name       text not null,
  kind       text,           -- free text: 'airport', 'terminal', 'room', ...
  created_at timestamptz not null default now(),
  unique (id, org_id),
  foreign key (parent_id, org_id) references public.locations(id, org_id) on delete cascade
);
create index on public.locations (org_id);

-- ---------------------------------------------------------------------
-- Equipment categories
-- ---------------------------------------------------------------------
create table public.equipment_categories (
  id                     uuid primary key default gen_random_uuid(),
  org_id                 uuid not null references public.organizations(id) on delete cascade,
  name                   text not null,
  icon                   text,          -- icon key for the UI
  -- Time limit for items in this category (items can override it individually):
  --   'none'      = no due time
  --   'hours'     = due default_checkout_hours after checkout
  --   'shift_end' = due when the employee's shift ends (Shifts module);
  --                 default_checkout_hours, if set, is the fallback when they aren't on a shift
  time_limit_type        public.time_limit_type not null default 'none',
  default_checkout_hours numeric(6,2) check (default_checkout_hours > 0),
  extended_alert_hours   numeric(6,2) check (extended_alert_hours > 0),  -- null = company default
  sort_order             int not null default 0,
  created_at             timestamptz not null default now(),
  unique (id, org_id),
  unique (org_id, name),
  constraint category_limit_needs_hours
    check (time_limit_type <> 'hours' or default_checkout_hours is not null)
);

-- How long an individual item may be checked out:
--   'category'  = use its category's setting (default)
--   'hours'     = this item's own checkout_hours
--   'shift_end' = end of the employee's shift (checkout_hours, if set, is the fallback)
--   'none'      = never due
create type public.time_limit_mode as enum ('category', 'hours', 'shift_end', 'none');

-- Single source of truth for an item's time limit.
-- Returns the rule ('none' | 'hours' | 'shift_end') and the hours to use
-- (for 'shift_end' the hours are the fallback when the employee isn't on a shift).
create function private.resolve_time_limit(
  p_mode public.time_limit_mode, p_item_hours numeric,
  p_cat_type public.time_limit_type, p_cat_hours numeric,
  out rule text, out hours numeric)
language sql immutable as $$
  select r.rule,
         case r.rule
           when 'none'  then null
           when 'hours' then case when p_mode = 'hours' then p_item_hours else p_cat_hours end
           else coalesce(p_item_hours, p_cat_hours)
         end
  from (select case p_mode
                 when 'category' then coalesce(p_cat_type::text, 'none')
                 else p_mode::text end as rule) r
$$;

-- When does this employee's current shift end? null = not on a shift right now
-- (or the Shifts module isn't on). Replaced by the Shifts module migration.
create function private.employee_shift_end(p_employee uuid, p_at timestamptz)
returns timestamptz language sql stable as $$ select null::timestamptz $$;

-- ---------------------------------------------------------------------
-- Employees (people who check equipment out — NOT dashboard logins)
-- ---------------------------------------------------------------------
create table public.employees (
  id              uuid primary key default gen_random_uuid(),
  org_id          uuid not null references public.organizations(id) on delete cascade,
  employee_number text,
  first_name      text not null,
  last_name       text not null default '',
  badge_uid       text check (badge_uid = private.normalize_uid(badge_uid)),
  station_role    public.station_role not null default 'employee',  -- manager/admin fobs open the staff menu
  location_id     uuid,
  active          boolean not null default true,
  created_at      timestamptz not null default now(),
  unique (id, org_id),
  unique (org_id, badge_uid),
  unique (org_id, employee_number),
  foreign key (location_id, org_id) references public.locations(id, org_id) on delete set null (location_id)
);

-- Staff fob PINs (hashed), kept out of reach of every API role.
create table private.staff_pins (
  employee_id  uuid primary key references public.employees(id) on delete cascade,
  pin_hash     text not null,
  failures     int not null default 0,
  locked_until timestamptz
);

-- ---------------------------------------------------------------------
-- Equipment
-- ---------------------------------------------------------------------
create table public.equipment (
  id                  uuid primary key default gen_random_uuid(),
  org_id              uuid not null references public.organizations(id) on delete cascade,
  category_id         uuid,
  home_location_id    uuid,
  name                text not null,             -- "Vacuum 07"
  asset_tag           text,
  serial_number       text,
  nfc_uid             text check (nfc_uid = private.normalize_uid(nfc_uid)),
  status              public.equipment_status not null default 'available',
  time_limit_mode     public.time_limit_mode not null default 'category',
  checkout_hours      numeric(6,2) check (checkout_hours > 0),   -- for 'hours', or fallback for 'shift_end'
  extended_alert_hours numeric(6,2) check (extended_alert_hours > 0),  -- null = category, then company default
  condition           text,
  notes               text,
  -- Current custody, maintained by private.record_event — not edited directly.
  current_employee_id uuid,
  checked_out_at      timestamptz,
  due_at              timestamptz,
  last_event_at       timestamptz,
  created_at          timestamptz not null default now(),
  unique (id, org_id),
  unique (org_id, nfc_uid),
  unique (org_id, asset_tag),
  foreign key (category_id, org_id)         references public.equipment_categories(id, org_id) on delete set null (category_id),
  foreign key (home_location_id, org_id)    references public.locations(id, org_id) on delete set null (home_location_id),
  foreign key (current_employee_id, org_id) references public.employees(id, org_id) on delete set null (current_employee_id),
  constraint item_limit_needs_hours check (time_limit_mode <> 'hours' or checkout_hours is not null)
);
create index on public.equipment (org_id, status);
create index on public.equipment (current_employee_id) where current_employee_id is not null;

-- ---------------------------------------------------------------------
-- Stations (Raspberry Pi kiosks)
-- ---------------------------------------------------------------------
create table public.stations (
  id               uuid primary key default gen_random_uuid(),
  org_id           uuid not null references public.organizations(id) on delete cascade,
  location_id      uuid,
  name             text not null,             -- "Equipment Room 01"
  activated_at     timestamptz,
  revoked_at       timestamptz,
  last_seen_at     timestamptz,
  software_version text,
  admin_claimed_at timestamptz,  -- the admin tag shipped with this station was registered during setup
  created_at       timestamptz not null default now(),
  unique (id, org_id),
  foreign key (location_id, org_id) references public.locations(id, org_id) on delete set null (location_id)
);

-- Secrets kept in their own table with NO access policies at all:
-- only the SECURITY DEFINER functions below can read them.
create table private.station_keys (
  station_id               uuid primary key references public.stations(id) on delete cascade,
  device_key_hash          text unique,
  activation_code_hash     text unique,
  activation_expires_at    timestamptz
);

-- ---------------------------------------------------------------------
-- Transactions: append-only checkout / return history
-- ---------------------------------------------------------------------
create table public.transactions (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references public.organizations(id) on delete cascade,
  equipment_id  uuid not null,
  employee_id   uuid not null,                  -- who tapped (checked it out / brought it back)
  previous_employee_id uuid,                    -- who had it at that moment (a return "for" someone)
  station_id    uuid,
  action        public.txn_action not null,
  source        public.txn_source not null,
  occurred_at   timestamptz not null,           -- when the tap actually happened
  received_at   timestamptz not null default now(),  -- when the server got it
  client_txn_id uuid,                           -- generated on the station; makes re-uploads safe
  recorded_by   uuid references auth.users(id), -- dashboard user, for manual entries
  flags         text[] not null default '{}',   -- 'conflict_already_held', 'late_sync', ...
  notes         text,
  foreign key (equipment_id, org_id) references public.equipment(id, org_id),
  foreign key (employee_id, org_id)  references public.employees(id, org_id),
  foreign key (previous_employee_id, org_id) references public.employees(id, org_id),
  foreign key (station_id, org_id)   references public.stations(id, org_id),
  unique (station_id, client_txn_id)
);
create index on public.transactions (org_id, occurred_at desc);
create index on public.transactions (equipment_id, occurred_at desc);
create index on public.transactions (employee_id, occurred_at desc);
create index on public.transactions (org_id) where flags <> '{}';

-- ---------------------------------------------------------------------
-- Alerts: items out too long (extended) or past their due time (overdue).
-- Raised by private.generate_equipment_alerts() on a schedule; closed
-- automatically when the item is returned or changes hands.
-- ---------------------------------------------------------------------
create type public.alert_kind as enum ('extended_checkout', 'overdue');

create table public.equipment_alerts (
  id              uuid primary key default gen_random_uuid(),
  org_id          uuid not null references public.organizations(id) on delete cascade,
  equipment_id    uuid not null,
  employee_id     uuid,
  kind            public.alert_kind not null,
  checked_out_at  timestamptz not null,     -- identifies which checkout this is about
  threshold_at    timestamptz not null,     -- when it crossed the line (due time, or out + N hours)
  raised_at       timestamptz not null default now(),
  resolved_at     timestamptz,              -- item came back / changed hands
  acknowledged_by uuid references auth.users(id),
  acknowledged_at timestamptz,
  notes           text,
  unique (equipment_id, kind, checked_out_at),
  foreign key (equipment_id, org_id) references public.equipment(id, org_id) on delete cascade,
  foreign key (employee_id, org_id)  references public.employees(id, org_id) on delete set null (employee_id)
);
create index on public.equipment_alerts (org_id) where resolved_at is null;
create index on public.equipment_alerts (org_id, raised_at desc);

-- How many hours before an item counts as "out too long": item, then category, then company.
create function private.extended_hours(p_equipment uuid)
returns numeric language sql stable security definer set search_path = public as $$
  select coalesce(e.extended_alert_hours, c.extended_alert_hours, o.extended_checkout_hours)
  from public.equipment e
  join public.organizations o on o.id = e.org_id
  left join public.equipment_categories c on c.id = e.category_id
  where e.id = p_equipment
$$;

-- ---------------------------------------------------------------------
-- Audit log: who changed what from the dashboard
-- ---------------------------------------------------------------------
create table public.audit_log (
  id          bigint generated always as identity primary key,
  org_id      uuid,   -- no FK on purpose: the log outlives deleted rows/orgs
  actor_id    uuid,      -- dashboard user
  actor_employee_id uuid, -- or the manager/admin fob used at a station
  table_name  text not null,
  row_id      uuid,
  operation   text not null,
  old_data    jsonb,
  new_data    jsonb,
  at          timestamptz not null default now()
);
create index on public.audit_log (org_id, at desc);

create function private.audit()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  rec jsonb := to_jsonb(coalesce(new, old));
  v_org uuid := case when tg_table_name = 'organizations'
                     then (rec->>'id')::uuid else (rec->>'org_id')::uuid end;
begin
  insert into public.audit_log (org_id, actor_id, actor_employee_id, table_name, row_id, operation, old_data, new_data)
  values (
    v_org, auth.uid(), nullif(current_setting('app.actor_employee', true), '')::uuid, tg_table_name,
    case when tg_table_name = 'org_members' then (rec->>'user_id')::uuid else (rec->>'id')::uuid end,
    tg_op,
    case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end,
    case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end
  );
  return null;
end $$;

-- Equipment custody columns change on every tap; only audit real edits to equipment.
create trigger audit_organizations after insert or update or delete on public.organizations for each row execute function private.audit();
create trigger audit_org_members   after insert or update or delete on public.org_members   for each row execute function private.audit();
create trigger audit_locations     after insert or update or delete on public.locations     for each row execute function private.audit();
create trigger audit_categories    after insert or update or delete on public.equipment_categories for each row execute function private.audit();
create trigger audit_employees     after insert or update or delete on public.employees     for each row execute function private.audit();
create trigger audit_stations      after insert or delete on public.stations for each row execute function private.audit();
create trigger audit_equipment     after insert or delete on public.equipment for each row execute function private.audit();
create trigger audit_equipment_upd after update on public.equipment for each row
  when (row(old.name, old.category_id, old.home_location_id, old.asset_tag, old.serial_number,
            old.nfc_uid, old.status, old.time_limit_mode, old.checkout_hours, old.extended_alert_hours,
            old.condition, old.notes)
        is distinct from
        row(new.name, new.category_id, new.home_location_id, new.asset_tag, new.serial_number,
            new.nfc_uid, new.status, new.time_limit_mode, new.checkout_hours, new.extended_alert_hours,
            new.condition, new.notes))
  execute function private.audit();

-- Accept NFC IDs in any format from the dashboard / imports; store them normalized.
create function private.normalize_uid_columns()
returns trigger language plpgsql as $$
begin
  if tg_table_name = 'employees' then
    new.badge_uid := private.normalize_uid(new.badge_uid);
  else
    new.nfc_uid := private.normalize_uid(new.nfc_uid);
  end if;
  return new;
end $$;
create trigger normalize_badge before insert or update on public.employees
  for each row execute function private.normalize_uid_columns();
create trigger normalize_tag before insert or update on public.equipment
  for each row execute function private.normalize_uid_columns();

-- =====================================================================
-- Row-level security
-- =====================================================================
alter table public.organizations        enable row level security;
alter table public.org_members          enable row level security;
alter table public.locations            enable row level security;
alter table public.equipment_categories enable row level security;
alter table public.employees            enable row level security;
alter table public.equipment            enable row level security;
alter table public.stations             enable row level security;
alter table public.transactions         enable row level security;
alter table public.audit_log            enable row level security;
alter table private.station_keys        enable row level security;  -- no policies = no access

-- Organizations: members read; admins edit branding/settings. Created via create_organization().
create policy org_select on public.organizations for select to authenticated
  using (private.has_org_role(id));
create policy org_update on public.organizations for update to authenticated
  using (private.has_org_role(id, 'admin')) with check (private.has_org_role(id, 'admin'));

-- Members: everyone in the org sees the member list; only owners change it.
create policy members_select on public.org_members for select to authenticated
  using (private.has_org_role(org_id));
create policy members_write on public.org_members for all to authenticated
  using (private.has_org_role(org_id, 'owner')) with check (private.has_org_role(org_id, 'owner'));

-- Locations, categories, equipment, stations: read = member, write = admin.
create policy loc_select on public.locations for select to authenticated using (private.has_org_role(org_id));
create policy loc_write  on public.locations for all to authenticated
  using (private.has_org_role(org_id, 'admin')) with check (private.has_org_role(org_id, 'admin'));

create policy cat_select on public.equipment_categories for select to authenticated using (private.has_org_role(org_id));
create policy cat_write  on public.equipment_categories for all to authenticated
  using (private.has_org_role(org_id, 'admin')) with check (private.has_org_role(org_id, 'admin'));

create policy eq_select on public.equipment for select to authenticated using (private.has_org_role(org_id));
create policy eq_write  on public.equipment for all to authenticated
  using (private.has_org_role(org_id, 'admin')) with check (private.has_org_role(org_id, 'admin'));

create policy st_select on public.stations for select to authenticated using (private.has_org_role(org_id));
create policy st_update on public.stations for update to authenticated
  using (private.has_org_role(org_id, 'admin')) with check (private.has_org_role(org_id, 'admin'));
create policy st_delete on public.stations for delete to authenticated
  using (private.has_org_role(org_id, 'admin'));
-- (stations are inserted via create_station() so an activation code is always issued)

-- Employees: supervisors manage the roster.
create policy emp_select on public.employees for select to authenticated using (private.has_org_role(org_id));
create policy emp_write  on public.employees for all to authenticated
  using (private.has_org_role(org_id, 'supervisor')) with check (private.has_org_role(org_id, 'supervisor'));

-- Transactions: read-only from the table. New rows only through station_tap() / dashboard_record_event().
create policy txn_select on public.transactions for select to authenticated using (private.has_org_role(org_id));

-- Audit log: admins only.
create policy audit_select on public.audit_log for select to authenticated using (private.has_org_role(org_id, 'admin'));

-- Custody columns are maintained by the system; dashboard users may not set them directly.
revoke insert, update on public.equipment from anon, authenticated;
grant insert (org_id, category_id, home_location_id, name, asset_tag, serial_number, nfc_uid, status,
              time_limit_mode, checkout_hours, extended_alert_hours, condition, notes)
  on public.equipment to authenticated;
grant update (category_id, home_location_id, name, asset_tag, serial_number, nfc_uid, status,
              time_limit_mode, checkout_hours, extended_alert_hours, condition, notes)
  on public.equipment to authenticated;
revoke insert, update, delete on public.transactions, public.audit_log from anon, authenticated;
revoke insert, update on public.stations from anon, authenticated;
-- Station roles (who can open the staff menu) are changed only by admins, via set_employee_station_role().
revoke insert, update on public.employees from anon, authenticated;
grant insert (org_id, employee_number, first_name, last_name, badge_uid, location_id, active) on public.employees to authenticated;
grant update (employee_number, first_name, last_name, badge_uid, location_id, active) on public.employees to authenticated;
alter table private.staff_pins enable row level security;   -- no policies: no API access
grant update (name, location_id) on public.stations to authenticated;

-- =====================================================================
-- Core event recording (internal)
-- One place decides what a tap means, so stations and the dashboard
-- can never disagree.
-- =====================================================================
create function private.record_event(
  p_org           uuid,
  p_equipment     uuid,
  p_employee      uuid,
  p_action        public.txn_action,   -- null = decide automatically
  p_occurred_at   timestamptz,
  p_source        public.txn_source,
  p_station       uuid default null,
  p_client_txn_id uuid default null,
  p_recorded_by   uuid default null,
  p_notes         text default null,
  -- true = apply the company's checkout rules and refuse what they don't allow
  -- (a live tap at a station). false = record what physically happened
  -- (a tap a station saved while offline, or a supervisor's correction).
  p_enforce       boolean default false
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  eq        public.equipment;
  org       public.organizations;
  v_action  public.txn_action := p_action;
  v_when    timestamptz := coalesce(p_occurred_at, now());
  v_flags   text[] := '{}';
  v_is_latest boolean;
  v_hours   numeric;
  v_rule    text;
  v_txn     uuid;
  v_due     timestamptz;
  v_allow_return_other boolean;
  v_allow_take_held    boolean;
  v_block   text;
begin
  -- Lock the item so two stations tapping the same item at once are serialized.
  select * into eq from public.equipment where id = p_equipment and org_id = p_org for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'unknown_equipment');
  end if;
  select * into org from public.organizations where id = p_org;
  v_allow_return_other := coalesce((org.settings->>'allow_return_by_other')::boolean, true);
  v_allow_take_held    := coalesce((org.settings->>'allow_checkout_while_held')::boolean, false);

  -- Station clocks drift. Don't accept events "from the future".
  if v_when > now() + interval '5 minutes' then
    v_flags := array_append(v_flags, 'clock_skew');
    v_when := now();
  end if;

  v_is_latest := eq.last_event_at is null or v_when >= eq.last_event_at;

  -- Kiosk flow: what does tapping this item mean?
  --   lost item            -> return it (found)
  --   I have it            -> return it
  --   someone else has it  -> return it for them (if the company allows), otherwise a checkout attempt
  --   it's in the room     -> check it out
  if v_action is null then
    v_action := case
      when eq.status = 'lost' then 'checkin'
      when eq.current_employee_id = p_employee then 'checkin'
      when eq.current_employee_id is not null and v_allow_return_other then 'checkin'
      else 'checkout' end;
  end if;

  -- Company rules for live taps. Refused taps aren't recorded; the station explains why.
  if p_enforce and v_is_latest then
    if v_action = 'checkout' then
      v_block := case
        when eq.status in ('maintenance', 'retired') then 'item_unavailable'
        when eq.status = 'lost' then 'item_lost'
        when eq.current_employee_id is not null and eq.current_employee_id <> p_employee
             and not v_allow_take_held then 'checked_out_to_other' end;
    elsif eq.current_employee_id is not null and eq.current_employee_id <> p_employee
          and not v_allow_return_other and eq.status <> 'lost' then
      v_block := 'not_your_item';
    end if;
    if v_block is not null then
      return jsonb_build_object(
        'ok', false, 'error', v_block,
        'equipment', jsonb_build_object('id', eq.id, 'name', eq.name, 'status', eq.status),
        'holder', (select jsonb_build_object('id', e.id, 'name', trim(e.first_name || ' ' || e.last_name))
                   from public.employees e where e.id = eq.current_employee_id),
        'checked_out_at', eq.checked_out_at, 'due_at', eq.due_at);
    end if;
  end if;

  if not v_is_latest then
    -- An older event uploaded after newer ones (offline station catching up).
    -- Keep it in history, but don't let it overwrite current custody.
    v_flags := array_append(v_flags, 'late_sync');
  else
    if v_action = 'checkout' then
      if eq.current_employee_id is not null and eq.current_employee_id <> p_employee then
        v_flags := array_append(v_flags, 'conflict_already_held');  -- previous holder never returned it
      end if;
      if eq.status in ('maintenance', 'retired', 'lost') then
        v_flags := array_append(v_flags, 'item_' || eq.status::text);
      end if;

      -- Work out when it's due.
      select l.rule, l.hours into v_rule, v_hours
        from (select 1) one
        left join public.equipment_categories c on c.id = eq.category_id
        cross join lateral private.resolve_time_limit(eq.time_limit_mode, eq.checkout_hours,
                                                      c.time_limit_type, c.default_checkout_hours) l;
      if v_rule = 'shift_end' then
        v_due := private.employee_shift_end(p_employee, v_when);
        if v_due is null then
          -- Not on a shift right now: fall back to hours if any are set.
          v_flags := array_append(v_flags, 'no_active_shift');
          v_rule := case when v_hours is not null then 'hours' else 'none' end;
        end if;
      end if;
      if v_rule = 'hours' then
        v_due := v_when + make_interval(secs => v_hours * 3600);
      end if;
    else
      if eq.status = 'lost' then
        v_flags := array_append(v_flags, 'found_lost_item');
      elsif eq.current_employee_id is null then
        v_flags := array_append(v_flags, 'return_not_checked_out');
      elsif eq.current_employee_id <> p_employee then
        v_flags := array_append(v_flags, 'returned_by_other');
      end if;
      -- Was it out longer than the "extended" limit?
      if eq.checked_out_at is not null
         and v_when - eq.checked_out_at > make_interval(secs => private.extended_hours(eq.id) * 3600) then
        v_flags := array_append(v_flags, 'returned_after_extended');
      end if;
    end if;
  end if;

  insert into public.transactions
    (org_id, equipment_id, employee_id, previous_employee_id, station_id, action, source, occurred_at,
     client_txn_id, recorded_by, flags, notes)
  values
    (p_org, p_equipment, p_employee,
     case when v_is_latest then eq.current_employee_id end,   -- unknown for late uploads
     p_station, v_action, p_source, v_when,
     p_client_txn_id, p_recorded_by, v_flags, p_notes)
  returning id into v_txn;

  if v_is_latest then
    if v_action = 'checkout' then
      update public.equipment set
        current_employee_id = p_employee,
        checked_out_at      = v_when,
        due_at              = v_due,
        status              = case when status in ('available', 'checked_out') then 'checked_out' else status end,
        last_event_at       = v_when
      where id = p_equipment;
    else
      update public.equipment set
        current_employee_id = null,
        checked_out_at      = null,
        due_at              = null,
        status              = case when status in ('checked_out', 'lost') then 'available' else status end,
        last_event_at       = v_when
      where id = p_equipment;
    end if;
    -- Any open alerts were about the previous checkout; this event ends them.
    update public.equipment_alerts set resolved_at = v_when
     where equipment_id = p_equipment and resolved_at is null;
  end if;

  return jsonb_build_object(
    'ok', true,
    'transaction_id', v_txn,
    'action', v_action,
    'flags', to_jsonb(v_flags),
    'equipment', jsonb_build_object('id', eq.id, 'name', eq.name),
    'employee',  (select jsonb_build_object('id', e.id, 'name', trim(e.first_name || ' ' || e.last_name))
                  from public.employees e where e.id = p_employee),
    'previous_holder', case when v_is_latest and eq.current_employee_id is distinct from p_employee then
                  (select jsonb_build_object('id', e.id, 'name', trim(e.first_name || ' ' || e.last_name))
                   from public.employees e where e.id = eq.current_employee_id) end,
    'due_at', v_due,
    'due_rule', v_rule   -- 'hours' | 'shift_end' | 'none' — lets the station say "Due at end of your shift"
  );
end $$;

-- Resolve a station from its device key; null if unknown/revoked.
create function private.station_from_key(p_device_key text)
returns public.stations
language sql stable security definer set search_path = public as $$
  select s.* from public.stations s
  join private.station_keys k on k.station_id = s.id
  where k.device_key_hash = private.sha256_hex(p_device_key)
    and s.activated_at is not null
    and s.revoked_at is null
$$;

-- The error a station gets when station_from_key() says no. 'station_not_authorized'
-- makes the station unpair itself; the platform migration adds 'account_paused'.
create function private.station_denied(p_device_key text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  return jsonb_build_object('ok', false, 'error', 'station_not_authorized');
end $$;

-- =====================================================================
-- Public API — dashboard functions (signed-in users)
-- =====================================================================

-- New customer company. The caller becomes its owner.
create function public.create_organization(p_name text, p_slug text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_org uuid;
begin
  if auth.uid() is null then raise exception 'not signed in' using errcode = '42501'; end if;
  insert into public.organizations (name, slug) values (p_name, lower(p_slug)) returning id into v_org;
  insert into public.org_members (org_id, user_id, role) values (v_org, auth.uid(), 'owner');
  return v_org;
end $$;

-- Register a new station. Returns the activation code to type on the Pi (valid 7 days).
create function public.create_station(p_org uuid, p_name text, p_location uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_station uuid; v_code text := private.new_activation_code();
begin
  if not private.has_org_role(p_org, 'admin') then raise exception 'not allowed' using errcode = '42501'; end if;
  insert into public.stations (org_id, name, location_id) values (p_org, p_name, p_location) returning id into v_station;
  insert into private.station_keys (station_id, activation_code_hash, activation_expires_at)
  values (v_station, private.sha256_hex(private.normalize_code(v_code)), now() + interval '7 days');
  return jsonb_build_object('station_id', v_station, 'activation_code', v_code,
                            'expires_at', now() + interval '7 days');
end $$;

-- New activation code for an existing station (replacement Pi, re-setup).
-- Immediately invalidates the old device key.
create function public.reset_station_activation(p_station uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_org uuid; v_code text := private.new_activation_code();
begin
  select org_id into v_org from public.stations where id = p_station;
  if v_org is null or not private.has_org_role(v_org, 'admin') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  update private.station_keys set
    device_key_hash = null,
    activation_code_hash = private.sha256_hex(private.normalize_code(v_code)),
    activation_expires_at = now() + interval '7 days'
  where station_id = p_station;
  update public.stations set activated_at = null, revoked_at = null, admin_claimed_at = null where id = p_station;
  return jsonb_build_object('station_id', p_station, 'activation_code', v_code,
                            'expires_at', now() + interval '7 days');
end $$;

-- Lost/stolen station: cut it off immediately.
create function public.revoke_station(p_station uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_org uuid;
begin
  select org_id into v_org from public.stations where id = p_station;
  if v_org is null or not private.has_org_role(v_org, 'admin') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  update private.station_keys set device_key_hash = null, activation_code_hash = null where station_id = p_station;
  update public.stations set revoked_at = now() where id = p_station;
end $$;

-- Supervisors mark an item lost, send it to maintenance, or put it back in service.
-- A lost item keeps who had it (for the record) until someone returns it as found.
create function public.set_equipment_status(p_equipment uuid, p_status public.equipment_status, p_notes text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare eq public.equipment;
begin
  select * into eq from public.equipment where id = p_equipment for update;
  if not found or not private.has_org_role(eq.org_id, 'supervisor') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if p_status = 'retired' and not private.has_org_role(eq.org_id, 'admin') then
    raise exception 'only admins can retire equipment' using errcode = '42501';
  end if;
  update public.equipment set
    status = case
      when p_status in ('available', 'checked_out')       -- "back in service": status follows custody
        then case when current_employee_id is not null then 'checked_out' else 'available' end::public.equipment_status
      else p_status end,
    notes = coalesce(p_notes, notes)
  where id = p_equipment;
  if p_status = 'lost' then
    update public.equipment_alerts set resolved_at = now() where equipment_id = p_equipment and resolved_at is null;
  end if;
  return jsonb_build_object('ok', true, 'status', (select status from public.equipment where id = p_equipment));
end $$;

-- Manual checkout/return from the dashboard (e.g. a supervisor fixing a missed tap).
create function public.dashboard_record_event(
  p_equipment uuid, p_employee uuid, p_action public.txn_action,
  p_occurred_at timestamptz default null, p_notes text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_org uuid;
begin
  select org_id into v_org from public.equipment where id = p_equipment;
  if v_org is null or not private.has_org_role(v_org, 'supervisor') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if not exists (select 1 from public.employees where id = p_employee and org_id = v_org) then
    return jsonb_build_object('ok', false, 'error', 'unknown_employee');
  end if;
  return private.record_event(v_org, p_equipment, p_employee, p_action,
                              coalesce(p_occurred_at, now()), 'dashboard',
                              null, null, auth.uid(), p_notes);
end $$;

-- =====================================================================
-- Public API — station functions (authenticated by device key, not a login)
-- =====================================================================

-- Setup wizard: trade the activation code for this station's permanent device key.
-- The key is returned ONCE; the station stores it, the server keeps only a hash.
create function public.activate_station(p_activation_code text, p_software_version text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_station uuid;
  v_key text := encode(extensions.gen_random_bytes(32), 'hex');
begin
  update private.station_keys set
    device_key_hash = private.sha256_hex(v_key),
    activation_code_hash = null,
    activation_expires_at = null
  where activation_code_hash = private.sha256_hex(private.normalize_code(p_activation_code))
    and activation_expires_at > now()
  returning station_id into v_station;

  if v_station is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_or_expired_code');
  end if;

  update public.stations set activated_at = now(), revoked_at = null, last_seen_at = now(),
         software_version = coalesce(p_software_version, software_version)
  where id = v_station;

  return jsonb_build_object('ok', true, 'station_id', v_station, 'device_key', v_key,
           -- Setup asks for the admin tag from the box; it can be skipped only if the company already has one.
           'has_admin_fob', exists (select 1 from public.employees e join public.stations st on st.org_id = e.org_id
                                    where st.id = v_station and e.active and e.station_role = 'admin' and e.badge_uid is not null))
         || public.station_config(v_key);
end $$;

-- Everything the station needs to draw its screens.
create function public.station_config(p_device_key text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare s public.stations; o public.organizations;
begin
  s := private.station_from_key(p_device_key);
  if s.id is null then return private.station_denied(p_device_key); end if;
  select * into o from public.organizations where id = s.org_id;
  return jsonb_build_object(
    'ok', true,
    'station', jsonb_build_object('id', s.id, 'name', s.name,
                 'location', (select name from public.locations where id = s.location_id)),
    'organization', jsonb_build_object(
      'name', o.name, 'logo_url', o.logo_url,
      'primary_color', o.primary_color, 'accent_color', o.accent_color,
      'timezone', o.timezone, 'terminology', o.terminology,
      'settings', o.settings, 'enabled_modules', to_jsonb(o.enabled_modules)),
    'categories', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'icon', icon)
                              order by sort_order, name)
                            from public.equipment_categories where org_id = s.org_id), '[]'::jsonb)
  );
end $$;

-- Badge + item lists so the station can validate taps while offline.
create function public.station_sync_cache(p_device_key text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare s public.stations;
begin
  s := private.station_from_key(p_device_key);
  if s.id is null then return private.station_denied(p_device_key); end if;
  return jsonb_build_object(
    'ok', true,
    'generated_at', now(),
    'employees', coalesce((select jsonb_agg(jsonb_build_object(
                    'id', e.id, 'badge_uid', e.badge_uid,
                    'name', trim(e.first_name || ' ' || e.last_name),
                    'role', e.station_role,
                    'has_pin', exists (select 1 from private.staff_pins p where p.employee_id = e.id)))
                  from public.employees e
                  where e.org_id = s.org_id and e.active and e.badge_uid is not null), '[]'::jsonb),
    'equipment', coalesce((select jsonb_agg(jsonb_build_object(
                    'id', e.id, 'nfc_uid', e.nfc_uid, 'name', e.name,
                    'category_id', e.category_id, 'status', e.status,
                    'current_employee_id', e.current_employee_id,
                    'checked_out_at', e.checked_out_at, 'due_at', e.due_at,
                    'extended_alert_hours', private.extended_hours(e.id)))
                  from public.equipment e
                  where e.org_id = s.org_id and e.nfc_uid is not null and e.status <> 'retired'), '[]'::jsonb)
  );
end $$;

-- A tap: employee badge + equipment tag. Safe to call again with the same
-- client_txn_id (offline re-upload) — it returns the original result.
create function public.station_tap(
  p_device_key    text,
  p_client_txn_id uuid,
  p_badge_uid     text,
  p_equipment_uid text,
  p_occurred_at   timestamptz default null,
  p_action        public.txn_action default null,
  p_queued        boolean default false)   -- true = saved while offline; record it even if rules would refuse it now
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  s     public.stations;
  v_emp uuid;
  v_eq  uuid;
  t     public.transactions;
begin
  s := private.station_from_key(p_device_key);
  if s.id is null then return private.station_denied(p_device_key); end if;
  if p_client_txn_id is null then return jsonb_build_object('ok', false, 'error', 'missing_client_txn_id'); end if;

  update public.stations set last_seen_at = now() where id = s.id;

  -- Already received this exact event? Return what happened the first time.
  select * into t from public.transactions where station_id = s.id and client_txn_id = p_client_txn_id;
  if found then
    return jsonb_build_object('ok', true, 'duplicate', true, 'transaction_id', t.id,
                              'action', t.action, 'flags', to_jsonb(t.flags));
  end if;

  select id into v_emp from public.employees
   where org_id = s.org_id and active and badge_uid = private.normalize_uid(p_badge_uid);
  if v_emp is null then return jsonb_build_object('ok', false, 'error', 'unknown_badge'); end if;

  select id into v_eq from public.equipment
   where org_id = s.org_id and nfc_uid = private.normalize_uid(p_equipment_uid);
  if v_eq is null then return jsonb_build_object('ok', false, 'error', 'unknown_equipment'); end if;

  return private.record_event(s.org_id, v_eq, v_emp, p_action, p_occurred_at,
                              'station', s.id, p_client_txn_id, null, null,
                              not coalesce(p_queued, false));
exception when unique_violation then
  -- Two uploads of the same event raced each other; the other one won.
  select * into t from public.transactions where station_id = s.id and client_txn_id = p_client_txn_id;
  return jsonb_build_object('ok', true, 'duplicate', true, 'transaction_id', t.id,
                            'action', t.action, 'flags', to_jsonb(t.flags));
end $$;

-- Tap an item without a badge: is it in or out, and who has it?
create function public.station_item_status(p_device_key text, p_equipment_uid text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare s public.stations; eq public.equipment;
begin
  s := private.station_from_key(p_device_key);
  if s.id is null then return private.station_denied(p_device_key); end if;
  select * into eq from public.equipment
   where org_id = s.org_id and nfc_uid = private.normalize_uid(p_equipment_uid);
  if not found then return jsonb_build_object('ok', false, 'error', 'unknown_equipment'); end if;
  return jsonb_build_object(
    'ok', true,
    'equipment', jsonb_build_object('id', eq.id, 'name', eq.name, 'status', eq.status,
                   'category', (select name from public.equipment_categories where id = eq.category_id)),
    'holder', (select jsonb_build_object('id', e.id, 'name', trim(e.first_name || ' ' || e.last_name))
               from public.employees e where e.id = eq.current_employee_id),
    'checked_out_at', eq.checked_out_at,
    'due_at', eq.due_at,
    'is_overdue', eq.due_at is not null and eq.due_at < now());
end $$;

-- "I'm alive" ping so the dashboard can show online/offline.
create function public.station_heartbeat(p_device_key text, p_software_version text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.stations;
begin
  s := private.station_from_key(p_device_key);
  if s.id is null then return private.station_denied(p_device_key); end if;
  update public.stations set last_seen_at = now(),
         software_version = coalesce(p_software_version, software_version)
  where id = s.id;
  return jsonb_build_object('ok', true, 'server_time', now());
end $$;

-- =====================================================================
-- Dashboard views (respect row-level security of the person querying)
-- =====================================================================
create view public.equipment_overview with (security_invoker = true) as
select
  e.id, e.org_id, e.name, e.asset_tag, e.status, e.condition,
  c.name  as category,
  l.name  as home_location,
  e.time_limit_mode,
  tl.rule  as effective_time_limit,      -- 'none' | 'hours' | 'shift_end'
  tl.hours as effective_checkout_hours,  -- for 'shift_end': fallback hours when not on a shift
  e.current_employee_id,
  trim(emp.first_name || ' ' || emp.last_name) as current_holder,
  e.checked_out_at, e.due_at,
  (e.due_at is not null and e.due_at < now()) as is_overdue,
  round(extract(epoch from now() - e.checked_out_at) / 3600, 1) as hours_out,
  coalesce(e.extended_alert_hours, c.extended_alert_hours, o.extended_checkout_hours) as extended_alert_hours,
  (e.checked_out_at is not null
   and now() - e.checked_out_at > make_interval(secs => coalesce(e.extended_alert_hours, c.extended_alert_hours,
                                                                 o.extended_checkout_hours) * 3600))
    as is_extended,
  e.last_event_at
from public.equipment e
join public.organizations o on o.id = e.org_id
left join public.equipment_categories c on c.id = e.category_id
left join public.locations l on l.id = e.home_location_id
left join public.employees emp on emp.id = e.current_employee_id
cross join lateral private.resolve_time_limit(e.time_limit_mode, e.checkout_hours,
                                              c.time_limit_type, c.default_checkout_hours) tl;

-- Every checkout and return in plain language: who did it, for whom, where.
create view public.activity_log with (security_invoker = true) as
select
  t.id, t.org_id, t.occurred_at, t.received_at,
  q.name  as equipment,
  c.name  as category,
  t.action,
  trim(by_e.first_name || ' ' || by_e.last_name)     as by_employee,
  trim(prev_e.first_name || ' ' || prev_e.last_name) as previous_holder,
  case
    when t.action = 'checkout' and t.previous_employee_id is not null and t.previous_employee_id <> t.employee_id
      then 'Checked out (was still with ' || trim(prev_e.first_name || ' ' || prev_e.last_name) || ')'
    when t.action = 'checkout' then 'Checked out'
    when 'found_lost_item' = any(t.flags) then 'Returned as found'
    when t.previous_employee_id is not null and t.previous_employee_id <> t.employee_id
      then 'Returned for ' || trim(prev_e.first_name || ' ' || prev_e.last_name)
    else 'Returned'
  end as description,
  case when t.source = 'dashboard' then 'Dashboard' else st.name end as place,
  t.recorded_by,
  t.flags,
  t.notes
from public.transactions t
join public.equipment q on q.id = t.equipment_id
join public.employees by_e on by_e.id = t.employee_id
left join public.employees prev_e on prev_e.id = t.previous_employee_id
left join public.equipment_categories c on c.id = q.category_id
left join public.stations st on st.id = t.station_id;

create view public.station_overview with (security_invoker = true) as
select s.*,
  (s.revoked_at is null and s.last_seen_at > now() - interval '5 minutes') as is_online,
  l.name as location
from public.stations s
left join public.locations l on l.id = s.location_id;

-- =====================================================================
-- Alerts: raise + sign off
-- =====================================================================

-- Raises alerts for items out too long or past due, and closes any that no
-- longer apply. Runs on a schedule; safe to run as often as you like.
create function private.generate_equipment_alerts()
returns int language plpgsql security definer set search_path = public as $$
declare n int; m int;
begin
  -- Out too long
  insert into public.equipment_alerts (org_id, equipment_id, employee_id, kind, checked_out_at, threshold_at)
  select e.org_id, e.id, e.current_employee_id, 'extended_checkout', e.checked_out_at,
         e.checked_out_at + make_interval(secs => h.hours * 3600)
  from public.equipment e
  cross join lateral (select private.extended_hours(e.id) as hours) h
  where e.current_employee_id is not null and e.checked_out_at is not null
    and e.status <> 'lost'           -- lost items are already known; no repeat alerts
    and h.hours is not null
    and e.checked_out_at + make_interval(secs => h.hours * 3600) <= now()
  on conflict (equipment_id, kind, checked_out_at) do nothing;
  get diagnostics n = row_count;

  -- Past due
  insert into public.equipment_alerts (org_id, equipment_id, employee_id, kind, checked_out_at, threshold_at)
  select e.org_id, e.id, e.current_employee_id, 'overdue', e.checked_out_at, e.due_at
  from public.equipment e
  where e.current_employee_id is not null and e.checked_out_at is not null
    and e.status <> 'lost'
    and e.due_at is not null and e.due_at <= now()
  on conflict (equipment_id, kind, checked_out_at) do nothing;
  get diagnostics m = row_count;

  -- Safety net: close alerts whose checkout is over (normally done at the tap).
  update public.equipment_alerts a set resolved_at = now()
  from public.equipment e
  where e.id = a.equipment_id and a.resolved_at is null
    and (e.checked_out_at is distinct from a.checked_out_at);

  return n + m;
end $$;

-- Supervisor sign-off ("called Alex, radio is in his locker").
create function public.acknowledge_alert(p_alert uuid, p_notes text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_org uuid;
begin
  select org_id into v_org from public.equipment_alerts where id = p_alert;
  if v_org is null or not private.has_org_role(v_org, 'supervisor') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  update public.equipment_alerts
     set acknowledged_by = auth.uid(), acknowledged_at = now(), notes = p_notes
   where id = p_alert;
end $$;

alter table public.equipment_alerts enable row level security;
create policy alerts_select on public.equipment_alerts for select to authenticated using (private.has_org_role(org_id));
revoke insert, update, delete on public.equipment_alerts from anon, authenticated;
revoke execute on function public.acknowledge_alert(uuid, text) from public;
grant  execute on function public.acknowledge_alert(uuid, text) to authenticated;

-- Check every 5 minutes (Supabase has pg_cron).
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    execute 'create extension if not exists pg_cron';
    execute $q$select cron.schedule('generate-equipment-alerts', '*/5 * * * *',
                                    'select private.generate_equipment_alerts()')$q$;
  else
    raise notice 'pg_cron not available: call private.generate_equipment_alerts() on a schedule another way';
  end if;
end $$;

-- =====================================================================
-- Function permissions
-- Internal helpers: nobody calls them directly.
-- Station functions: callable with the public (anon) API key — the device
-- key inside each call is what actually authenticates the station.
-- =====================================================================
revoke execute on all functions in schema private from public, anon, authenticated;
grant  execute on function private.has_org_role(uuid, public.member_role) to authenticated;
-- Used by triggers/CHECKs that run as whoever is editing:
grant  execute on function private.normalize_uid(text) to anon, authenticated;
grant  execute on function private.resolve_time_limit(public.time_limit_mode, numeric, public.time_limit_type, numeric) to authenticated;

revoke execute on function
  public.create_organization(text, text),
  public.create_station(uuid, text, uuid),
  public.reset_station_activation(uuid),
  public.revoke_station(uuid),
  public.dashboard_record_event(uuid, uuid, public.txn_action, timestamptz, text),
  public.set_equipment_status(uuid, public.equipment_status, text),
  public.activate_station(text, text),
  public.station_config(text),
  public.station_sync_cache(text),
  public.station_tap(text, uuid, text, text, timestamptz, public.txn_action, boolean),
  public.station_item_status(text, text),
  public.station_heartbeat(text, text)
from public;

grant execute on function
  public.create_organization(text, text),
  public.create_station(uuid, text, uuid),
  public.reset_station_activation(uuid),
  public.revoke_station(uuid),
  public.dashboard_record_event(uuid, uuid, public.txn_action, timestamptz, text),
  public.set_equipment_status(uuid, public.equipment_status, text)
to authenticated;

grant execute on function
  public.activate_station(text, text),
  public.station_config(text),
  public.station_sync_cache(text),
  public.station_tap(text, uuid, text, text, timestamptz, public.txn_action, boolean),
  public.station_item_status(text, text),
  public.station_heartbeat(text, text)
to anon, authenticated;
