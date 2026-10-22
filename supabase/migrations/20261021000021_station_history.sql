-- =====================================================================
-- 21: Station history, and moving stations
--   * Every station keeps a history: added, set up, new code, disconnected, replaced, renamed,
--     moved (location or contract), removed, with who did it. Customers see it in the station's
--     details (for stations they can see); you see it on the customer's page in the console.
--   * You can rename a station and move it to another location or contract from the console.
--   * When a station moves to another contract, its past taps stay with the contract it had at
--     the time: each tap now remembers the station's contract when it happened.
--   * Fix: the dashboard's station list (station_overview) now includes the columns added since
--     it was made (contract, removed, replaced). Before this, a station's contract didn't show on
--     the live dashboard and a removed station stayed in the list.
-- =====================================================================

-- ---------------------------------------------------------------------
-- The dashboard's station list, with every station column
-- ---------------------------------------------------------------------
drop view public.station_overview;
create view public.station_overview with (security_invoker = true) as
select s.*,
  (s.revoked_at is null and s.last_seen_at > now() - interval '5 minutes') as is_online,
  l.name as location
from public.stations s
left join public.locations l on l.id = s.location_id;
grant select on public.station_overview to authenticated;

-- ---------------------------------------------------------------------
-- Taps remember the station's contract at the time
-- ---------------------------------------------------------------------
alter table public.transactions add column station_contract_id uuid;
update public.transactions t set station_contract_id = s.contract_id
  from public.stations s where s.id = t.station_id and s.contract_id is not null and t.station_contract_id is null;

create function private.stamp_station_contract()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.station_id is not null and new.station_contract_id is null then
    new.station_contract_id := (select contract_id from public.stations where id = new.station_id);
  end if;
  return new;
end $$;
create trigger stamp_station_contract before insert on public.transactions for each row execute function private.stamp_station_contract();

-- Same rule as before (the item, the station or the person is yours), with the station's contract as it was.
create function private.can_see_tap(p_org uuid, p_eq uuid, p_station_contract uuid, p_emp uuid)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare sc uuid[]; c_eq uuid; c_emp uuid;
begin
  if not private.has_org_role(p_org) then return false; end if;
  sc := private.scope_of(p_org, auth.uid());
  if sc is null then return true; end if;
  select contract_id into c_eq from public.equipment where id = p_eq;
  select contract_id into c_emp from public.employees where id = p_emp;
  return c_eq = any (sc) or p_station_contract = any (sc) or c_emp = any (sc) or (c_eq is null and p_station_contract is null);
end $$;
drop policy txn_select on public.transactions;
create policy txn_select on public.transactions for select to authenticated
  using (private.can_see_tap(org_id, equipment_id, station_contract_id, employee_id));

-- ---------------------------------------------------------------------
-- Station history
-- ---------------------------------------------------------------------
create table public.station_events (
  id          bigint generated always as identity primary key,
  org_id      uuid not null references public.organizations(id) on delete cascade,
  station_id  uuid not null references public.stations(id) on delete cascade,
  at          timestamptz not null default now(),
  kind        text not null check (kind in ('added', 'set_up', 'new_code', 'disconnected', 'replaced', 'removed', 'renamed', 'moved_location', 'moved_contract')),
  details     jsonb not null default '{}',
  by_name     text            -- "Dana Brooks", "Sonoran Point", or blank when the station did it
);
create index on public.station_events (station_id, at desc);
create index on public.station_events (org_id, at desc);
alter table public.station_events enable row level security;
create policy station_events_select on public.station_events for select to authenticated
  using (private.can_see(org_id, (select contract_id from public.stations where id = station_id)));
revoke insert, update, delete on public.station_events from anon, authenticated;

-- Who's doing this: you (shown to customers as Sonoran Point), a dashboard user, or a fob holder at a station.
create function private.actor_label()
returns text language sql stable security definer set search_path = public as $$
  select case
    when private.is_platform_operator() then 'Sonoran Point'
    when auth.uid() is not null then (select coalesce(nullif(trim(raw_user_meta_data->>'full_name'), ''), email) from auth.users where id = auth.uid())
    when nullif(current_setting('app.actor_employee', true), '') is not null then
      (select trim(first_name || ' ' || coalesce(last_name, '')) from public.employees where id = nullif(current_setting('app.actor_employee', true), '')::uuid)
  end
$$;

create function private.station_event(p_station uuid, p_kind text, p_details jsonb default '{}')
returns void language sql security definer set search_path = public as $$
  insert into public.station_events (org_id, station_id, kind, details, by_name)
  select org_id, id, p_kind, coalesce(p_details, '{}'), private.actor_label() from public.stations where id = p_station
$$;

create function private.station_history()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then perform private.station_event(new.id, 'added'); return null; end if;
  if new.removed_at is not null and old.removed_at is null then perform private.station_event(new.id, 'removed'); return null; end if;
  if new.replaced_at is not null and new.replaced_at is distinct from old.replaced_at then
    perform private.station_event(new.id, 'replaced', jsonb_strip_nulls(jsonb_build_object('unit', nullif(current_setting('app.station_unit', true), ''))));
  else
    if new.activated_at is not null and old.activated_at is null then perform private.station_event(new.id, 'set_up'); end if;
    if new.revoked_at is not null and old.revoked_at is null then perform private.station_event(new.id, 'disconnected'); end if;
  end if;
  if new.name is distinct from old.name then
    perform private.station_event(new.id, 'renamed', jsonb_build_object('from', old.name, 'to', new.name));
  end if;
  if new.location_id is distinct from old.location_id then
    perform private.station_event(new.id, 'moved_location', jsonb_build_object(
      'from', (select name from public.locations where id = old.location_id), 'to', (select name from public.locations where id = new.location_id)));
  end if;
  if new.contract_id is distinct from old.contract_id then
    perform private.station_event(new.id, 'moved_contract', jsonb_build_object(
      'from', (select name from public.contracts where id = old.contract_id), 'to', (select name from public.contracts where id = new.contract_id)));
  end if;
  return null;
end $$;
create trigger station_history_insert after insert on public.stations for each row execute function private.station_history();
create trigger station_history_update after update on public.stations for each row
  when (row(old.name, old.location_id, old.contract_id, old.activated_at, old.revoked_at, old.removed_at, old.replaced_at)
        is distinct from row(new.name, new.location_id, new.contract_id, new.activated_at, new.revoked_at, new.removed_at, new.replaced_at))
  execute function private.station_history();

-- What we know about stations that already exist.
insert into public.station_events (org_id, station_id, at, kind)
select org_id, id, created_at, 'added' from public.stations
union all select org_id, id, activated_at, 'set_up' from public.stations where activated_at is not null
union all select org_id, id, revoked_at, 'disconnected' from public.stations where revoked_at is not null and removed_at is null
union all select org_id, id, removed_at, 'removed' from public.stations where removed_at is not null
union all select org_id, id, replaced_at, 'replaced' from public.stations where replaced_at is not null;

-- New codes are logged where they're made (the station row may not change).
create or replace function public.reset_station_activation(p_station uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_org uuid; v_removed timestamptz; v_code text := private.new_activation_code();
begin
  select org_id, removed_at into v_org, v_removed from public.stations where id = p_station;
  if v_org is null or not private.has_org_role(v_org, 'admin') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if v_removed is not null then raise exception 'station removed' using errcode = '42501'; end if;
  update private.station_keys set
    device_key_hash = null,
    activation_code_hash = private.sha256_hex(private.normalize_code(v_code)),
    activation_expires_at = now() + interval '7 days'
  where station_id = p_station;
  update public.stations set activated_at = null, revoked_at = null, admin_claimed_at = null where id = p_station;
  perform private.station_event(p_station, 'new_code');
  return jsonb_build_object('station_id', p_station, 'activation_code', v_code,
                            'expires_at', now() + interval '7 days');
end $$;

create or replace function public.platform_station_code(p_station uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_org uuid; v_removed timestamptz; v_code text := private.new_activation_code();
begin
  perform private.require_operator();
  select org_id, removed_at into v_org, v_removed from public.stations where id = p_station;
  if v_org is null then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if v_removed is not null then return jsonb_build_object('ok', false, 'error', 'removed'); end if;
  update private.station_keys set device_key_hash = null,
    activation_code_hash = private.sha256_hex(private.normalize_code(v_code)), activation_expires_at = now() + interval '7 days'
  where station_id = p_station;
  update public.stations set activated_at = null, revoked_at = null, admin_claimed_at = null where id = p_station;
  perform private.station_event(p_station, 'new_code');
  perform private.plog(v_org, 'new activation code', jsonb_build_object('station', (select name from public.stations where id = p_station)));
  return jsonb_build_object('ok', true, 'station_id', p_station, 'activation_code', v_code, 'expires_at', now() + interval '7 days');
end $$;


create or replace function public.platform_replace_station(p_station uuid, p_unit uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.stations; u private.hardware_units; v_code text := private.new_activation_code(); v_old int;
begin
  perform private.require_operator();
  select * into s from public.stations where id = p_station for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if s.removed_at is not null then return jsonb_build_object('ok', false, 'error', 'removed'); end if;
  if p_unit is not null then
    select * into u from private.hardware_units where id = p_unit for update;
    if not found then return jsonb_build_object('ok', false, 'error', 'unit_not_found'); end if;
    if u.station_id = p_station then return jsonb_build_object('ok', false, 'error', 'same_unit'); end if;
    if u.status not in ('ready', 'returned') or u.station_id is not null or (u.org_id is not null and u.org_id <> s.org_id) then
      return jsonb_build_object('ok', false, 'error', 'unit_not_in_stock');
    end if;
  end if;

  v_old := private.release_station_hardware(p_station, 'repair', 'replaced');
  if p_unit is not null then
    update private.hardware_units set org_id = s.org_id, station_id = p_station, status = 'ready', updated_at = now() where id = p_unit;
    insert into private.hardware_events (unit_id, operator, action, details)
    values (p_unit, auth.uid(), 'replacement', jsonb_build_object('station', s.name, 'customer', (select name from public.organizations where id = s.org_id)));
  end if;

  update private.station_keys set device_key_hash = null,
    activation_code_hash = private.sha256_hex(private.normalize_code(v_code)), activation_expires_at = now() + interval '7 days'
  where station_id = p_station;
  perform set_config('app.station_unit', coalesce(u.serial, ''), true);   -- for the station's history
  update public.stations set activated_at = null, revoked_at = null, admin_claimed_at = null, last_seen_at = null, replaced_at = now()
   where id = p_station;
  perform private.plog(s.org_id, 'replaced station hardware', jsonb_build_object('station', s.name)
    || case when p_unit is not null then jsonb_build_object('unit', u.serial) else '{}'::jsonb end);
  return jsonb_build_object('ok', true, 'station_id', p_station, 'activation_code', v_code, 'expires_at', now() + interval '7 days',
    'unit', u.serial, 'old_units', v_old);
end $$;


-- ---------------------------------------------------------------------
-- Console: rename a station, move it to another location or contract.
-- p: {name?, location? (a name; blank = none), contract_id? (blank = whole company)}
-- ---------------------------------------------------------------------
create function public.platform_update_station(p_station uuid, p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.stations; v_name text; v_loc uuid; v_contract uuid;
begin
  perform private.require_operator();
  select * into s from public.stations where id = p_station for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if s.removed_at is not null then return jsonb_build_object('ok', false, 'error', 'removed'); end if;
  v_name := case when p ? 'name' then regexp_replace(trim(p->>'name'), '\s+', ' ', 'g') else s.name end;
  if coalesce(v_name, '') = '' or length(v_name) > 60 then return jsonb_build_object('ok', false, 'error', 'name_required'); end if;
  if exists (select 1 from public.stations where org_id = s.org_id and id <> s.id and revoked_at is null and lower(name) = lower(v_name)) then
    return jsonb_build_object('ok', false, 'error', 'duplicate_name');
  end if;
  v_contract := case when p ? 'contract_id' then nullif(p->>'contract_id', '')::uuid else s.contract_id end;
  if v_contract is not null and not exists (select 1 from public.contracts where id = v_contract and org_id = s.org_id) then
    return jsonb_build_object('ok', false, 'error', 'unknown_contract');
  end if;
  if p ? 'location' then
    if nullif(trim(p->>'location'), '') is null then v_loc := null;
    else
      select id into v_loc from public.locations where org_id = s.org_id and lower(name) = lower(trim(p->>'location')) order by created_at limit 1;
      if v_loc is null then
        if length(trim(p->>'location')) > 60 then return jsonb_build_object('ok', false, 'error', 'location_too_long'); end if;
        insert into public.locations (org_id, name) values (s.org_id, trim(p->>'location')) returning id into v_loc;
      end if;
    end if;
  else v_loc := s.location_id;
  end if;
  update public.stations set name = v_name, location_id = v_loc, contract_id = v_contract where id = p_station;
  if row(v_name, v_loc, v_contract) is distinct from row(s.name, s.location_id, s.contract_id) then
    perform private.plog(s.org_id, 'updated station', jsonb_build_object('station', v_name));
  end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.platform_customer(p_org uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare o public.organizations;
begin
  perform private.require_operator();
  select * into o from public.organizations where id = p_org;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  return jsonb_build_object('ok', true,
    'organization', to_jsonb(o) || jsonb_build_object('notes', (select notes from private.customer_notes where org_id = p_org)),
    'stations', coalesce((select jsonb_agg(jsonb_build_object(
        'id', s.id, 'name', s.name, 'location', l.name, 'activated_at', s.activated_at, 'revoked_at', s.revoked_at,
        'last_seen_at', s.last_seen_at, 'software_version', s.software_version, 'admin_claimed_at', s.admin_claimed_at,
        'code_expires_at', k.activation_expires_at, 'created_at', s.created_at, 'contract_id', s.contract_id, 'replaced_at', s.replaced_at) order by s.created_at)
      from public.stations s left join public.locations l on l.id = s.location_id
      left join private.station_keys k on k.station_id = s.id where s.org_id = p_org and s.removed_at is null), '[]'::jsonb),
    'locations', coalesce((select jsonb_agg(l.name order by l.name) from public.locations l where l.org_id = p_org), '[]'::jsonb),
    'station_events', coalesce((select jsonb_agg(jsonb_build_object('station_id', e.station_id, 'at', e.at, 'kind', e.kind, 'details', e.details, 'by', e.by_name)
        order by e.at desc, e.id desc) from (select * from public.station_events where org_id = p_org order by at desc, id desc limit 300) e), '[]'::jsonb),
    'contracts', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'parent_id', c.parent_id, 'name', c.name, 'share', c.share_children, 'move', c.move_on_return)
        order by c.sort_order, c.name) from public.contracts c where c.org_id = p_org), '[]'::jsonb),
    'members', coalesce((select jsonb_agg(jsonb_build_object('email', u.email, 'name', nullif(trim(u.raw_user_meta_data->>'full_name'), ''), 'role', m.role, 'last_sign_in_at', u.last_sign_in_at)
        order by m.role desc, u.email)
      from public.org_members m join auth.users u on u.id = m.user_id where m.org_id = p_org), '[]'::jsonb),
    'invites', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'email', i.email, 'role', i.role, 'expires_at', i.expires_at))
      from public.org_invites i where i.org_id = p_org and i.accepted_at is null and i.expires_at > now()), '[]'::jsonb),
    'log', coalesce((select jsonb_agg(jsonb_build_object('at', g.at, 'action', g.action, 'details', g.details,
        'by', coalesce(po.name, u.email)) order by g.at desc)
      from (select * from private.platform_log where org_id = p_org order by at desc limit 50) g
      left join private.platform_operators po on po.user_id = g.operator left join auth.users u on u.id = g.operator), '[]'::jsonb));
end $$;

revoke execute on all functions in schema private from public, anon, authenticated;
grant  execute on function private.has_org_role(uuid, public.member_role) to authenticated;
grant  execute on function private.normalize_uid(text) to anon, authenticated;
grant  execute on function private.resolve_time_limit(public.time_limit_mode, numeric, public.time_limit_type, numeric) to authenticated;
grant  execute on function private.can_manage_logo(text) to authenticated;
grant  execute on function private.can_see(uuid, uuid), private.can_see_equipment(uuid), private.can_see_txn(uuid, uuid, uuid, uuid),
  private.can_see_tap(uuid, uuid, uuid, uuid), private.sees(uuid, uuid, uuid), private.scope_of(uuid, uuid) to authenticated;
revoke execute on function public.platform_update_station(uuid, jsonb) from public;
grant  execute on function public.platform_update_station(uuid, jsonb) to authenticated;
