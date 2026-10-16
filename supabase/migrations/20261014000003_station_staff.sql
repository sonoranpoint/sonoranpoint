-- =====================================================================
-- Manager and admin fobs: staff actions from the station itself
--
-- A fob is an employee badge whose station_role is 'manager' or 'admin'.
-- Tapping one opens the staff menu. Because NFC badge IDs can be copied,
-- staff fobs can (and from the station, must) have a 4–8 digit PIN.
-- 5 wrong PINs lock that fob for 15 minutes.
--
--   manager: add employees (+ their badge), add equipment (+ its tag),
--            mark items lost / maintenance / back in service,
--            replace a lost badge or tag (for regular employees)
--   admin:   all of that, plus make people managers/admins, set PINs,
--            deactivate employees, retire equipment
--
-- Every change is written to the audit log with the fob holder as the actor.
-- =====================================================================

create function private.valid_pin(p_pin text)
returns boolean language sql immutable as $$ select coalesce(p_pin ~ '^[0-9]{4,8}$', false) $$;

create function private.set_pin(p_employee uuid, p_pin text)
returns void language sql security definer set search_path = public as $$
  insert into private.staff_pins (employee_id, pin_hash)
  values (p_employee, private.sha256_hex(p_employee::text || ':' || p_pin))
  on conflict (employee_id) do update set pin_hash = excluded.pin_hash, failures = 0, locked_until = null
$$;

-- Checks station key + fob + role + PIN. On success, marks the fob holder as
-- the actor for the audit log for the rest of this request.
create function private.staff_session(p_device_key text, p_badge_uid text, p_pin text, p_min public.station_role)
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
  update public.stations set last_seen_at = now() where id = s.id;
  return jsonb_build_object('ok', true, 'station_id', s.id, 'org_id', s.org_id,
    'staff', jsonb_build_object('id', e.id, 'name', trim(e.first_name || ' ' || e.last_name), 'role', e.station_role));
end $$;

-- Is this NFC ID already used by someone or something in the company?
create function private.uid_owner(p_org uuid, p_uid text, p_except uuid default null)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(
    (select jsonb_build_object('kind', 'badge', 'name', trim(first_name || ' ' || last_name))
       from public.employees where org_id = p_org and badge_uid = private.normalize_uid(p_uid)
        and id is distinct from p_except limit 1),
    (select jsonb_build_object('kind', 'tag', 'name', name)
       from public.equipment where org_id = p_org and nfc_uid = private.normalize_uid(p_uid)
        and id is distinct from p_except limit 1))
$$;

-- ---------------------------------------------------------------------
-- Opening the staff menu
-- ---------------------------------------------------------------------
create function public.station_staff_login(p_device_key text, p_badge_uid text, p_pin text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare ss jsonb; v_org uuid;
begin
  ss := private.staff_session(p_device_key, p_badge_uid, p_pin, 'manager');
  if not (ss->>'ok')::boolean then return ss; end if;
  v_org := (ss->>'org_id')::uuid;
  return jsonb_build_object(
    'ok', true,
    'staff', ss->'staff',
    'categories', coalesce((select jsonb_agg(jsonb_build_object(
        'id', c.id, 'name', c.name,
        'names', coalesce((select jsonb_agg(q.name order by q.name) from public.equipment q where q.category_id = c.id), '[]'::jsonb))
        order by c.sort_order, c.name)
      from public.equipment_categories c where c.org_id = v_org), '[]'::jsonb),
    'employees', coalesce((select jsonb_agg(jsonb_build_object(
        'id', e.id, 'name', trim(e.first_name || ' ' || e.last_name),
        'first_name', e.first_name, 'last_name', e.last_name, 'employee_number', e.employee_number,
        'role', e.station_role, 'active', e.active, 'has_badge', e.badge_uid is not null,
        'has_pin', exists (select 1 from private.staff_pins p where p.employee_id = e.id))
        order by e.active desc, e.first_name, e.last_name)
      from public.employees e where e.org_id = v_org), '[]'::jsonb),
    -- Equipment added on the dashboard without a tag yet, so it can be tagged here.
    'untagged', coalesce((select jsonb_agg(jsonb_build_object('id', q.id, 'name', q.name,
        'category', (select name from public.equipment_categories where id = q.category_id)) order by q.name)
      from public.equipment q where q.org_id = v_org and q.nfc_uid is null and q.status <> 'retired'), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------
-- Add an employee and register their badge
-- ---------------------------------------------------------------------
create function public.station_add_employee(
  p_device_key text, p_badge_uid text, p_pin text,
  p_first_name text, p_last_name text, p_employee_number text, p_new_badge_uid text,
  p_role public.station_role default 'employee', p_new_pin text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare ss jsonb; v_org uuid; v_owner jsonb; v_emp uuid; v_num text := nullif(trim(p_employee_number), '');
begin
  ss := private.staff_session(p_device_key, p_badge_uid, p_pin, 'manager');
  if not (ss->>'ok')::boolean then return ss; end if;
  v_org := (ss->>'org_id')::uuid;

  if coalesce(trim(p_first_name), '') = '' then return jsonb_build_object('ok', false, 'error', 'name_required'); end if;
  if p_role > 'employee' and ss->'staff'->>'role' <> 'admin' then return jsonb_build_object('ok', false, 'error', 'admin_only'); end if;
  if p_role > 'employee' and not private.valid_pin(p_new_pin) then return jsonb_build_object('ok', false, 'error', 'pin_needed'); end if;
  if private.normalize_uid(p_new_badge_uid) is null then return jsonb_build_object('ok', false, 'error', 'no_badge'); end if;
  v_owner := private.uid_owner(v_org, p_new_badge_uid);
  if v_owner is not null then
    return jsonb_build_object('ok', false, 'error', case when v_owner->>'kind' = 'badge' then 'badge_in_use' else 'tag_is_equipment' end, 'used_by', v_owner->>'name');
  end if;
  if v_num is not null and exists (select 1 from public.employees where org_id = v_org and employee_number = v_num) then
    return jsonb_build_object('ok', false, 'error', 'number_in_use',
      'used_by', (select trim(first_name || ' ' || last_name) from public.employees where org_id = v_org and employee_number = v_num));
  end if;

  insert into public.employees (org_id, first_name, last_name, employee_number, badge_uid, station_role)
  values (v_org, trim(p_first_name), coalesce(trim(p_last_name), ''), v_num, private.normalize_uid(p_new_badge_uid), p_role)
  returning id into v_emp;
  if p_role > 'employee' then perform private.set_pin(v_emp, p_new_pin); end if;
  return jsonb_build_object('ok', true, 'employee', jsonb_build_object('id', v_emp,
    'name', trim(trim(p_first_name) || ' ' || coalesce(trim(p_last_name), '')), 'role', p_role));
end $$;

-- ---------------------------------------------------------------------
-- Add equipment and register its tag
-- ---------------------------------------------------------------------
create function public.station_add_equipment(
  p_device_key text, p_badge_uid text, p_pin text,
  p_name text, p_category_id uuid, p_tag_uid text, p_asset_tag text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare ss jsonb; v_org uuid; v_owner jsonb; v_eq uuid; v_asset text := nullif(trim(p_asset_tag), '');
begin
  ss := private.staff_session(p_device_key, p_badge_uid, p_pin, 'manager');
  if not (ss->>'ok')::boolean then return ss; end if;
  v_org := (ss->>'org_id')::uuid;

  if coalesce(trim(p_name), '') = '' then return jsonb_build_object('ok', false, 'error', 'name_required'); end if;
  if not exists (select 1 from public.equipment_categories where id = p_category_id and org_id = v_org) then
    return jsonb_build_object('ok', false, 'error', 'unknown_category');
  end if;
  if private.normalize_uid(p_tag_uid) is null then return jsonb_build_object('ok', false, 'error', 'no_tag'); end if;
  v_owner := private.uid_owner(v_org, p_tag_uid);
  if v_owner is not null then
    return jsonb_build_object('ok', false, 'error', case when v_owner->>'kind' = 'tag' then 'tag_in_use' else 'tag_is_badge' end, 'used_by', v_owner->>'name');
  end if;
  if v_asset is not null and exists (select 1 from public.equipment where org_id = v_org and asset_tag = v_asset) then
    return jsonb_build_object('ok', false, 'error', 'asset_tag_in_use');
  end if;

  insert into public.equipment (org_id, category_id, name, asset_tag, nfc_uid,
                                home_location_id)
  values (v_org, p_category_id, trim(p_name), v_asset, private.normalize_uid(p_tag_uid),
          (select location_id from public.stations where id = (ss->>'station_id')::uuid))
  returning id into v_eq;
  return jsonb_build_object('ok', true, 'equipment', jsonb_build_object('id', v_eq, 'name', trim(p_name)));
end $$;

-- ---------------------------------------------------------------------
-- Lost / maintenance / back in service (retire: admins)
-- ---------------------------------------------------------------------
create function public.station_set_item_status(
  p_device_key text, p_badge_uid text, p_pin text, p_equipment_uid text, p_status public.equipment_status)
returns jsonb language plpgsql security definer set search_path = public as $$
declare ss jsonb; eq public.equipment;
begin
  ss := private.staff_session(p_device_key, p_badge_uid, p_pin,
                              case when p_status = 'retired' then 'admin' else 'manager' end::public.station_role);
  if not (ss->>'ok')::boolean then return ss; end if;
  select * into eq from public.equipment
   where org_id = (ss->>'org_id')::uuid and nfc_uid = private.normalize_uid(p_equipment_uid) for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'unknown_equipment'); end if;
  update public.equipment set status = case
      when p_status in ('available', 'checked_out')
        then case when current_employee_id is not null then 'checked_out' else 'available' end::public.equipment_status
      else p_status end
   where id = eq.id;
  if p_status = 'lost' then
    update public.equipment_alerts set resolved_at = now() where equipment_id = eq.id and resolved_at is null;
  end if;
  return jsonb_build_object('ok', true, 'equipment', jsonb_build_object('id', eq.id, 'name', eq.name,
    'status', (select status from public.equipment where id = eq.id)));
end $$;

-- ---------------------------------------------------------------------
-- Replace a lost badge or a damaged tag
-- ---------------------------------------------------------------------
create function public.station_replace_uid(
  p_device_key text, p_badge_uid text, p_pin text, p_kind text, p_target uuid, p_new_uid text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare ss jsonb; v_org uuid; v_owner jsonb; v_role public.station_role;
begin
  ss := private.staff_session(p_device_key, p_badge_uid, p_pin, 'manager');
  if not (ss->>'ok')::boolean then return ss; end if;
  v_org := (ss->>'org_id')::uuid;
  if private.normalize_uid(p_new_uid) is null then return jsonb_build_object('ok', false, 'error', 'no_tag'); end if;
  v_owner := private.uid_owner(v_org, p_new_uid, p_target);
  if v_owner is not null then
    return jsonb_build_object('ok', false, 'error', case when v_owner->>'kind' = 'badge' then 'badge_in_use' else 'tag_in_use' end,
                              'used_by', v_owner->>'name');
  end if;
  if p_kind = 'employee' then
    select station_role into v_role from public.employees where id = p_target and org_id = v_org;
    if not found then return jsonb_build_object('ok', false, 'error', 'unknown_employee'); end if;
    -- Re-badging a manager/admin fob is an admin job.
    if v_role > 'employee' and ss->'staff'->>'role' <> 'admin' then return jsonb_build_object('ok', false, 'error', 'admin_only'); end if;
    update public.employees set badge_uid = private.normalize_uid(p_new_uid) where id = p_target;
  elsif p_kind = 'equipment' then
    update public.equipment set nfc_uid = private.normalize_uid(p_new_uid) where id = p_target and org_id = v_org;
    if not found then return jsonb_build_object('ok', false, 'error', 'unknown_equipment'); end if;
  else
    return jsonb_build_object('ok', false, 'error', 'bad_kind');
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------
-- Admins: roles, PINs, deactivate / reactivate
-- ---------------------------------------------------------------------
create function public.station_update_employee(
  p_device_key text, p_badge_uid text, p_pin text, p_employee uuid,
  p_role public.station_role default null, p_active boolean default null, p_new_pin text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare ss jsonb; e public.employees; v_role public.station_role;
begin
  ss := private.staff_session(p_device_key, p_badge_uid, p_pin, 'admin');
  if not (ss->>'ok')::boolean then return ss; end if;
  select * into e from public.employees where id = p_employee and org_id = (ss->>'org_id')::uuid for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'unknown_employee'); end if;
  -- Don't let an admin lock themselves out by accident.
  if e.id = (ss->'staff'->>'id')::uuid and (p_active is false or (p_role is not null and p_role <> e.station_role)) then
    return jsonb_build_object('ok', false, 'error', 'cant_change_self');
  end if;
  if p_new_pin is not null and not private.valid_pin(p_new_pin) then return jsonb_build_object('ok', false, 'error', 'pin_needed'); end if;
  v_role := coalesce(p_role, e.station_role);
  if v_role > 'employee' and p_new_pin is null and not exists (select 1 from private.staff_pins where employee_id = e.id) then
    return jsonb_build_object('ok', false, 'error', 'pin_needed');
  end if;

  update public.employees set station_role = v_role, active = coalesce(p_active, active) where id = e.id;
  if p_new_pin is not null then perform private.set_pin(e.id, p_new_pin); end if;
  if v_role = 'employee' then delete from private.staff_pins where employee_id = e.id; end if;
  return jsonb_build_object('ok', true, 'employee', (select jsonb_build_object('id', id, 'role', station_role, 'active', active)
                                                    from public.employees where id = e.id));
end $$;

-- Same two admin jobs from the dashboard (company admins).
create function public.set_employee_station_role(p_employee uuid, p_role public.station_role, p_pin text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_org uuid;
begin
  select org_id into v_org from public.employees where id = p_employee;
  if v_org is null or not private.has_org_role(v_org, 'admin') then raise exception 'not allowed' using errcode = '42501'; end if;
  if p_pin is not null and not private.valid_pin(p_pin) then return jsonb_build_object('ok', false, 'error', 'pin_needed'); end if;
  update public.employees set station_role = p_role where id = p_employee;
  if p_pin is not null then perform private.set_pin(p_employee, p_pin); end if;
  if p_role = 'employee' then delete from private.staff_pins where employee_id = p_employee; end if;
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------
-- First-time setup: register the admin tag that shipped with the station.
-- Allowed once per activation, within 60 minutes of activating, so the
-- one-time activation code is what authorizes it.
--   blank tag             -> new admin employee with that tag + PIN
--   already an admin fob  -> nothing to do (sets the PIN if one is given)
--   anyone else's badge / an equipment tag -> refused
-- ---------------------------------------------------------------------
create function public.station_claim_admin_tag(
  p_device_key text, p_tag_uid text, p_first_name text default null, p_last_name text default null, p_pin text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.stations; e public.employees; v_owner jsonb; v_emp uuid;
begin
  s := private.station_from_key(p_device_key);
  if s.id is null then return private.station_denied(p_device_key); end if;
  if s.admin_claimed_at is not null or s.activated_at < now() - interval '60 minutes' then
    return jsonb_build_object('ok', false, 'error', 'setup_window_closed');
  end if;
  if private.normalize_uid(p_tag_uid) is null then return jsonb_build_object('ok', false, 'error', 'no_tag'); end if;

  select * into e from public.employees where org_id = s.org_id and badge_uid = private.normalize_uid(p_tag_uid);
  if found then
    if e.station_role <> 'admin' or not e.active then
      return jsonb_build_object('ok', false, 'error', 'badge_in_use', 'used_by', trim(e.first_name || ' ' || e.last_name));
    end if;
    perform set_config('app.actor_employee', e.id::text, true);
    if p_pin is not null then
      if not private.valid_pin(p_pin) then return jsonb_build_object('ok', false, 'error', 'pin_needed'); end if;
      perform private.set_pin(e.id, p_pin);
    end if;
    update public.stations set admin_claimed_at = now() where id = s.id;
    return jsonb_build_object('ok', true, 'existing', true,
      'employee', jsonb_build_object('id', e.id, 'name', trim(e.first_name || ' ' || e.last_name), 'role', 'admin'),
      'has_pin', exists (select 1 from private.staff_pins where employee_id = e.id));
  end if;

  v_owner := private.uid_owner(s.org_id, p_tag_uid);
  if v_owner is not null then return jsonb_build_object('ok', false, 'error', 'tag_is_equipment', 'used_by', v_owner->>'name'); end if;
  if p_first_name is null then return jsonb_build_object('ok', true, 'existing', false, 'needs', 'name_and_pin'); end if;  -- tag checked, ask for details
  if coalesce(trim(p_first_name), '') = '' then return jsonb_build_object('ok', false, 'error', 'name_required'); end if;
  if not private.valid_pin(p_pin) then return jsonb_build_object('ok', false, 'error', 'pin_needed'); end if;

  v_emp := gen_random_uuid();
  perform set_config('app.actor_employee', v_emp::text, true);   -- the new admin is credited with their own setup
  insert into public.employees (id, org_id, first_name, last_name, badge_uid, station_role)
  values (v_emp, s.org_id, trim(p_first_name), coalesce(trim(p_last_name), ''), private.normalize_uid(p_tag_uid), 'admin');
  perform private.set_pin(v_emp, p_pin);
  update public.stations set admin_claimed_at = now() where id = s.id;
  return jsonb_build_object('ok', true, 'existing', false,
    'employee', jsonb_build_object('id', v_emp, 'name', trim(trim(p_first_name) || ' ' || coalesce(trim(p_last_name), '')), 'role', 'admin'));
end $$;

-- ---------------------------------------------------------------------
-- Permissions
-- ---------------------------------------------------------------------
revoke execute on all functions in schema private from public, anon, authenticated;
grant  execute on function private.has_org_role(uuid, public.member_role) to authenticated;
grant  execute on function private.normalize_uid(text) to anon, authenticated;
grant  execute on function private.resolve_time_limit(public.time_limit_mode, numeric, public.time_limit_type, numeric) to authenticated;

revoke execute on function
  public.station_staff_login(text, text, text),
  public.station_add_employee(text, text, text, text, text, text, text, public.station_role, text),
  public.station_add_equipment(text, text, text, text, uuid, text, text),
  public.station_set_item_status(text, text, text, text, public.equipment_status),
  public.station_replace_uid(text, text, text, text, uuid, text),
  public.station_update_employee(text, text, text, uuid, public.station_role, boolean, text),
  public.set_employee_station_role(uuid, public.station_role, text),
  public.station_claim_admin_tag(text, text, text, text, text)
from public;
grant execute on function
  public.station_staff_login(text, text, text),
  public.station_add_employee(text, text, text, text, text, text, text, public.station_role, text),
  public.station_add_equipment(text, text, text, text, uuid, text, text),
  public.station_set_item_status(text, text, text, text, public.equipment_status),
  public.station_replace_uid(text, text, text, text, uuid, text),
  public.station_update_employee(text, text, text, uuid, public.station_role, boolean, text),
  public.station_claim_admin_tag(text, text, text, text, text)
to anon, authenticated;
grant execute on function public.set_employee_station_role(uuid, public.station_role, text) to authenticated;
