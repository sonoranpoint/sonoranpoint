-- 29: Adding people and items at a station with an NFC tag, a barcode, or both.
--   station_add_employee / station_add_equipment take a barcode as well (p_new_barcode / p_barcode). Either the
--   tag or the barcode is enough; with only a barcode, the tag ID is made from it (the barcode_columns trigger).
--   Older station versions keep working: the new parameters are optional and the tag ID can still be a scan.

drop function if exists public.station_add_employee(text, text, text, text, text, text, text, public.station_role, text);
drop function if exists public.station_add_equipment(text, text, text, text, uuid, text, text);

-- What a barcode would clash with in this company: the same barcode on someone (or something) else,
-- or the tag ID made from it already being someone's badge or an item's tag.
create or replace function private.barcode_owner(p_org uuid, p_table text, p_code text)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(
    case when p_table = 'employees' then (select jsonb_build_object('kind', 'badge', 'name', trim(first_name || ' ' || last_name)) from public.employees where org_id = p_org and barcode = p_code limit 1)
         else (select jsonb_build_object('kind', 'tag', 'name', name) from public.equipment where org_id = p_org and barcode = p_code limit 1) end,
    private.uid_owner(p_org, private.barcode_uid(p_code)))
$$;

create function public.station_add_employee(
  p_device_key text, p_badge_uid text, p_pin text,
  p_first_name text, p_last_name text, p_employee_number text, p_new_badge_uid text,
  p_role public.station_role default 'employee', p_new_pin text default null, p_new_barcode text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare ss jsonb; v_org uuid; v_owner jsonb; v_emp uuid; v_num text := nullif(trim(p_employee_number), '');
        v_uid text := private.normalize_uid(p_new_badge_uid); v_code text := nullif(upper(trim(p_new_barcode)), '');
begin
  ss := private.staff_session(p_device_key, p_badge_uid, p_pin, 'manager');
  if not (ss->>'ok')::boolean then return ss; end if;
  v_org := (ss->>'org_id')::uuid;

  if coalesce(trim(p_first_name), '') = '' then return jsonb_build_object('ok', false, 'error', 'name_required'); end if;
  if p_role > 'employee' and ss->'staff'->>'role' <> 'admin' then return jsonb_build_object('ok', false, 'error', 'admin_only'); end if;
  if p_role > 'employee' and not private.valid_pin(p_new_pin) then return jsonb_build_object('ok', false, 'error', 'pin_needed'); end if;
  if v_uid is null and v_code is null then return jsonb_build_object('ok', false, 'error', 'no_badge'); end if;
  if v_code is not null and length(v_code) > 40 then return jsonb_build_object('ok', false, 'error', 'barcode_too_long'); end if;
  if v_uid is not null then
    v_owner := private.uid_owner(v_org, v_uid);
    if v_owner is not null then
      return jsonb_build_object('ok', false, 'error', case when v_owner->>'kind' = 'badge' then 'badge_in_use' else 'tag_is_equipment' end, 'used_by', v_owner->>'name');
    end if;
  end if;
  if v_code is not null then
    v_owner := private.barcode_owner(v_org, 'employees', v_code);
    if v_owner is not null then
      return jsonb_build_object('ok', false, 'error', case when v_owner->>'kind' = 'badge' then 'barcode_in_use' else 'barcode_is_equipment' end, 'used_by', v_owner->>'name');
    end if;
  end if;
  if v_num is not null and exists (select 1 from public.employees where org_id = v_org and employee_number = v_num) then
    return jsonb_build_object('ok', false, 'error', 'number_in_use',
      'used_by', (select trim(first_name || ' ' || last_name) from public.employees where org_id = v_org and employee_number = v_num));
  end if;

  insert into public.employees (org_id, first_name, last_name, employee_number, badge_uid, barcode, station_role)
  values (v_org, trim(p_first_name), coalesce(trim(p_last_name), ''), v_num, v_uid, v_code, p_role)
  returning id into v_emp;
  if p_role > 'employee' then perform private.set_pin(v_emp, p_new_pin); end if;
  return jsonb_build_object('ok', true, 'employee', jsonb_build_object('id', v_emp,
    'name', trim(trim(p_first_name) || ' ' || coalesce(trim(p_last_name), '')), 'role', p_role));
end $$;

create function public.station_add_equipment(
  p_device_key text, p_badge_uid text, p_pin text,
  p_name text, p_category_id uuid, p_tag_uid text, p_asset_tag text default null, p_barcode text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare ss jsonb; v_org uuid; v_owner jsonb; v_eq uuid; v_asset text := nullif(trim(p_asset_tag), '');
        v_uid text := private.normalize_uid(p_tag_uid); v_code text := nullif(upper(trim(p_barcode)), '');
begin
  ss := private.staff_session(p_device_key, p_badge_uid, p_pin, 'manager');
  if not (ss->>'ok')::boolean then return ss; end if;
  v_org := (ss->>'org_id')::uuid;

  if coalesce(trim(p_name), '') = '' then return jsonb_build_object('ok', false, 'error', 'name_required'); end if;
  if not exists (select 1 from public.equipment_categories where id = p_category_id and org_id = v_org) then
    return jsonb_build_object('ok', false, 'error', 'unknown_category');
  end if;
  if v_uid is null and v_code is null then return jsonb_build_object('ok', false, 'error', 'no_tag'); end if;
  if v_code is not null and length(v_code) > 40 then return jsonb_build_object('ok', false, 'error', 'barcode_too_long'); end if;
  if v_uid is not null then
    v_owner := private.uid_owner(v_org, v_uid);
    if v_owner is not null then
      return jsonb_build_object('ok', false, 'error', case when v_owner->>'kind' = 'tag' then 'tag_in_use' else 'tag_is_badge' end, 'used_by', v_owner->>'name');
    end if;
  end if;
  if v_code is not null then
    v_owner := private.barcode_owner(v_org, 'equipment', v_code);
    if v_owner is not null then
      return jsonb_build_object('ok', false, 'error', case when v_owner->>'kind' = 'tag' then 'barcode_in_use' else 'barcode_is_badge' end, 'used_by', v_owner->>'name');
    end if;
  end if;
  if v_asset is not null and exists (select 1 from public.equipment where org_id = v_org and asset_tag = v_asset) then
    return jsonb_build_object('ok', false, 'error', 'asset_tag_in_use');
  end if;

  insert into public.equipment (org_id, category_id, name, asset_tag, nfc_uid, barcode, home_location_id)
  values (v_org, p_category_id, trim(p_name), v_asset, v_uid, v_code,
          (select location_id from public.stations where id = (ss->>'station_id')::uuid))
  returning id into v_eq;
  return jsonb_build_object('ok', true, 'equipment', jsonb_build_object('id', v_eq, 'name', trim(p_name)));
end $$;

revoke execute on all functions in schema private from public, anon, authenticated;
grant  execute on function private.has_org_role(uuid, public.member_role) to authenticated;
grant  execute on function private.normalize_uid(text) to anon, authenticated;
grant  execute on function private.resolve_time_limit(public.time_limit_mode, numeric, public.time_limit_type, numeric) to authenticated;
grant  execute on function private.can_manage_logo(text) to authenticated;
grant  execute on function private.can_see(uuid, uuid), private.can_see_equipment(uuid), private.can_see_txn(uuid, uuid, uuid, uuid),
  private.can_see_tap(uuid, uuid, uuid, uuid), private.sees(uuid, uuid, uuid), private.scope_of(uuid, uuid) to authenticated;
revoke execute on function
  public.station_add_employee(text, text, text, text, text, text, text, public.station_role, text, text),
  public.station_add_equipment(text, text, text, text, uuid, text, text, text)
from public;
grant execute on function
  public.station_add_employee(text, text, text, text, text, text, text, public.station_role, text, text),
  public.station_add_equipment(text, text, text, text, uuid, text, text, text)
to anon, authenticated;
