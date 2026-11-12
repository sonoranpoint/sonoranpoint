-- 31: Move a hardware unit to another customer.
--   platform_move_hardware(unit, org, station?, new_station_name?, old_station?) does it in one go:
--   * The station it was on at the old customer is disconnected (its key stops working, so the box can't keep
--     recording for them), or removed for good with p_old = 'remove'. Its history stays.
--   * The unit goes to the new customer, on one of their stations or a new one made here, as "In stock"
--     (ready to ship) with the old shipping details cleared.
--   * That station gets a fresh activation code (returned once): type it on the box when it arrives.
--   Both customers' activity logs and the unit's history say what happened.

create or replace function public.platform_move_hardware(p_unit uuid, p_org uuid, p_station uuid default null,
  p_new_station text default null, p_old text default 'disconnect')
returns jsonb language plpgsql security definer set search_path = public as $$
declare u private.hardware_units; v_from_org text; v_from_st text; v_to_org text; v_st uuid; v_st_name text; r jsonb; v_code jsonb;
begin
  perform private.require_operator();
  select * into u from private.hardware_units where id = p_unit for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'unit_not_found'); end if;
  if u.status = 'retired' then return jsonb_build_object('ok', false, 'error', 'retired'); end if;
  select name into v_to_org from public.organizations where id = p_org;
  if v_to_org is null then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if u.org_id = p_org then return jsonb_build_object('ok', false, 'error', 'same_customer'); end if;
  if coalesce(p_old, 'disconnect') not in ('disconnect', 'remove') then return jsonb_build_object('ok', false, 'error', 'bad_option'); end if;
  if p_station is not null then
    select id, name into v_st, v_st_name from public.stations where id = p_station and org_id = p_org and removed_at is null;
    if v_st is null then return jsonb_build_object('ok', false, 'error', 'station_mismatch'); end if;
    if exists (select 1 from private.hardware_units where station_id = p_station and id <> p_unit and status <> 'retired') then
      return jsonb_build_object('ok', false, 'error', 'station_has_unit');
    end if;
  elsif nullif(trim(p_new_station), '') is not null then
    if length(trim(p_new_station)) > 60 then return jsonb_build_object('ok', false, 'error', 'name_required'); end if;
    if exists (select 1 from public.stations where org_id = p_org and revoked_at is null and lower(name) = lower(trim(p_new_station))) then
      return jsonb_build_object('ok', false, 'error', 'duplicate_name');
    end if;
  end if;

  select o.name into v_from_org from public.organizations o where o.id = u.org_id;
  -- The old station: its key stops working (or it's removed); the unit leaves it first so it isn't marked returned.
  if u.station_id is not null then
    select name into v_from_st from public.stations where id = u.station_id;
    update private.hardware_units set station_id = null where id = p_unit;
    if p_old = 'remove' then perform private.remove_station(u.station_id);
      perform private.plog(u.org_id, 'removed station', jsonb_build_object('station', v_from_st, 'reason', 'its hardware moved to another customer'));
    else
      update private.station_keys set device_key_hash = null, activation_code_hash = null where station_id = u.station_id;
      update public.stations set revoked_at = coalesce(revoked_at, now()) where id = u.station_id;
      perform private.plog(u.org_id, 'disconnected station', jsonb_build_object('station', v_from_st, 'reason', 'its hardware moved to another customer'));
    end if;
  end if;

  -- The new station: one of theirs, or a new one.
  if v_st is null and nullif(trim(p_new_station), '') is not null then
    r := public.create_station(p_org, trim(p_new_station));
    if not coalesce((r->>'ok')::boolean, true) then raise exception 'could not add the station: %', r->>'error'; end if;
    v_st := (r->>'station_id')::uuid; v_st_name := trim(p_new_station);
    perform private.plog(p_org, 'added station', jsonb_build_object('name', v_st_name));
  end if;
  if r is not null then v_code := r;                                  -- a new station comes with its code
  elsif v_st is not null then v_code := public.platform_station_code(v_st); end if;

  update private.hardware_units set org_id = p_org, station_id = v_st, status = 'ready',
    shipped_at = null, carrier = null, tracking = null, ship_to = null, updated_at = now() where id = p_unit;
  insert into private.hardware_events (unit_id, operator, action, details)
  values (p_unit, auth.uid(), 'moved', jsonb_strip_nulls(jsonb_build_object('from_customer', v_from_org, 'from_station', v_from_st, 'customer', v_to_org, 'station', v_st_name)));
  if u.org_id is not null then perform private.plog(u.org_id, 'hardware moved out', jsonb_strip_nulls(jsonb_build_object('unit', u.serial, 'customer', v_to_org))); end if;
  perform private.plog(p_org, 'hardware moved in', jsonb_strip_nulls(jsonb_build_object('unit', u.serial, 'station', v_st_name)));
  return jsonb_build_object('ok', true, 'unit', u.serial, 'station_id', v_st, 'station', v_st_name,
    'activation_code', v_code->>'activation_code', 'expires_at', v_code->>'expires_at');
end $$;

revoke execute on function public.platform_move_hardware(uuid, uuid, uuid, text, text) from public, anon;
grant  execute on function public.platform_move_hardware(uuid, uuid, uuid, text, text) to authenticated;
