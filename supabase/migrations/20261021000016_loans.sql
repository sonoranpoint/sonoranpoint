-- =====================================================================
-- 16: Lending equipment between contracts
--   United BW lends a radio to Delta BW: while the loan is on, Delta's stations treat it like
--   their own (checkouts are marked "on loan"). The loan ends when the item is tapped at one of
--   United's stations (if it's in the room, that tap just takes it back; if someone has it, it's
--   returned), or when a supervisor ends it.
--   * Lend from the dashboard (supervisors) or at a station with a manager/admin fob, at a
--     station that serves the item's own contract.
--   * Stations also say who an item belongs to when it's tapped on its own.
-- =====================================================================
create table public.equipment_loans (
  id                  uuid primary key default gen_random_uuid(),
  org_id              uuid not null references public.organizations(id) on delete cascade,
  equipment_id        uuid not null,
  from_contract_id    uuid,                  -- whose it is
  to_contract_id      uuid not null,         -- who's borrowing it
  notes               text check (length(notes) <= 300),
  lent_at             timestamptz not null default now(),
  lent_by_user        uuid references auth.users(id) on delete set null,
  lent_by_employee    uuid,
  ended_at            timestamptz,
  ended_by_user       uuid references auth.users(id) on delete set null,
  ended_by_employee   uuid,
  ended_how           text check (ended_how in ('returned', 'ended')),   -- tapped back at the owner's station / ended by hand
  foreign key (equipment_id, org_id) references public.equipment(id, org_id) on delete cascade,
  foreign key (to_contract_id, org_id) references public.contracts(id, org_id) on delete cascade,
  foreign key (lent_by_employee, org_id) references public.employees(id, org_id) on delete set null (lent_by_employee),
  foreign key (ended_by_employee, org_id) references public.employees(id, org_id) on delete set null (ended_by_employee)
);
create unique index equipment_loans_open on public.equipment_loans (equipment_id) where ended_at is null;
create index on public.equipment_loans (org_id, lent_at desc);
alter table public.equipment_loans enable row level security;
create policy equipment_loans_select on public.equipment_loans for select to authenticated using (private.has_org_role(org_id));
revoke insert, update, delete on public.equipment_loans from anon, authenticated;

create function private.open_loan(p_equipment uuid)
returns public.equipment_loans language sql stable security definer set search_path = public as $$
  select * from public.equipment_loans where equipment_id = p_equipment and ended_at is null
$$;

create function private.lend(p_org uuid, p_equipment uuid, p_to uuid, p_notes text, p_user uuid, p_employee uuid, p_station uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare eq public.equipment; s public.stations;
begin
  select * into eq from public.equipment where id = p_equipment and org_id = p_org for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'unknown_equipment'); end if;
  if not exists (select 1 from public.contracts where id = p_to and org_id = p_org) then return jsonb_build_object('ok', false, 'error', 'unknown_contract'); end if;
  if eq.contract_id is null then return jsonb_build_object('ok', false, 'error', 'no_contract'); end if;   -- already works everywhere
  if private.contracts_share(p_org, eq.contract_id, p_to) then return jsonb_build_object('ok', false, 'error', 'already_shared'); end if;
  if p_station is not null then
    select * into s from public.stations where id = p_station;
    if not private.contracts_share(p_org, s.contract_id, eq.contract_id) then return jsonb_build_object('ok', false, 'error', 'not_yours_to_lend'); end if;
  end if;
  -- A new loan replaces any open one.
  update public.equipment_loans set ended_at = now(), ended_by_user = p_user, ended_by_employee = p_employee, ended_how = 'ended'
   where equipment_id = eq.id and ended_at is null;
  insert into public.equipment_loans (org_id, equipment_id, from_contract_id, to_contract_id, notes, lent_by_user, lent_by_employee)
  values (p_org, eq.id, eq.contract_id, p_to, nullif(left(trim(p_notes), 300), ''), p_user, p_employee);
  return jsonb_build_object('ok', true, 'equipment', jsonb_build_object('id', eq.id, 'name', eq.name),
    'to', (select name from public.contracts where id = p_to), 'from', (select name from public.contracts where id = eq.contract_id));
end $$;

create function private.end_loan(p_equipment uuid, p_how text, p_user uuid, p_employee uuid)
returns boolean language sql security definer set search_path = public as $$
  with u as (update public.equipment_loans set ended_at = now(), ended_how = p_how, ended_by_user = p_user, ended_by_employee = p_employee
              where equipment_id = p_equipment and ended_at is null returning 1)
  select exists (select 1 from u)
$$;

-- Dashboard (supervisors and up)
create function public.lend_equipment(p_equipment uuid, p_to_contract uuid, p_notes text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_org uuid;
begin
  select org_id into v_org from public.equipment where id = p_equipment;
  if v_org is null or not private.has_org_role(v_org, 'supervisor') then raise exception 'not allowed' using errcode = '42501'; end if;
  return private.lend(v_org, p_equipment, p_to_contract, p_notes, auth.uid(), null, null);
end $$;

create function public.end_equipment_loan(p_equipment uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_org uuid;
begin
  select org_id into v_org from public.equipment where id = p_equipment;
  if v_org is null or not private.has_org_role(v_org, 'supervisor') then raise exception 'not allowed' using errcode = '42501'; end if;
  return jsonb_build_object('ok', true, 'ended', private.end_loan(p_equipment, 'ended', auth.uid(), null));
end $$;

-- Station: a manager or admin fob, at a station that serves the item's own contract.
create function public.station_lend_equipment(p_device_key text, p_badge_uid text, p_pin text, p_equipment_uid text, p_to_contract uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare ss jsonb; v_eq uuid;
begin
  ss := private.staff_session(p_device_key, p_badge_uid, p_pin, 'manager');
  if not (ss->>'ok')::boolean then return ss; end if;
  select id into v_eq from public.equipment where org_id = (ss->>'org_id')::uuid and nfc_uid = private.normalize_uid(p_equipment_uid);
  if v_eq is null then return jsonb_build_object('ok', false, 'error', 'unknown_equipment'); end if;
  return private.lend((ss->>'org_id')::uuid, v_eq, p_to_contract, null, null, (ss->'staff'->>'id')::uuid, (ss->>'station_id')::uuid);
end $$;

create function public.station_end_loan(p_device_key text, p_badge_uid text, p_pin text, p_equipment_uid text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare ss jsonb; v_eq uuid;
begin
  ss := private.staff_session(p_device_key, p_badge_uid, p_pin, 'manager');
  if not (ss->>'ok')::boolean then return ss; end if;
  select id into v_eq from public.equipment where org_id = (ss->>'org_id')::uuid and nfc_uid = private.normalize_uid(p_equipment_uid);
  if v_eq is null then return jsonb_build_object('ok', false, 'error', 'unknown_equipment'); end if;
  return jsonb_build_object('ok', true, 'ended', private.end_loan(v_eq, 'ended', null, (ss->'staff'->>'id')::uuid));
end $$;

create or replace function public.station_tap(
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
  e     public.employees;
  eq    public.equipment;
  v_out boolean;
  r     jsonb;
  ln    public.equipment_loans;
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

  -- Contracts: this station only serves people (and lends out items) from contracts it shares with.
  -- Taps saved offline are recorded whatever happened; returns are always taken.
  select * into e from public.employees where id = v_emp;
  select * into eq from public.equipment where id = v_eq;
  if not coalesce(p_queued, false) then
    if not private.contracts_share(s.org_id, s.contract_id, e.contract_id) then
      return jsonb_build_object('ok', false, 'error', 'other_contract',
        'station_contract', (select name from public.contracts where id = s.contract_id),
        'employee_contract', (select name from public.contracts where id = e.contract_id));
    end if;
  end if;

  -- Loans: back at the owner's station, the loan is over. If it's sitting in the room, this tap just takes it back.
  ln := private.open_loan(eq.id);
  if ln.id is not null and s.contract_id is not null
     and private.contracts_share(s.org_id, s.contract_id, ln.from_contract_id)
     and not private.contracts_share(s.org_id, s.contract_id, ln.to_contract_id) then
    perform private.end_loan(eq.id, 'returned', null, v_emp);
    if eq.current_employee_id is null and not coalesce(p_queued, false) then
      return jsonb_build_object('ok', true, 'action', 'loan_returned', 'flags', '[]'::jsonb,
        'equipment', jsonb_build_object('id', eq.id, 'name', eq.name),
        'borrower', (select name from public.contracts where id = ln.to_contract_id));
    end if;
    ln := null;
  end if;

  if not coalesce(p_queued, false) then
    v_out := coalesce(p_action = 'checkout', not (eq.status = 'lost' or eq.current_employee_id is not distinct from v_emp
               or (eq.current_employee_id is not null
                   and coalesce(((select settings from public.organizations where id = s.org_id)->>'allow_return_by_other')::boolean, true))));
    if v_out and not private.contracts_share(s.org_id, s.contract_id, eq.contract_id)
       and not (ln.id is not null and private.contracts_share(s.org_id, s.contract_id, ln.to_contract_id)) then
      return jsonb_build_object('ok', false, 'error', 'other_contract_item',
        'equipment', jsonb_build_object('id', eq.id, 'name', eq.name),
        'item_contract', (select name from public.contracts where id = eq.contract_id),
        'loaned_to', (select name from public.contracts where id = ln.to_contract_id));
    end if;
  end if;

  r := private.record_event(s.org_id, v_eq, v_emp, p_action, p_occurred_at,
                            'station', s.id, p_client_txn_id, null, null,
                            not coalesce(p_queued, false));

  -- Checked out on loan: mark it so supervisors can see.
  if (r->>'ok')::boolean and r->>'action' = 'checkout' and ln.id is not null then
    update public.transactions set flags = array_append(flags, 'on_loan') where id = (r->>'transaction_id')::uuid;
    r := jsonb_set(r, '{flags}', (r->'flags') || '["on_loan"]'::jsonb)
         || jsonb_build_object('loan_from', (select name from public.contracts where id = ln.from_contract_id));
  end if;

  -- Returned at another contract's station: note it, and move the item if that group says so (not while it's on loan).
  if (r->>'ok')::boolean and r->>'action' = 'checkin' and s.contract_id is not null
     and eq.contract_id is distinct from s.contract_id and not (r->'flags') ? 'late_sync' then
    update public.transactions set flags = array_append(flags, 'returned_other_contract') where id = (r->>'transaction_id')::uuid;
    r := jsonb_set(r, '{flags}', (r->'flags') || '["returned_other_contract"]'::jsonb);
    if ln.id is null and private.contracts_move(s.org_id, eq.contract_id, s.contract_id) then
      update public.equipment set contract_id = s.contract_id where id = eq.id;
      r := r || jsonb_build_object('moved_to', (select name from public.contracts where id = s.contract_id));
    end if;
  end if;
  return r;
exception when unique_violation then
  -- Two uploads of the same event raced each other; the other one won.
  select * into t from public.transactions where station_id = s.id and client_txn_id = p_client_txn_id;
  return jsonb_build_object('ok', true, 'duplicate', true, 'transaction_id', t.id,
                            'action', t.action, 'flags', to_jsonb(t.flags));
end $$;

create or replace function public.station_sync_cache(p_device_key text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare s public.stations;
begin
  s := private.station_from_key(p_device_key);
  if s.id is null then return private.station_denied(p_device_key); end if;
  return jsonb_build_object(
    'ok', true,
    'generated_at', now(),
    'contract_names', coalesce((select jsonb_object_agg(id, name) from public.contracts where org_id = s.org_id), '{}'::jsonb),
    -- Contracts this station serves (null = every one): lets it apply the same rules offline.
    'reach', case when s.contract_id is null then null else
               coalesce((select jsonb_agg(c.id) from public.contracts c where c.org_id = s.org_id and private.contracts_share(s.org_id, s.contract_id, c.id)), '[]'::jsonb) end,
    'employees', coalesce((select jsonb_agg(jsonb_build_object(
                    'id', e.id, 'badge_uid', e.badge_uid,
                    'name', trim(e.first_name || ' ' || e.last_name),
                    'role', e.station_role, 'contract_id', e.contract_id,
                    'has_pin', exists (select 1 from private.staff_pins p where p.employee_id = e.id)))
                  from public.employees e
                  where e.org_id = s.org_id and e.active and e.badge_uid is not null), '[]'::jsonb),
    'equipment', coalesce((select jsonb_agg(jsonb_build_object(
                    'id', e.id, 'nfc_uid', e.nfc_uid, 'name', e.name,
                    'category_id', e.category_id, 'status', e.status, 'contract_id', e.contract_id,
                    'loan_to', (private.open_loan(e.id)).to_contract_id,
                    'current_employee_id', e.current_employee_id,
                    'checked_out_at', e.checked_out_at, 'due_at', e.due_at,
                    'extended_alert_hours', private.extended_hours(e.id),
                    'problem', private.open_problem(e.id)))
                  from public.equipment e
                  where e.org_id = s.org_id and e.nfc_uid is not null and e.status <> 'retired'), '[]'::jsonb)
  );
end $$;

create or replace function public.station_config(p_device_key text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare s public.stations; o public.organizations;
begin
  s := private.station_from_key(p_device_key);
  if s.id is null then return private.station_denied(p_device_key); end if;
  select * into o from public.organizations where id = s.org_id;
  return jsonb_build_object(
    'ok', true,
    'station', jsonb_build_object('id', s.id, 'name', s.name,
                 'contract', (select jsonb_build_object('id', c.id, 'name', c.name) from public.contracts c where c.id = s.contract_id),
                 'location', (select name from public.locations where id = s.location_id)),
    'organization', jsonb_build_object(
      'name', o.name, 'logo_url', o.logo_url,
      'primary_color', o.primary_color, 'accent_color', o.accent_color,
      'timezone', o.timezone, 'terminology', o.terminology,
      'settings', o.settings, 'enabled_modules', to_jsonb(o.enabled_modules)),
    'categories', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'icon', icon)
                              order by sort_order, name)
                            from public.equipment_categories where org_id = s.org_id), '[]'::jsonb),
    'contracts', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'parent_id', parent_id) order by sort_order, name)
                            from public.contracts where org_id = s.org_id), '[]'::jsonb),
    'problem_reasons', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'label', label, 'blocks_checkout', blocks_checkout)
                              order by sort_order, label)
                            from public.problem_reasons where org_id = s.org_id and archived_at is null), '[]'::jsonb)
  );
end $$;

create or replace function public.station_item_status(p_device_key text, p_equipment_uid text)
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
    'is_overdue', eq.due_at is not null and eq.due_at < now(),
    'problem', private.open_problem(eq.id),
    'contract', (select jsonb_build_object('id', c.id, 'name', c.name) from public.contracts c where c.id = eq.contract_id),
    'loan', (select jsonb_build_object('to', c.name, 'to_id', c.id, 'since', l.lent_at)
             from public.equipment_loans l join public.contracts c on c.id = l.to_contract_id where l.equipment_id = eq.id and l.ended_at is null));
end $$;

revoke execute on all functions in schema private from public, anon, authenticated;
grant  execute on function private.has_org_role(uuid, public.member_role) to authenticated;
grant  execute on function private.normalize_uid(text) to anon, authenticated;
grant  execute on function private.resolve_time_limit(public.time_limit_mode, numeric, public.time_limit_type, numeric) to authenticated;
grant  execute on function private.can_manage_logo(text) to authenticated;
revoke execute on function public.lend_equipment(uuid, uuid, text), public.end_equipment_loan(uuid),
  public.station_lend_equipment(text, text, text, text, uuid), public.station_end_loan(text, text, text, text) from public;
grant  execute on function public.lend_equipment(uuid, uuid, text), public.end_equipment_loan(uuid) to authenticated;
grant  execute on function public.station_lend_equipment(text, text, text, text, uuid), public.station_end_loan(text, text, text, text) to anon, authenticated;
