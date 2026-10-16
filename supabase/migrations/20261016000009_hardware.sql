-- =====================================================================
-- Hardware you build and ship (operator console → Hardware).
--
-- One row per physical unit: a station kit, a spare reader, a screen...
-- It follows the unit from the bench to the customer:
--   building → ready → shipped → installed   (and repair / returned / retired)
-- with who built it, Pi serial, parts, carrier + tracking, and which
-- customer and station it's assigned to. Every change is kept in its history.
--
-- When a station is activated with its code, a unit shipped for that station
-- is marked installed automatically.
--
-- Customers never see any of this.
-- =====================================================================
create sequence private.hardware_serial_seq;

create table private.hardware_units (
  id          uuid primary key default gen_random_uuid(),
  serial      text not null unique check (length(trim(serial)) between 1 and 40),
  kind        text not null default 'station' check (kind in ('station', 'reader', 'display', 'spare', 'other')),
  status      text not null default 'building' check (status in ('building', 'ready', 'shipped', 'installed', 'repair', 'returned', 'retired')),
  org_id      uuid references public.organizations(id) on delete set null,
  station_id  uuid references public.stations(id) on delete set null,
  pi_serial   text,
  software    text,
  parts       text,
  built_at    date,
  built_by    uuid references auth.users(id) on delete set null,
  shipped_at  date,
  carrier     text,
  tracking    text,
  ship_to     text,
  notes       text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index hardware_units_org on private.hardware_units (org_id);
create index hardware_units_station on private.hardware_units (station_id);

create table private.hardware_events (
  id        bigint generated always as identity primary key,
  unit_id   uuid not null references private.hardware_units(id) on delete cascade,
  at        timestamptz not null default now(),
  operator  uuid references auth.users(id) on delete set null,
  action    text not null,
  details   jsonb not null default '{}'
);
create index hardware_events_unit on private.hardware_events (unit_id, at desc);

alter table private.hardware_units enable row level security;
alter table private.hardware_events enable row level security;
revoke all on private.hardware_units, private.hardware_events from public, anon, authenticated;
revoke all on sequence private.hardware_serial_seq from public, anon, authenticated;

create function private.hardware_json(u private.hardware_units)
returns jsonb language sql stable security definer set search_path = public as $$
  select to_jsonb(u) || jsonb_build_object(
    'customer', (select name from public.organizations where id = u.org_id),
    'station', (select jsonb_build_object('name', s.name, 'location', l.name, 'activated_at', s.activated_at,
                'last_seen_at', s.last_seen_at, 'revoked_at', s.revoked_at)
               from public.stations s left join public.locations l on l.id = s.location_id where s.id = u.station_id),
    'built_by_name', (select coalesce(nullif(po.name, ''), split_part(au.email, '@', 1)) from auth.users au
                      left join private.platform_operators po on po.user_id = au.id where au.id = u.built_by))
$$;

-- Everything, newest first.
create function public.platform_hardware()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform private.require_operator();
  return coalesce((select jsonb_agg(private.hardware_json(u) order by u.created_at desc) from private.hardware_units u), '[]'::jsonb);
end $$;

-- One unit with its history.
create function public.platform_hardware_unit(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare u private.hardware_units;
begin
  perform private.require_operator();
  select * into u from private.hardware_units where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  return jsonb_build_object('ok', true, 'unit', private.hardware_json(u),
    'events', coalesce((select jsonb_agg(jsonb_build_object('at', e.at, 'action', e.action, 'details', e.details,
        'by', coalesce(nullif(po.name, ''), split_part(au.email, '@', 1), 'Automatic')) order by e.at desc, e.id desc)
      from private.hardware_events e left join auth.users au on au.id = e.operator
      left join private.platform_operators po on po.user_id = e.operator where e.unit_id = p_id), '[]'::jsonb));
end $$;

-- Add (no "id") or change a unit. Only the keys sent are changed.
-- Keys: serial, kind, status, org_id, station_id, pi_serial, software, parts, built_at,
--       shipped_at, carrier, tracking, ship_to, notes, and "note" (adds a line to its history).
-- Picking a station also sets its customer; changing the customer clears the station.
create function public.platform_save_hardware(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  u private.hardware_units; o jsonb; n jsonb; v_changed jsonb; v_st_org uuid;
  v_new boolean := not (p ? 'id');
begin
  perform private.require_operator();
  if not v_new then
    select * into u from private.hardware_units where id = (p->>'id')::uuid for update;
    if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  end if;

  -- Check everything before writing anything.
  if p ? 'serial' and not v_new and nullif(trim(p->>'serial'), '') is null then return jsonb_build_object('ok', false, 'error', 'serial_required'); end if;
  if nullif(trim(p->>'serial'), '') is not null and exists (select 1 from private.hardware_units where serial = trim(p->>'serial') and id is distinct from u.id) then
    return jsonb_build_object('ok', false, 'error', 'serial_taken');
  end if;
  if p ? 'kind' and (p->>'kind') not in ('station', 'reader', 'display', 'spare', 'other') then return jsonb_build_object('ok', false, 'error', 'bad_kind'); end if;
  if p ? 'status' and (p->>'status') not in ('building', 'ready', 'shipped', 'installed', 'repair', 'returned', 'retired') then
    return jsonb_build_object('ok', false, 'error', 'bad_status');
  end if;
  if nullif(p->>'org_id', '') is not null and not exists (select 1 from public.organizations where id = (p->>'org_id')::uuid) then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;
  if nullif(p->>'station_id', '') is not null then
    select org_id into v_st_org from public.stations where id = (p->>'station_id')::uuid;
    if v_st_org is null or (nullif(p->>'org_id', '') is not null and v_st_org <> (p->>'org_id')::uuid) then
      return jsonb_build_object('ok', false, 'error', 'station_mismatch');
    end if;
  end if;

  if v_new then
    insert into private.hardware_units (serial, built_by, built_at)
    values (coalesce(nullif(trim(p->>'serial'), ''), 'SP-' || lpad(nextval('private.hardware_serial_seq')::text, 4, '0')), auth.uid(), current_date)
    on conflict (serial) do nothing
    returning * into u;
    -- the automatic number skips any serial typed by hand
    while u.id is null loop
      insert into private.hardware_units (serial, built_by, built_at)
      values ('SP-' || lpad(nextval('private.hardware_serial_seq')::text, 4, '0'), auth.uid(), current_date)
      on conflict (serial) do nothing returning * into u;
    end loop;
  end if;
  o := to_jsonb(u);

  update private.hardware_units h set
    serial     = case when nullif(trim(p->>'serial'), '') is not null then trim(p->>'serial') else h.serial end,
    kind       = coalesce(p->>'kind', h.kind),
    status     = coalesce(p->>'status', h.status),
    org_id     = case when v_st_org is not null then v_st_org
                      when p ? 'org_id' then nullif(p->>'org_id', '')::uuid else h.org_id end,
    station_id = case when p ? 'station_id' then nullif(p->>'station_id', '')::uuid
                      when p ? 'org_id' and nullif(p->>'org_id', '')::uuid is distinct from h.org_id then null else h.station_id end,
    pi_serial  = case when p ? 'pi_serial' then nullif(trim(p->>'pi_serial'), '') else h.pi_serial end,
    software   = case when p ? 'software' then nullif(trim(p->>'software'), '') else h.software end,
    parts      = case when p ? 'parts' then nullif(trim(p->>'parts'), '') else h.parts end,
    built_at   = case when p ? 'built_at' then nullif(p->>'built_at', '')::date else h.built_at end,
    shipped_at = case when p ? 'shipped_at' then nullif(p->>'shipped_at', '')::date
                      when p->>'status' = 'shipped' and h.shipped_at is null then current_date else h.shipped_at end,
    carrier    = case when p ? 'carrier' then nullif(trim(p->>'carrier'), '') else h.carrier end,
    tracking   = case when p ? 'tracking' then nullif(trim(p->>'tracking'), '') else h.tracking end,
    ship_to    = case when p ? 'ship_to' then nullif(trim(p->>'ship_to'), '') else h.ship_to end,
    notes      = case when p ? 'notes' then nullif(trim(p->>'notes'), '') else h.notes end,
    updated_at = now()
  where h.id = u.id returning * into u;
  n := to_jsonb(u);

  -- What changed, with names instead of ids.
  v_changed := coalesce((select jsonb_object_agg(k, n -> k) from jsonb_object_keys(n) k
                         where k not in ('id', 'created_at', 'updated_at', 'built_by') and (n -> k) is distinct from (o -> k)), '{}'::jsonb);
  if v_new then v_changed := v_changed || jsonb_build_object('serial', u.serial); end if;
  if v_changed ? 'org_id' then v_changed := (v_changed - 'org_id') || jsonb_build_object('customer', (select name from public.organizations where id = u.org_id)); end if;
  if v_changed ? 'station_id' then v_changed := (v_changed - 'station_id') || jsonb_build_object('station', (select name from public.stations where id = u.station_id)); end if;
  if v_changed ? 'notes' then v_changed := (v_changed - 'notes') || '{"notes": "changed"}'; end if;
  if v_changed ? 'parts' then v_changed := (v_changed - 'parts') || '{"parts": "changed"}'; end if;

  if v_new then
    insert into private.hardware_events (unit_id, operator, action, details) values (u.id, auth.uid(), 'added', v_changed);
    perform private.plog(u.org_id, 'added hardware', jsonb_build_object('unit', u.serial, 'kind', u.kind));
  elsif v_changed <> '{}'::jsonb then
    insert into private.hardware_events (unit_id, operator, action, details)
    values (u.id, auth.uid(), case when v_changed ? 'status' then 'status: ' || u.status else 'updated' end, v_changed - 'status');
    if v_changed ? 'status' then
      perform private.plog(u.org_id, 'hardware ' || u.status, jsonb_build_object('unit', u.serial) || (v_changed - 'status'));
    end if;
  end if;
  if nullif(trim(p->>'note'), '') is not null then
    insert into private.hardware_events (unit_id, operator, action, details) values (u.id, auth.uid(), 'note', jsonb_build_object('text', trim(p->>'note')));
  end if;
  return jsonb_build_object('ok', true, 'id', u.id, 'serial', u.serial);
end $$;

-- Owners only, for units added by mistake. Retire real ones instead (keeps the history).
create function public.platform_delete_hardware(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v text;
begin
  perform private.require_platform_owner();
  delete from private.hardware_units where id = p_id returning serial into v;
  if v is null then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  perform private.plog(null, 'deleted hardware', jsonb_build_object('unit', v));
  return jsonb_build_object('ok', true);
end $$;

-- A shipped unit is installed once its station is activated.
create function private.hardware_station_activated()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.activated_at is not null and old.activated_at is null then
    with done as (
      update private.hardware_units set status = 'installed', updated_at = now()
      where station_id = new.id and status in ('ready', 'shipped') returning id)
    insert into private.hardware_events (unit_id, operator, action, details)
    select id, null, 'status: installed', jsonb_build_object('reason', 'station activated') from done;
  end if;
  return new;
end $$;
create trigger hardware_station_activated after update of activated_at on public.stations
  for each row execute function private.hardware_station_activated();

revoke execute on all functions in schema private from public, anon, authenticated;
grant  execute on function private.has_org_role(uuid, public.member_role) to authenticated;
grant  execute on function private.normalize_uid(text) to anon, authenticated;
grant  execute on function private.resolve_time_limit(public.time_limit_mode, numeric, public.time_limit_type, numeric) to authenticated;

revoke execute on function public.platform_hardware(), public.platform_hardware_unit(uuid), public.platform_save_hardware(jsonb),
  public.platform_delete_hardware(uuid) from public;
grant execute on function public.platform_hardware(), public.platform_hardware_unit(uuid), public.platform_save_hardware(jsonb),
  public.platform_delete_hardware(uuid) to authenticated;
