-- =====================================================================
-- 20: Removing and replacing stations
--   * Remove a station for good (customer admins, or you from the console): it leaves every
--     station list, its taps stay in history under its name, and the box it ran on goes back
--     to "returned" on your Hardware page. Removing also disconnects it if it was still on.
--   * Replace a station's hardware (console): the same station (name, contract, history) moves
--     to a new box. You pick a unit from stock (or none, if you don't track it) and get a new
--     activation code; the old unit is marked "repair". The customer sees "Replaced on ...".
-- =====================================================================
alter table public.stations add column removed_at timestamptz, add column replaced_at timestamptz;

-- The box a station ran on goes back to you.
create function private.release_station_hardware(p_station uuid, p_status text, p_reason text)
returns int language plpgsql security definer set search_path = public as $$
declare v_st text; v_org text; n int;
begin
  select s.name, o.name into v_st, v_org from public.stations s join public.organizations o on o.id = s.org_id where s.id = p_station;
  with done as (
    update private.hardware_units set status = p_status, station_id = null,
           org_id = case when p_status = 'returned' then null else org_id end, updated_at = now()
     where station_id = p_station and status not in ('retired') returning id)
  insert into private.hardware_events (unit_id, operator, action, details)
  select id, auth.uid(), 'status: ' || p_status, jsonb_build_object('reason', p_reason, 'station', v_st, 'customer', v_org) from done;
  get diagnostics n = row_count;
  return n;
end $$;

create function private.remove_station(p_station uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.stations;
begin
  select * into s from public.stations where id = p_station for update;
  if s.removed_at is not null then return jsonb_build_object('ok', true, 'already', true); end if;
  update private.station_keys set device_key_hash = null, activation_code_hash = null where station_id = p_station;
  update public.stations set removed_at = now(), revoked_at = coalesce(revoked_at, now()) where id = p_station;
  perform private.release_station_hardware(p_station, 'returned', 'station removed');
  perform private.plog(s.org_id, 'removed station', jsonb_build_object('station', s.name));
  return jsonb_build_object('ok', true);
end $$;

-- Customer admins (who can see the station's contract).
create function public.remove_station(p_station uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.stations;
begin
  select * into s from public.stations where id = p_station;
  if not found or not private.has_org_role(s.org_id, 'admin') or not private.can_see(s.org_id, s.contract_id) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  return private.remove_station(p_station);
end $$;

create function public.platform_remove_station(p_station uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform private.require_operator();
  if not exists (select 1 from public.stations where id = p_station) then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  return private.remove_station(p_station);
end $$;

-- New box for the same station. p_unit: a station unit that's in stock (ready or returned), or null.
create function public.platform_replace_station(p_station uuid, p_unit uuid default null)
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
  update public.stations set activated_at = null, revoked_at = null, admin_claimed_at = null, last_seen_at = null, replaced_at = now()
   where id = p_station;
  perform private.plog(s.org_id, 'replaced station hardware', jsonb_build_object('station', s.name)
    || case when p_unit is not null then jsonb_build_object('unit', u.serial) else '{}'::jsonb end);
  return jsonb_build_object('ok', true, 'station_id', p_station, 'activation_code', v_code, 'expires_at', now() + interval '7 days',
    'unit', u.serial, 'old_units', v_old);
end $$;

-- A removed station can't be brought back with a new code.
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
  perform private.plog(v_org, 'new activation code', jsonb_build_object('station', (select name from public.stations where id = p_station)));
  return jsonb_build_object('ok', true, 'station_id', p_station, 'activation_code', v_code, 'expires_at', now() + interval '7 days');
end $$;

-- Console lists leave removed stations out.
create or replace function public.platform_fleet()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform private.require_operator();
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', s.id, 'name', s.name, 'org_id', o.id, 'customer', o.name, 'customer_status', o.status, 'location', l.name,
      'activated_at', s.activated_at, 'last_seen_at', s.last_seen_at, 'software_version', s.software_version,
      'admin_claimed_at', s.admin_claimed_at, 'code_expires_at', k.activation_expires_at, 'created_at', s.created_at,
      'revoked_at', s.revoked_at, 'contract_id', s.contract_id, 'replaced_at', s.replaced_at,
      'online', s.activated_at is not null and s.revoked_at is null and s.last_seen_at > now() - interval '5 minutes')
      order by o.name, s.name)
    from public.stations s join public.organizations o on o.id = s.org_id
    left join public.locations l on l.id = s.location_id left join private.station_keys k on k.station_id = s.id
    where s.removed_at is null), '[]'::jsonb);
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
grant  execute on function private.can_see(uuid, uuid), private.can_see_equipment(uuid), private.can_see_txn(uuid, uuid, uuid, uuid), private.sees(uuid, uuid, uuid), private.scope_of(uuid, uuid) to authenticated;
revoke execute on function public.remove_station(uuid), public.platform_remove_station(uuid), public.platform_replace_station(uuid, uuid) from public;
grant  execute on function public.remove_station(uuid), public.platform_remove_station(uuid), public.platform_replace_station(uuid, uuid) to authenticated;
