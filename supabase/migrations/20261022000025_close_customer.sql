-- =====================================================================
-- 25: Closing out a customer
--   platform_close_customer(org): their account becomes Cancelled, every station is disconnected
--   (the Pis stop recording and keep nothing new), open invites are cancelled, and every unit
--   they have is marked "Coming back" on your Hardware page. Their history, team and dashboard stay:
--   they can still sign in to look at and download it. To reopen, set them back to Active and give
--   each station a new code.
--   Hardware gets a new status, 'returning' (Coming back), between Installed and Returned.
-- =====================================================================
alter table private.hardware_units drop constraint hardware_units_status_check;
alter table private.hardware_units add constraint hardware_units_status_check
  check (status in ('building', 'ready', 'shipped', 'installed', 'returning', 'repair', 'returned', 'retired'));

create or replace function public.platform_save_hardware(p jsonb)
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
  if p ? 'status' and (p->>'status') not in ('building', 'ready', 'shipped', 'installed', 'returning', 'repair', 'returned', 'retired') then
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

create function public.platform_close_customer(p_org uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare o public.organizations; n_st int; n_hw int; n_inv int;
begin
  perform private.require_operator();
  select * into o from public.organizations where id = p_org for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  update public.organizations set status = 'cancelled' where id = p_org;
  update private.station_keys set device_key_hash = null, activation_code_hash = null
   where station_id in (select id from public.stations where org_id = p_org and removed_at is null);
  with s as (update public.stations set revoked_at = now() where org_id = p_org and revoked_at is null and removed_at is null returning 1)
  select count(*) into n_st from s;
  with h as (update private.hardware_units set status = 'returning', updated_at = now()
              where org_id = p_org and status in ('ready', 'shipped', 'installed') returning id)
  , ev as (insert into private.hardware_events (unit_id, operator, action, details)
           select id, auth.uid(), 'status: returning', jsonb_build_object('reason', 'customer closed out', 'customer', o.name) from h returning 1)
  select count(*) into n_hw from ev;
  with i as (delete from public.org_invites where org_id = p_org and accepted_at is null returning 1)
  select count(*) into n_inv from i;
  perform private.plog(p_org, 'closed out customer', jsonb_build_object('text',
    n_st || ' station' || case when n_st = 1 then '' else 's' end || ' disconnected, ' || n_hw || ' unit' || case when n_hw = 1 then '' else 's' end || ' coming back'));
  return jsonb_build_object('ok', true, 'stations', n_st, 'units', n_hw, 'invites', n_inv);
end $$;

revoke execute on all functions in schema private from public, anon, authenticated;
grant  execute on function private.has_org_role(uuid, public.member_role) to authenticated;
grant  execute on function private.normalize_uid(text) to anon, authenticated;
grant  execute on function private.resolve_time_limit(public.time_limit_mode, numeric, public.time_limit_type, numeric) to authenticated;
grant  execute on function private.can_manage_logo(text) to authenticated;
grant  execute on function private.can_see(uuid, uuid), private.can_see_equipment(uuid), private.can_see_txn(uuid, uuid, uuid, uuid),
  private.can_see_tap(uuid, uuid, uuid, uuid), private.sees(uuid, uuid, uuid), private.scope_of(uuid, uuid) to authenticated;
revoke execute on function public.platform_close_customer(uuid) from public;
grant  execute on function public.platform_close_customer(uuid) to authenticated;
