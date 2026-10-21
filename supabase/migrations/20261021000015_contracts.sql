-- =====================================================================
-- 15: Contracts
--   A company splits its work into contracts, nested as deep as it likes:
--     Prospect (admin office)
--     ├── BW (below wing)   sharing off  ── Delta BW, United BW      never cross
--     └── AW (above wing)   sharing on   ── Delta AW, United AW      badges and gear work across both
--   * Every station, person, item and shift can belong to one contract (blank = the whole company).
--   * Two contracts "share" when one is inside the other, or when the group they meet in has
--     sharing on (at the top, the company setting share_contracts). A station refuses badges
--     from contracts it doesn't share with, and won't check out their items. Returns are always
--     taken, flagged, and the item moves to the station's contract when that group says so
--     (move_on_return; at the top, the company setting move_on_return).
--   * The word is the company's own: terminology.contract / contract_plural (default "Contract").
-- =====================================================================
create table public.contracts (
  id              uuid primary key default gen_random_uuid(),
  org_id          uuid not null references public.organizations(id) on delete cascade,
  parent_id       uuid,
  name            text not null check (length(trim(name)) between 1 and 60),
  share_children  boolean not null default false,   -- badges and items work across the contracts under this one
  move_on_return  boolean not null default false,   -- an item returned at another contract's station moves there
  sort_order      int not null default 0,
  created_at      timestamptz not null default now(),
  unique (id, org_id),
  foreign key (parent_id, org_id) references public.contracts(id, org_id)
);
create unique index contracts_name on public.contracts (org_id, coalesce(parent_id, '00000000-0000-0000-0000-000000000000'::uuid), lower(trim(name)));
create trigger audit_contracts after insert or update or delete on public.contracts for each row execute function private.audit();

alter table public.stations  add column contract_id uuid, add foreign key (contract_id, org_id) references public.contracts(id, org_id);
alter table public.employees add column contract_id uuid, add foreign key (contract_id, org_id) references public.contracts(id, org_id);
alter table public.equipment add column contract_id uuid, add foreign key (contract_id, org_id) references public.contracts(id, org_id);
alter table public.shifts    add column contract_id uuid, add foreign key (contract_id, org_id) references public.contracts(id, org_id);
create index on public.employees (contract_id); create index on public.equipment (contract_id);

update public.organizations set terminology = terminology || '{"contract": "Contract", "contract_plural": "Contracts"}'::jsonb
 where not terminology ? 'contract';

alter table public.contracts enable row level security;
create policy contracts_select on public.contracts for select to authenticated using (private.has_org_role(org_id));
revoke insert, update, delete on public.contracts from anon, authenticated;

-- The contract and its parents, top first.
create function private.contract_path(p uuid)
returns uuid[] language sql stable security definer set search_path = public as $$
  with recursive up(id, parent_id, depth) as (
    select id, parent_id, 0 from public.contracts where id = p
    union all
    select c.id, c.parent_id, up.depth + 1 from public.contracts c join up on c.id = up.parent_id where up.depth < 50)
  select coalesce(array_agg(id order by depth desc), '{}') from up
$$;

-- Where two contracts meet: 'same' (one is inside the other, or either is blank), or the group
-- they first meet in (null = they only meet at the company level).
create function private.contract_meet(a uuid, b uuid, out related boolean, out meet uuid)
language plpgsql stable security definer set search_path = public as $$
declare pa uuid[]; pb uuid[]; i int := 1;
begin
  related := a is null or b is null or a = b; meet := null;
  if related then return; end if;
  pa := private.contract_path(a); pb := private.contract_path(b);
  if a = any (pb) or b = any (pa) then related := true; return; end if;
  while i <= least(array_length(pa, 1), array_length(pb, 1)) and pa[i] = pb[i] loop meet := pa[i]; i := i + 1; end loop;
end $$;

create function private.contracts_share(p_org uuid, a uuid, b uuid)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare m record;
begin
  m := private.contract_meet(a, b);
  if m.related then return true; end if;
  if m.meet is null then return coalesce((select (settings->>'share_contracts')::boolean from public.organizations where id = p_org), false); end if;
  return (select share_children from public.contracts where id = m.meet);
end $$;

create function private.contracts_move(p_org uuid, item_contract uuid, station_contract uuid)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare m record;
begin
  if item_contract is null or station_contract is null or item_contract = station_contract then return false; end if;
  m := private.contract_meet(item_contract, station_contract);
  if m.related then return false; end if;
  if m.meet is null then return coalesce((select (settings->>'move_on_return')::boolean from public.organizations where id = p_org), false); end if;
  return (select move_on_return from public.contracts where id = m.meet);
end $$;

-- Admins build the tree. p: {id?, name, parent_id?, share_children?, move_on_return?}
create function public.save_contract(p_org uuid, p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_parent uuid := nullif(p->>'parent_id', '')::uuid; v_name text := trim(coalesce(p->>'name', ''));
begin
  if not private.has_org_role(p_org, 'admin') then raise exception 'not allowed' using errcode = '42501'; end if;
  if v_name = '' then return jsonb_build_object('ok', false, 'error', 'name_required'); end if;
  if length(v_name) > 60 then return jsonb_build_object('ok', false, 'error', 'name_too_long'); end if;
  if v_parent is not null and not exists (select 1 from public.contracts where id = v_parent and org_id = p_org) then
    return jsonb_build_object('ok', false, 'error', 'unknown_parent');
  end if;
  if v_id is not null and v_parent is not null and v_id = any (private.contract_path(v_parent)) then
    return jsonb_build_object('ok', false, 'error', 'parent_inside_itself');
  end if;
  if exists (select 1 from public.contracts where org_id = p_org and parent_id is not distinct from v_parent
             and lower(trim(name)) = lower(v_name) and id is distinct from v_id) then
    return jsonb_build_object('ok', false, 'error', 'duplicate_name');
  end if;
  if v_id is null then
    insert into public.contracts (org_id, parent_id, name, share_children, move_on_return, sort_order)
    values (p_org, v_parent, v_name, coalesce((p->>'share_children')::boolean, false), coalesce((p->>'move_on_return')::boolean, false),
            (select coalesce(max(sort_order), 0) + 1 from public.contracts where org_id = p_org and parent_id is not distinct from v_parent))
    returning id into v_id;
  else
    update public.contracts set name = v_name, parent_id = case when p ? 'parent_id' then v_parent else parent_id end,
           share_children = coalesce((p->>'share_children')::boolean, share_children),
           move_on_return = coalesce((p->>'move_on_return')::boolean, move_on_return)
     where id = v_id and org_id = p_org;
    if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  end if;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

-- Only an empty contract can be deleted (no contracts under it, nothing assigned to it).
create function public.delete_contract(p_contract uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_org uuid; n jsonb;
begin
  select org_id into v_org from public.contracts where id = p_contract;
  if v_org is null or not private.has_org_role(v_org, 'admin') then raise exception 'not allowed' using errcode = '42501'; end if;
  n := jsonb_build_object(
    'contracts', (select count(*) from public.contracts where parent_id = p_contract),
    'stations',  (select count(*) from public.stations  where contract_id = p_contract and revoked_at is null),
    'employees', (select count(*) from public.employees where contract_id = p_contract and active),
    'equipment', (select count(*) from public.equipment where contract_id = p_contract and status <> 'retired'),
    'shifts',    (select count(*) from public.shifts    where contract_id = p_contract and active));
  if (select sum(value::int) from jsonb_each_text(n)) > 0 then return jsonb_build_object('ok', false, 'error', 'in_use', 'counts', n); end if;
  update public.stations  set contract_id = null where contract_id = p_contract;
  update public.employees set contract_id = null where contract_id = p_contract;
  update public.equipment set contract_id = null where contract_id = p_contract;
  update public.shifts    set contract_id = null where contract_id = p_contract;
  delete from public.contracts where id = p_contract;
  return jsonb_build_object('ok', true);
end $$;

-- Assign things to a contract from the dashboard (columns are opened up below).
grant insert (contract_id) on public.employees to authenticated;
grant update (contract_id) on public.employees to authenticated;
grant insert (contract_id) on public.equipment to authenticated;
grant update (contract_id) on public.equipment to authenticated;
grant update (contract_id) on public.stations to authenticated;

-- People and items added at a station join that station's contract.
create or replace function private.staff_session(p_device_key text, p_badge_uid text, p_pin text, p_min public.station_role)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.stations; e public.employees; pin private.staff_pins;
begin
  s := private.station_from_key(p_device_key);
  if s.id is null then return private.station_denied(p_device_key); end if;
  select * into e from public.employees
   where org_id = s.org_id and active and badge_uid = private.normalize_uid(p_badge_uid);
  if not found or e.station_role < 'manager' then return jsonb_build_object('ok', false, 'error', 'not_staff'); end if;
  if e.station_role < p_min then return jsonb_build_object('ok', false, 'error', 'admin_only'); end if;

  select * into pin from private.staff_pins where employee_id = e.id for update;
  if found then
    if pin.locked_until > now() then
      return jsonb_build_object('ok', false, 'error', 'pin_locked', 'locked_until', pin.locked_until);
    end if;
    if p_pin is null or p_pin = '' then return jsonb_build_object('ok', false, 'error', 'pin_required'); end if;
    if pin.pin_hash <> private.sha256_hex(e.id::text || ':' || p_pin) then
      update private.staff_pins set
        failures = case when failures + 1 >= 5 then 0 else failures + 1 end,
        locked_until = case when failures + 1 >= 5 then now() + interval '15 minutes' end
      where employee_id = e.id;
      return jsonb_build_object('ok', false, 'error',
        case when pin.failures + 1 >= 5 then 'pin_locked' else 'wrong_pin' end,
        'tries_left', greatest(0, 4 - pin.failures));
    end if;
    update private.staff_pins set failures = 0 where employee_id = e.id and failures <> 0;
  end if;

  perform set_config('app.actor_employee', e.id::text, true);
  perform set_config('app.station_id', s.id::text, true);   -- new people and items join this station's contract
  update public.stations set last_seen_at = now() where id = s.id;
  return jsonb_build_object('ok', true, 'station_id', s.id, 'org_id', s.org_id,
    'staff', jsonb_build_object('id', e.id, 'name', trim(e.first_name || ' ' || e.last_name), 'role', e.station_role));
end $$;

create function private.default_contract()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.contract_id is null and nullif(current_setting('app.station_id', true), '') is not null then
    new.contract_id := (select contract_id from public.stations where id = current_setting('app.station_id', true)::uuid and org_id = new.org_id);
  end if;
  return new;
end $$;
create trigger default_contract before insert on public.employees for each row execute function private.default_contract();
create trigger default_contract before insert on public.equipment for each row execute function private.default_contract();

-- ---------------------------------------------------------------------
-- Stations enforce it
-- ---------------------------------------------------------------------
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
    v_out := coalesce(p_action = 'checkout', not (eq.status = 'lost' or eq.current_employee_id is not distinct from v_emp
               or (eq.current_employee_id is not null
                   and coalesce(((select settings from public.organizations where id = s.org_id)->>'allow_return_by_other')::boolean, true))));
    if v_out and not private.contracts_share(s.org_id, s.contract_id, eq.contract_id) then
      return jsonb_build_object('ok', false, 'error', 'other_contract_item',
        'equipment', jsonb_build_object('id', eq.id, 'name', eq.name),
        'item_contract', (select name from public.contracts where id = eq.contract_id));
    end if;
  end if;

  r := private.record_event(s.org_id, v_eq, v_emp, p_action, p_occurred_at,
                            'station', s.id, p_client_txn_id, null, null,
                            not coalesce(p_queued, false));

  -- Returned at another contract's station: note it, and move the item if that group says so.
  if (r->>'ok')::boolean and r->>'action' = 'checkin' and s.contract_id is not null
     and eq.contract_id is distinct from s.contract_id and not (r->'flags') ? 'late_sync' then
    update public.transactions set flags = array_append(flags, 'returned_other_contract') where id = (r->>'transaction_id')::uuid;
    r := jsonb_set(r, '{flags}', (r->'flags') || '["returned_other_contract"]'::jsonb);
    if private.contracts_move(s.org_id, eq.contract_id, s.contract_id) then
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
    'problem_reasons', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'label', label, 'blocks_checkout', blocks_checkout)
                              order by sort_order, label)
                            from public.problem_reasons where org_id = s.org_id and archived_at is null), '[]'::jsonb)
  );
end $$;

revoke execute on all functions in schema private from public, anon, authenticated;
grant  execute on function private.has_org_role(uuid, public.member_role) to authenticated;
grant  execute on function private.normalize_uid(text) to anon, authenticated;
grant  execute on function private.resolve_time_limit(public.time_limit_mode, numeric, public.time_limit_type, numeric) to authenticated;
grant  execute on function private.can_manage_logo(text) to authenticated;
revoke execute on function public.save_contract(uuid, jsonb), public.delete_contract(uuid) from public;
grant  execute on function public.save_contract(uuid, jsonb), public.delete_contract(uuid) to authenticated;
