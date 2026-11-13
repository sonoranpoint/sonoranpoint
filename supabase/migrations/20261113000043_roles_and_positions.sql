-- Migration 43: one role per person, departments and positions.
--
-- * A person's role (Agent, View Only, Supervisor, Manager, Admin or one of the company's own roles) now decides both what their
--   fob can do at the station and, if they have a dashboard account, what they can do there. employees.access_role +
--   employees.custom_role_id hold it (null = Agent: badge only). station_role is worked out from it and kept for older code.
-- * Email is optional: someone can be a Supervisor at the station without a dashboard account. A linked account
--   (employees.user_id, migration 42) always has the same role as the employee record.
-- * Departments belong to a contract (Delta BW: Cabin, Janitorial, Lav, Sky Club). An employee can have several positions,
--   each a title plus an optional department (Supervisor - Cabin, Supervisor - Janitorial). Positions are labels for now.

alter table public.employees add column if not exists access_role public.member_role;
alter table public.employees add column if not exists custom_role_id uuid references public.custom_roles(id) on delete set null;

-- What a role's boxes mean at the station.
create or replace function private.station_powers(p_perms text[])
returns boolean language sql immutable as $$
  select coalesce(p_perms && array['people', 'remove_people', 'status', 'visitors', 'equipment', 'team', 'stations'], false)
$$;

-- An employee's boxes, from their role.
create or replace function private.emp_perms(p_employee uuid)
returns text[] language sql stable security definer set search_path = public as $$
  select case when e.access_role is null then '{}'::text[]
              when e.custom_role_id is not null then coalesce((select perms from public.custom_roles where id = e.custom_role_id), '{}')
              else private.role_perms(e.access_role) end
  from public.employees e where e.id = p_employee
$$;

create or replace function private.access_value(p_role public.member_role, p_custom uuid)
returns text language sql immutable as $$
  select case when p_role is null then '' when p_custom is not null then 'role:' || p_custom else p_role::text end
$$;

create or replace function private.access_label(p_role public.member_role, p_custom uuid)
returns text language sql stable security definer set search_path = public as $$
  select case when p_role is null then 'Agent'
              when p_custom is not null then coalesce((select name from public.custom_roles where id = p_custom), 'Custom role')
              else case p_role when 'viewer' then 'View Only' when 'supervisor' then 'Supervisor' when 'admin' then 'Manager' else 'Admin' end end
$$;

-- Keep station_role in step with the role (older station software and the station's menu use it). An insert or update that only
-- sets station_role (older station software, seed data) is read the old way: manager fob = Manager, admin fob = Admin.
create or replace function private.employee_station_role()
returns trigger language plpgsql security definer set search_path = public as $$
declare p text[];
begin
  if new.access_role is null and new.custom_role_id is null
     and new.station_role <> 'employee' and (tg_op = 'INSERT' or new.station_role is distinct from old.station_role) then
    new.access_role := case new.station_role when 'admin' then 'owner' else 'admin' end::public.member_role;
  end if;
  if new.custom_role_id is not null then new.access_role := 'viewer'; end if;
  if new.access_role is null then new.custom_role_id := null; end if;
  p := case when new.access_role is null then '{}'::text[]
            when new.custom_role_id is not null then coalesce((select perms from public.custom_roles where id = new.custom_role_id), '{}')
            else private.role_perms(new.access_role) end;
  new.station_role := case when 'stations' = any (p) then 'admin' when private.station_powers(p) then 'manager' else 'employee' end::public.station_role;
  return new;
end $$;

-- Existing fobs keep what they could do: manager fob -> Manager, admin fob -> Admin; a linked dashboard account's role wins.
update public.employees set access_role = case station_role when 'admin' then 'owner' else 'admin' end::public.member_role
 where station_role <> 'employee' and access_role is null;
update public.employees e set access_role = m.role, custom_role_id = m.custom_role_id
  from public.org_members m where m.org_id = e.org_id and m.user_id = e.user_id;

drop trigger if exists employee_station_role on public.employees;
create trigger employee_station_role before insert or update on public.employees for each row execute function private.employee_station_role();
update public.employees set access_role = access_role;   -- work out station_role for everyone once

-- Roles are changed only through the functions below (which check who may give what), never by writing the table directly.
create or replace function private.guard_employee_access()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if current_setting('role', true) = 'authenticated' and auth.uid() is not null
     and coalesce(current_setting('app.station_id', true), '') = '' and coalesce(current_setting('app.access_ok', true), '') <> '1' then
    if tg_op = 'INSERT' then
      if new.access_role is not null or new.custom_role_id is not null or new.user_id is not null or new.station_role <> 'employee' then
        raise exception 'not allowed' using errcode = '42501';
      end if;
    elsif new.access_role is distinct from old.access_role or new.custom_role_id is distinct from old.custom_role_id
       or new.user_id is distinct from old.user_id or new.station_role is distinct from old.station_role then
      raise exception 'not allowed' using errcode = '42501';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists a_guard_employee_access on public.employees;   -- "a_" runs it before the other triggers
create trigger a_guard_employee_access before insert or update on public.employees for each row execute function private.guard_employee_access();

-- A linked dashboard account and its employee record share one role.
create or replace function private.member_role_to_employee()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_prev text := coalesce(current_setting('app.access_ok', true), '');
begin
  perform set_config('app.access_ok', '1', true);
  update public.employees set access_role = new.role, custom_role_id = new.custom_role_id
   where org_id = new.org_id and user_id = new.user_id
     and (access_role is distinct from new.role or custom_role_id is distinct from new.custom_role_id);
  perform set_config('app.access_ok', v_prev, true);
  return null;
end $$;
drop trigger if exists member_role_to_employee on public.org_members;
create trigger member_role_to_employee after insert or update of role, custom_role_id on public.org_members
  for each row execute function private.member_role_to_employee();

-- Changing a role's boxes changes what its people's fobs can do.
create or replace function private.custom_role_to_employees()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_prev text := coalesce(current_setting('app.access_ok', true), '');
begin
  perform set_config('app.access_ok', '1', true);
  update public.employees set custom_role_id = custom_role_id where custom_role_id = new.id;
  perform set_config('app.access_ok', v_prev, true);
  return null;
end $$;
drop trigger if exists custom_role_to_employees on public.custom_roles;
create trigger custom_role_to_employees after update of perms on public.custom_roles for each row execute function private.custom_role_to_employees();

-- Station people: may this fob give a role / change this person? Same rules as the dashboard: Admins anything below Admin,
-- others with the Team box only roles whose boxes they have (never Manager or Admin).
create or replace function private.emp_can_give(p_actor uuid, p_role public.member_role, p_custom uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select case
    when p_role is null and p_custom is null then true
    when p_custom is not null then exists (select 1 from public.custom_roles c where c.id = p_custom and c.org_id = a.org_id
                                           and (a.access_role = 'owner' or ('team' = any (ap) and c.perms <@ ap)))
    when p_role = 'owner' then false
    when a.access_role = 'owner' then true
    else 'team' = any (ap) and p_role < 'admin' and private.role_perms(p_role) <@ ap end
  from public.employees a, lateral (select private.emp_perms(a.id) ap) x where a.id = p_actor
$$;

create or replace function private.emp_can_manage(p_actor uuid, p_target uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select t.access_role is null or (t.id <> p_actor and private.emp_can_give(p_actor, t.access_role, t.custom_role_id))
  from public.employees t where t.id = p_target
$$;

-- Fob + PIN check, now also with the person's boxes. A fob with station powers must have a PIN.
CREATE OR REPLACE FUNCTION private.staff_session(p_device_key text, p_badge_uid text, p_pin text, p_min station_role)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare s public.stations; e public.employees; pin private.staff_pins;
begin
  s := private.station_from_key(p_device_key);
  if s.id is null then return private.station_denied(p_device_key); end if;
  select * into e from public.employees
   where org_id = s.org_id and active and badge_uid = private.normalize_uid(p_badge_uid);
  if not found or e.station_role < 'manager' then return jsonb_build_object('ok', false, 'error', 'not_staff'); end if;
  if e.station_role < p_min then return jsonb_build_object('ok', false, 'error', 'admin_only'); end if;

  select * into pin from private.staff_pins where employee_id = e.id for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'no_pin'); end if;
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

  perform set_config('app.actor_employee', e.id::text, true);
  perform set_config('app.station_id', s.id::text, true);   -- new people and items join this station's contract
  update public.stations set last_seen_at = now() where id = s.id;
  return jsonb_build_object('ok', true, 'station_id', s.id, 'org_id', s.org_id,
    'staff', jsonb_build_object('id', e.id, 'name', trim(e.first_name || ' ' || e.last_name), 'role', e.station_role,
      'access', private.access_value(e.access_role, e.custom_role_id), 'role_label', private.access_label(e.access_role, e.custom_role_id),
      'perms', to_jsonb(private.emp_perms(e.id))));
end $function$;

-- Fob + PIN + one box (null = any station power).
create or replace function private.staff_with(p_device_key text, p_badge_uid text, p_pin text, p_perm text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare ss jsonb;
begin
  ss := private.staff_session(p_device_key, p_badge_uid, p_pin, 'manager');
  if (ss->>'ok')::boolean and p_perm is not null and not (ss->'staff'->'perms' ? p_perm) then
    return jsonb_build_object('ok', false, 'error', 'admin_only');
  end if;
  return ss;
end $$;

-- "" = Agent, "viewer"/"supervisor"/"admin"/"owner", or "role:<id>".
create or replace function private.parse_access(p text, out o_role public.member_role, out o_custom uuid)
language plpgsql immutable as $$
begin
  if p is null or p = '' then return; end if;
  if p like 'role:%' then o_custom := substr(p, 6)::uuid; o_role := 'viewer'; else o_role := p::public.member_role; end if;
end $$;

-- Station functions: each action checks the box it needs (regenerated from the current definitions).
CREATE OR REPLACE FUNCTION public.station_add_equipment(p_device_key text, p_badge_uid text, p_pin text, p_name text, p_category_id uuid, p_tag_uid text, p_asset_tag text DEFAULT NULL::text, p_barcode text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare ss jsonb; v_org uuid; v_owner jsonb; v_eq uuid; v_asset text := nullif(trim(p_asset_tag), '');
        v_uid text := private.normalize_uid(p_tag_uid); v_code text := nullif(upper(trim(p_barcode)), '');
begin
  ss := private.staff_with(p_device_key, p_badge_uid, p_pin, 'equipment');
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
end $function$;

CREATE OR REPLACE FUNCTION public.station_clear_problem(p_device_key text, p_badge_uid text, p_pin text, p_equipment_uid text, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare ss jsonb; eq public.equipment; n int;
begin
  ss := private.staff_with(p_device_key, p_badge_uid, p_pin, 'status');
  if not (ss->>'ok')::boolean then return ss; end if;
  select * into eq from public.equipment where org_id = (ss->>'org_id')::uuid and nfc_uid = private.normalize_uid(p_equipment_uid);
  if not found then return jsonb_build_object('ok', false, 'error', 'unknown_equipment'); end if;
  update public.equipment_problems set cleared_at = now(), cleared_by_employee = (ss->'staff'->>'id')::uuid,
         clear_notes = nullif(left(trim(p_notes), 500), '')
   where equipment_id = eq.id and cleared_at is null;
  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'cleared', n, 'equipment', jsonb_build_object('id', eq.id, 'name', eq.name));
end $function$;

CREATE OR REPLACE FUNCTION public.station_end_loan(p_device_key text, p_badge_uid text, p_pin text, p_equipment_uid text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare ss jsonb; v_eq uuid;
begin
  ss := private.staff_with(p_device_key, p_badge_uid, p_pin, 'status');
  if not (ss->>'ok')::boolean then return ss; end if;
  select id into v_eq from public.equipment where org_id = (ss->>'org_id')::uuid and nfc_uid = private.normalize_uid(p_equipment_uid);
  if v_eq is null then return jsonb_build_object('ok', false, 'error', 'unknown_equipment'); end if;
  return jsonb_build_object('ok', true, 'ended', private.end_loan(v_eq, 'ended', null, (ss->'staff'->>'id')::uuid));
end $function$;

CREATE OR REPLACE FUNCTION public.station_lend_equipment(p_device_key text, p_badge_uid text, p_pin text, p_equipment_uid text, p_to_contract uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare ss jsonb; v_eq uuid;
begin
  ss := private.staff_with(p_device_key, p_badge_uid, p_pin, 'status');
  if not (ss->>'ok')::boolean then return ss; end if;
  select id into v_eq from public.equipment where org_id = (ss->>'org_id')::uuid and nfc_uid = private.normalize_uid(p_equipment_uid);
  if v_eq is null then return jsonb_build_object('ok', false, 'error', 'unknown_equipment'); end if;
  return private.lend((ss->>'org_id')::uuid, v_eq, p_to_contract, null, null, (ss->'staff'->>'id')::uuid, (ss->>'station_id')::uuid);
end $function$;

CREATE OR REPLACE FUNCTION public.station_visitor_pass(p_device_key text, p_badge_uid text, p_pin text, p_visitor_badge text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r jsonb; s public.stations; m public.employees; v public.employees; v_end timestamptz; p public.visitor_passes;
begin
  r := private.staff_with(p_device_key, p_badge_uid, p_pin, 'visitors');
  if not (r->>'ok')::boolean then return r; end if;
  s := private.station_from_key(p_device_key);
  select * into m from public.employees where id = (r->'staff'->>'id')::uuid;
  if not private.contracts_share(s.org_id, s.contract_id, m.contract_id) then return jsonb_build_object('ok', false, 'error', 'not_your_station'); end if;
  select * into v from public.employees where org_id = s.org_id and active and badge_uid = private.normalize_uid(p_visitor_badge);
  if not found then return jsonb_build_object('ok', false, 'error', 'unknown_badge'); end if;
  if v.id = m.id then return jsonb_build_object('ok', false, 'error', 'not_yourself'); end if;
  if s.contract_id is null or private.contracts_share(s.org_id, s.contract_id, v.contract_id) then
    return jsonb_build_object('ok', true, 'already', true, 'employee', jsonb_build_object('id', v.id, 'name', trim(v.first_name || ' ' || v.last_name)));
  end if;
  v_end := private.end_of_today(s.org_id);
  select * into p from public.visitor_passes where employee_id = v.id and contract_id = s.contract_id and ended_at is null and ends_at > now() order by ends_at desc limit 1;
  if found then
    update public.visitor_passes set ends_at = greatest(ends_at, v_end) where id = p.id returning * into p;
  else
    insert into public.visitor_passes (org_id, employee_id, contract_id, ends_at, approved_by_employee, station_id)
    values (s.org_id, v.id, s.contract_id, v_end, m.id, s.id) returning * into p;
  end if;
  return jsonb_build_object('ok', true, 'pass_id', p.id, 'ends_at', p.ends_at,
    'employee', jsonb_build_object('id', v.id, 'name', trim(v.first_name || ' ' || v.last_name)),
    'home_contract', (select name from public.contracts where id = v.contract_id),
    'approved_by', trim(m.first_name || ' ' || m.last_name));
end $function$;

CREATE OR REPLACE FUNCTION public.station_set_item_status(p_device_key text, p_badge_uid text, p_pin text, p_equipment_uid text, p_status equipment_status)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare ss jsonb; eq public.equipment;
begin
  ss := private.staff_with(p_device_key, p_badge_uid, p_pin, case when p_status = 'retired' then 'equipment' else 'status' end);
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
end $function$;

CREATE OR REPLACE FUNCTION public.station_replace_uid(p_device_key text, p_badge_uid text, p_pin text, p_kind text, p_target uuid, p_new_uid text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare ss jsonb; v_org uuid; v_owner jsonb; v_role public.station_role;
begin
  ss := private.staff_with(p_device_key, p_badge_uid, p_pin, null);
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
    -- Badges need the People box; someone with a role only by whoever could give that role (migration 43).
    if not (ss->'staff'->'perms' ? 'people') or not private.emp_can_manage((ss->'staff'->>'id')::uuid, p_target) then
      return jsonb_build_object('ok', false, 'error', 'admin_only');
    end if;
    update public.employees set badge_uid = private.normalize_uid(p_new_uid) where id = p_target;
  elsif p_kind = 'equipment' then
    if not (ss->'staff'->'perms' ? 'status') then return jsonb_build_object('ok', false, 'error', 'admin_only'); end if;
    update public.equipment set nfc_uid = private.normalize_uid(p_new_uid) where id = p_target and org_id = v_org;
    if not found then return jsonb_build_object('ok', false, 'error', 'unknown_equipment'); end if;
  else
    return jsonb_build_object('ok', false, 'error', 'bad_kind');
  end if;
  return jsonb_build_object('ok', true);
end $function$;

CREATE OR REPLACE FUNCTION public.station_staff_login(p_device_key text, p_badge_uid text, p_pin text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare ss jsonb; v_org uuid;
begin
  ss := private.staff_with(p_device_key, p_badge_uid, p_pin, null);
  if not (ss->>'ok')::boolean then return ss; end if;
  v_org := (ss->>'org_id')::uuid;
  return jsonb_build_object(
    'ok', true,
    'staff', ss->'staff',
    -- Roles this person can give at the station (migration 43): built-ins below theirs, and the company's own roles they cover.
    'roles', (select coalesce(jsonb_agg(x order by x->>'sort'), '[]'::jsonb) from (
        select jsonb_build_object('value', r::text, 'label', private.access_label(r, null), 'station', private.station_powers(private.role_perms(r)), 'sort', 'a' || array_position(enum_range(null::public.member_role), r)) x
        from unnest(array['viewer', 'supervisor', 'admin']::public.member_role[]) r
        where private.emp_can_give((ss->'staff'->>'id')::uuid, r, null)
        union all
        select jsonb_build_object('value', 'role:' || c.id, 'label', c.name, 'station', private.station_powers(c.perms), 'sort', 'z' || c.name)
        from public.custom_roles c where c.org_id = v_org and private.emp_can_give((ss->'staff'->>'id')::uuid, 'viewer', c.id)) q),
    'categories', coalesce((select jsonb_agg(jsonb_build_object(
        'id', c.id, 'name', c.name,
        'names', coalesce((select jsonb_agg(q.name order by q.name) from public.equipment q where q.category_id = c.id), '[]'::jsonb))
        order by c.sort_order, c.name)
      from public.equipment_categories c where c.org_id = v_org), '[]'::jsonb),
    'employees', coalesce((select jsonb_agg(jsonb_build_object(
        'id', e.id, 'name', trim(e.first_name || ' ' || e.last_name),
        'first_name', e.first_name, 'last_name', e.last_name, 'employee_number', e.employee_number,
        'role', e.station_role, 'access', private.access_value(e.access_role, e.custom_role_id), 'role_label', private.access_label(e.access_role, e.custom_role_id),
        'can_manage', private.emp_can_manage((ss->'staff'->>'id')::uuid, e.id) and e.id <> (ss->'staff'->>'id')::uuid,
        'active', e.active, 'has_badge', e.badge_uid is not null,
        'has_pin', exists (select 1 from private.staff_pins p where p.employee_id = e.id))
        order by e.active desc, e.first_name, e.last_name)
      from public.employees e where e.org_id = v_org), '[]'::jsonb),
    -- Equipment added on the dashboard without a tag yet, so it can be tagged here.
    'untagged', coalesce((select jsonb_agg(jsonb_build_object('id', q.id, 'name', q.name,
        'category', (select name from public.equipment_categories where id = q.category_id)) order by q.name)
      from public.equipment q where q.org_id = v_org and q.nfc_uid is null and q.status <> 'retired'), '[]'::jsonb));
end $function$;

CREATE OR REPLACE FUNCTION public.station_sync_cache(p_device_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare s public.stations;
begin
  s := private.station_from_key(p_device_key);
  if s.id is null then return private.station_denied(p_device_key); end if;
  return jsonb_build_object(
    'ok', true,
    'generated_at', now(),
    'contract_names', coalesce((select jsonb_object_agg(id, name) from public.contracts where org_id = s.org_id), '{}'::jsonb),
    'reach', case when s.contract_id is null then null else
               coalesce((select jsonb_agg(c.id) from public.contracts c where c.org_id = s.org_id and private.contracts_share(s.org_id, s.contract_id, c.id)), '[]'::jsonb) end,
    'visitors', case when s.contract_id is null then '{}'::jsonb else
               coalesce((select jsonb_object_agg(employee_id, ends_at) from (
                  select p.employee_id, max(p.ends_at) ends_at from public.visitor_passes p
                  where p.org_id = s.org_id and p.ended_at is null and p.ends_at > now() and p.starts_at <= now() + interval '1 day'
                    and private.contracts_share(s.org_id, p.contract_id, s.contract_id) group by p.employee_id) v), '{}'::jsonb) end,
    'employees', coalesce((select jsonb_agg(jsonb_build_object(
                    'id', e.id, 'badge_uid', e.badge_uid, 'barcode', e.barcode,
                    'name', trim(e.first_name || ' ' || e.last_name),
                    'role', e.station_role, 'perms', to_jsonb(private.emp_perms(e.id)), 'contract_id', e.contract_id,
                    'has_pin', exists (select 1 from private.staff_pins p where p.employee_id = e.id)))
                  from public.employees e
                  where e.org_id = s.org_id and e.active and e.badge_uid is not null), '[]'::jsonb),
    'equipment', coalesce((select jsonb_agg(jsonb_build_object(
                    'id', e.id, 'nfc_uid', e.nfc_uid, 'barcode', e.barcode, 'name', e.name,
                    'category_id', e.category_id, 'status', e.status, 'contract_id', e.contract_id,
                    'loan_to', (private.open_loan(e.id)).to_contract_id,
                    'current_employee_id', e.current_employee_id,
                    'checked_out_at', e.checked_out_at, 'due_at', e.due_at,
                    'extended_alert_hours', private.extended_hours(e.id),
                    'problem', private.open_problem(e.id)))
                  from public.equipment e
                  where e.org_id = s.org_id and e.nfc_uid is not null and e.status <> 'retired'), '[]'::jsonb)
  );
end $function$;

CREATE OR REPLACE FUNCTION public.station_claim_admin_tag(p_device_key text, p_tag_uid text, p_first_name text DEFAULT NULL::text, p_last_name text DEFAULT NULL::text, p_pin text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  insert into public.employees (id, org_id, first_name, last_name, badge_uid, access_role)
  values (v_emp, s.org_id, trim(p_first_name), coalesce(trim(p_last_name), ''), private.normalize_uid(p_tag_uid), 'owner');
  perform private.set_pin(v_emp, p_pin);
  update public.stations set admin_claimed_at = now() where id = s.id;
  return jsonb_build_object('ok', true, 'existing', false,
    'employee', jsonb_build_object('id', v_emp, 'name', trim(trim(p_first_name) || ' ' || coalesce(trim(p_last_name), '')), 'role', 'admin'));
end $function$;

CREATE OR REPLACE FUNCTION public.delete_custom_role(p_role uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r public.custom_roles; n int;
begin
  select * into r from public.custom_roles where id = p_role;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if not (private.is_platform_operator()
          or (private.has_org_role(r.org_id, 'owner') and private.role_visible(r.org_id, r.id) and (r.contract_id is not null or private.my_scope(r.org_id) is null))) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  n := (select count(*) from public.org_members where custom_role_id = p_role)
     + (select count(*) from public.org_invites where custom_role_id = p_role and accepted_at is null)
     + (select count(*) from public.employees where custom_role_id = p_role and user_id is null);
  if n > 0 then return jsonb_build_object('ok', false, 'error', 'in_use', 'count', n); end if;
  delete from public.custom_roles where id = p_role;
  return jsonb_build_object('ok', true);
end $function$;

CREATE OR REPLACE FUNCTION public.accept_invite(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare inv public.org_invites; v_email text;
begin
  if auth.uid() is null then return jsonb_build_object('ok', false, 'error', 'not_signed_in'); end if;
  select * into inv from public.org_invites where token_hash = private.sha256_hex(p_token) for update;
  if not found or inv.accepted_at is not null then return jsonb_build_object('ok', false, 'error', 'invalid_invite'); end if;
  if inv.expires_at < now() then return jsonb_build_object('ok', false, 'error', 'invite_expired'); end if;
  select lower(email) into v_email from auth.users where id = auth.uid();
  if v_email is distinct from inv.email then return jsonb_build_object('ok', false, 'error', 'wrong_account', 'invited_email', inv.email); end if;
  -- An invite for contracts that are gone mustn't turn into a whole-company invite.
  if coalesce(cardinality(inv.contracts), 0) > 0
     and not exists (select 1 from public.contracts c where c.id = any (inv.contracts) and c.org_id = inv.org_id) then
    return jsonb_build_object('ok', false, 'error', 'invite_outdated');
  end if;
  -- Someone already on the team keeps what they had; this adds the invite's contracts (unless they see everything).
  insert into public.org_members (org_id, user_id, role, custom_role_id)
  values (inv.org_id, auth.uid(), inv.role, (select id from public.custom_roles where id = inv.custom_role_id))
  on conflict (org_id, user_id) do update set role = greatest(public.org_members.role, excluded.role);
  insert into public.member_contracts (org_id, user_id, contract_id)
  select inv.org_id, auth.uid(), c from unnest(coalesce(inv.contracts, '{}')) c
  where exists (select 1 from public.contracts where id = c and org_id = inv.org_id)
  on conflict do nothing;
  -- Invited from someone's employee page: their employee record is now this dashboard account.
  perform set_config('app.access_ok', '1', true);
  update public.employees e set user_id = auth.uid(), access_role = m.role, custom_role_id = m.custom_role_id
    from public.org_members m
   where e.id = inv.employee_id and e.org_id = inv.org_id and e.user_id is null and m.org_id = inv.org_id and m.user_id = auth.uid()
     and not exists (select 1 from public.employees where org_id = inv.org_id and user_id = auth.uid());
  perform set_config('app.access_ok', '', true);
  update public.org_invites set accepted_at = now(), accepted_by = auth.uid() where id = inv.id;
  return jsonb_build_object('ok', true, 'org_id', inv.org_id, 'role', inv.role);
end $function$;

-- Adding someone at the station: p_access picks their role ("" = Agent); p_role is the older fob choice.
drop function if exists public.station_add_employee(text, text, text, text, text, text, text, public.station_role, text, text);
create or replace function public.station_add_employee(p_device_key text, p_badge_uid text, p_pin text, p_first_name text, p_last_name text,
  p_employee_number text, p_new_badge_uid text, p_role public.station_role default 'employee', p_new_pin text default null,
  p_new_barcode text default null, p_access text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare ss jsonb; v_org uuid; v_owner jsonb; v_emp uuid; v_num text := nullif(trim(p_employee_number), '');
        v_uid text := private.normalize_uid(p_new_badge_uid); v_code text := nullif(upper(trim(p_new_barcode)), '');
        a record; v_powers boolean;
begin
  ss := private.staff_with(p_device_key, p_badge_uid, p_pin, 'people');
  if not (ss->>'ok')::boolean then return ss; end if;
  v_org := (ss->>'org_id')::uuid;
  if p_access is not null then a := private.parse_access(p_access);
  else select case p_role when 'manager' then 'admin' when 'admin' then 'owner' end::public.member_role o_role, null::uuid o_custom into a; end if;

  if coalesce(trim(p_first_name), '') = '' then return jsonb_build_object('ok', false, 'error', 'name_required'); end if;
  if not private.emp_can_give((ss->'staff'->>'id')::uuid, a.o_role, a.o_custom) then return jsonb_build_object('ok', false, 'error', 'admin_only'); end if;
  v_powers := a.o_role is not null and private.station_powers(case when a.o_custom is not null then (select perms from public.custom_roles where id = a.o_custom) else private.role_perms(a.o_role) end);
  if v_powers and not private.valid_pin(p_new_pin) then return jsonb_build_object('ok', false, 'error', 'pin_needed'); end if;
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

  insert into public.employees (org_id, first_name, last_name, employee_number, badge_uid, barcode, access_role, custom_role_id)
  values (v_org, trim(p_first_name), coalesce(trim(p_last_name), ''), v_num, v_uid, v_code, a.o_role, a.o_custom)
  returning id into v_emp;
  if v_powers then perform private.set_pin(v_emp, p_new_pin); end if;
  return jsonb_build_object('ok', true, 'employee', (select jsonb_build_object('id', id, 'name', trim(first_name || ' ' || last_name), 'role', station_role,
    'access', private.access_value(access_role, custom_role_id), 'role_label', private.access_label(access_role, custom_role_id)) from public.employees where id = v_emp));
end $$;

-- Changing someone at the station. Role: whoever could give both their old and new role. Deactivate: the "remove people" box.
-- PIN: your own, or someone whose role you could give. A linked dashboard account gets the same role.
drop function if exists public.station_update_employee(text, text, text, uuid, public.station_role, boolean, text);
create or replace function public.station_update_employee(p_device_key text, p_badge_uid text, p_pin text, p_employee uuid,
  p_role public.station_role default null, p_active boolean default null, p_new_pin text default null, p_access text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare ss jsonb; e public.employees; me uuid; a record; v_change boolean; v_powers boolean; p text[];
begin
  ss := private.staff_with(p_device_key, p_badge_uid, p_pin, null);
  if not (ss->>'ok')::boolean then return ss; end if;
  me := (ss->'staff'->>'id')::uuid;
  select * into e from public.employees where id = p_employee and org_id = (ss->>'org_id')::uuid for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'unknown_employee'); end if;
  if p_access is not null then a := private.parse_access(p_access);
  elsif p_role is not null then select case p_role when 'manager' then 'admin' when 'admin' then 'owner' end::public.member_role o_role, null::uuid o_custom into a;
  else select e.access_role o_role, e.custom_role_id o_custom into a; end if;
  v_change := a.o_role is distinct from e.access_role or a.o_custom is distinct from e.custom_role_id;
  -- Don't let anyone lock themselves out by accident.
  if e.id = me and (p_active is false or v_change) then return jsonb_build_object('ok', false, 'error', 'cant_change_self'); end if;
  if v_change and not (private.emp_can_manage(me, e.id) and private.emp_can_give(me, a.o_role, a.o_custom)) then
    return jsonb_build_object('ok', false, 'error', 'admin_only');
  end if;
  if p_active is not null and p_active is distinct from e.active
     and not (ss->'staff'->'perms' ? 'remove_people' and private.emp_can_manage(me, e.id)) then
    return jsonb_build_object('ok', false, 'error', 'admin_only');
  end if;
  if p_new_pin is not null and e.id <> me and not (ss->'staff'->'perms' ? 'people' and private.emp_can_manage(me, e.id)) then
    return jsonb_build_object('ok', false, 'error', 'admin_only');
  end if;
  if p_new_pin is not null and not private.valid_pin(p_new_pin) then return jsonb_build_object('ok', false, 'error', 'pin_needed'); end if;
  p := case when a.o_role is null then '{}'::text[] when a.o_custom is not null then (select perms from public.custom_roles where id = a.o_custom) else private.role_perms(a.o_role) end;
  v_powers := private.station_powers(p);
  if v_powers and p_new_pin is null and not exists (select 1 from private.staff_pins where employee_id = e.id) then
    return jsonb_build_object('ok', false, 'error', 'pin_needed');
  end if;

  update public.employees set access_role = a.o_role, custom_role_id = a.o_custom, active = coalesce(p_active, active) where id = e.id;
  if v_change and e.user_id is not null then
    if a.o_role is null then delete from public.org_members where org_id = e.org_id and user_id = e.user_id and role < 'owner';
    else update public.org_members set role = a.o_role, custom_role_id = a.o_custom where org_id = e.org_id and user_id = e.user_id; end if;
  end if;
  if p_new_pin is not null then perform private.set_pin(e.id, p_new_pin); end if;
  if not v_powers then delete from private.staff_pins where employee_id = e.id; end if;
  return jsonb_build_object('ok', true, 'employee', (select jsonb_build_object('id', id, 'role', station_role, 'active', active,
    'access', private.access_value(access_role, custom_role_id), 'role_label', private.access_label(access_role, custom_role_id)) from public.employees where id = e.id));
end $$;

-- An employee's role from the dashboard. Email is optional: with one, they also get a dashboard account with the same role.
drop function if exists public.set_employee_access(uuid, public.member_role, uuid, text);
create or replace function public.set_employee_access(p_employee uuid, p_role public.member_role default null, p_custom_role uuid default null,
  p_email text default null, p_pin text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare e public.employees; r jsonb := jsonb_build_object('ok', true); v_user uuid; i record; v_email text := lower(btrim(coalesce(p_email, '')));
        v_change boolean; v_powers boolean; v_linked boolean;
begin
  select * into e from public.employees where id = p_employee for update;
  if not found or not (private.is_platform_operator() or (private.has_perm(e.org_id, 'people') and private.can_see(e.org_id, e.contract_id))) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if p_custom_role is not null then
    if not exists (select 1 from public.custom_roles where id = p_custom_role and org_id = e.org_id) then return jsonb_build_object('ok', false, 'error', 'unknown_role'); end if;
    p_role := 'viewer';
  end if;
  v_change := p_role is distinct from e.access_role or p_custom_role is distinct from e.custom_role_id;
  -- You can touch someone's role only if you could give it; and only give roles you could give (Admins: Sonoran Point).
  if e.access_role is not null and (v_change or p_pin is not null or v_email <> '')
     and not (case when e.custom_role_id is null then private.can_manage_role(e.org_id, e.access_role) else private.can_give_custom(e.org_id, e.custom_role_id) end) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if v_change and p_role is not null
     and not (case when p_custom_role is null then private.can_manage_role(e.org_id, p_role) else private.can_give_custom(e.org_id, p_custom_role) end) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if p_pin is not null and not private.valid_pin(p_pin) then return jsonb_build_object('ok', false, 'error', 'pin_needed'); end if;
  v_powers := p_role is not null and private.station_powers(case when p_custom_role is not null then (select perms from public.custom_roles where id = p_custom_role) else private.role_perms(p_role) end);
  if v_powers and p_pin is null and (e.badge_uid is not null or e.barcode is not null)
     and not exists (select 1 from private.staff_pins where employee_id = e.id) then
    return jsonb_build_object('ok', false, 'error', 'pin_needed');
  end if;
  v_linked := e.user_id is not null and exists (select 1 from public.org_members where org_id = e.org_id and user_id = e.user_id);
  if p_role is not null and not v_linked and v_email <> '' and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    return jsonb_build_object('ok', false, 'error', 'bad_email');
  end if;

  perform set_config('app.access_ok', '1', true);
  if p_role is null then   -- Agent: badge only
    for i in select id from public.org_invites where employee_id = e.id and accepted_at is null loop perform public.cancel_invite(i.id); end loop;
    if v_linked then
      r := public.remove_member(e.org_id, e.user_id);
      if not (r->>'ok')::boolean then perform set_config('app.access_ok', '', true); return r; end if;
    end if;
    update public.employees set user_id = null, access_role = null, custom_role_id = null where id = e.id;
    delete from private.staff_pins where employee_id = e.id;
    perform set_config('app.access_ok', '', true);
    return jsonb_build_object('ok', true);
  end if;

  update public.employees set access_role = p_role, custom_role_id = p_custom_role where id = e.id;
  if p_pin is not null and v_powers then perform private.set_pin(e.id, p_pin); end if;
  if not v_powers then delete from private.staff_pins where employee_id = e.id; end if;

  if v_linked then
    if v_change then r := public.set_member_role(e.org_id, e.user_id, p_role, p_custom_role); end if;
  elsif v_email <> '' then
    select m.user_id into v_user from public.org_members m join auth.users u on u.id = m.user_id where m.org_id = e.org_id and lower(u.email) = v_email;
    if v_user is not null then   -- already on the dashboard: link them
      if exists (select 1 from public.employees where org_id = e.org_id and user_id = v_user and id <> e.id) then
        perform set_config('app.access_ok', '', true);
        raise exception 'email_linked' using errcode = 'P0001';
      end if;
      r := public.set_member_role(e.org_id, v_user, p_role, p_custom_role);
      if (r->>'ok')::boolean then update public.employees set user_id = v_user where id = e.id; end if;
      r := r || jsonb_build_object('linked', true);
    else
      for i in select id from public.org_invites where employee_id = e.id and accepted_at is null loop perform public.cancel_invite(i.id); end loop;
      r := public.invite_member(e.org_id, v_email, p_role, case when e.contract_id is null then null else array[e.contract_id] end, p_custom_role);
      if (r->>'ok')::boolean then update public.org_invites set employee_id = e.id where id = (r->>'invite_id')::uuid; end if;
    end if;
  end if;
  perform set_config('app.access_ok', '', true);
  if not (r->>'ok')::boolean then raise exception '%', r->>'error' using errcode = 'P0001'; end if;   -- undo the role change too
  return r;
end $$;
revoke execute on function public.set_employee_access(uuid, public.member_role, uuid, text, text) from public, anon;
grant  execute on function public.set_employee_access(uuid, public.member_role, uuid, text, text) to authenticated;

-- Older dashboards: a fob choice is a role (manager fob = Manager, admin fob = Admin).
create or replace function public.set_employee_station_role(p_employee uuid, p_role public.station_role, p_pin text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  return public.set_employee_access(p_employee, case p_role when 'manager' then 'admin' when 'admin' then 'owner' end::public.member_role, null, null, p_pin);
end $$;

-- Departments: each belongs to a contract (or the whole company). Managers and Admins with the Team box keep the list.
create table if not exists public.departments (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  contract_id uuid,
  name text not null check (length(btrim(name)) between 1 and 40),
  sort_order int not null default 0,
  created_at timestamptz not null default now(),
  unique (id, org_id),
  foreign key (contract_id, org_id) references public.contracts(id, org_id) on delete cascade
);
create unique index if not exists departments_name on public.departments (org_id, coalesce(contract_id, '00000000-0000-0000-0000-000000000000'::uuid), lower(btrim(name)));
alter table public.departments enable row level security;
drop policy if exists dept_select on public.departments;
create policy dept_select on public.departments for select to authenticated
  using (private.has_org_role(org_id) and (contract_id is null or private.can_see(org_id, contract_id)));
drop policy if exists dept_write on public.departments;
create policy dept_write on public.departments for all to authenticated
  using (private.has_perm(org_id, 'team') and (case when contract_id is null then private.unscoped(org_id) else private.can_see(org_id, contract_id) end))
  with check (private.has_perm(org_id, 'team') and (case when contract_id is null then private.unscoped(org_id) else private.can_see(org_id, contract_id) end));

-- Positions: a title, and the department it's for. Someone can have several. Labels only for now.
create table if not exists public.employee_positions (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  employee_id uuid not null,
  title text not null check (length(btrim(title)) between 1 and 40),
  department_id uuid,
  sort_order int not null default 0,
  created_at timestamptz not null default now(),
  foreign key (employee_id, org_id) references public.employees(id, org_id) on delete cascade,
  foreign key (department_id, org_id) references public.departments(id, org_id) on delete set null (department_id)
);
create index if not exists employee_positions_emp on public.employee_positions (employee_id);
alter table public.employee_positions enable row level security;
drop policy if exists pos_select on public.employee_positions;
create policy pos_select on public.employee_positions for select to authenticated
  using (exists (select 1 from public.employees e where e.id = employee_id and (private.can_see(e.org_id, e.contract_id) or private.visited_me(e.id))));
drop policy if exists pos_write on public.employee_positions;
create policy pos_write on public.employee_positions for all to authenticated
  using (private.has_perm(org_id, 'people') and exists (select 1 from public.employees e where e.id = employee_id and e.org_id = employee_positions.org_id and private.can_see(e.org_id, e.contract_id)))
  with check (private.has_perm(org_id, 'people') and exists (select 1 from public.employees e where e.id = employee_id and e.org_id = employee_positions.org_id and private.can_see(e.org_id, e.contract_id)));

grant select, insert, update, delete on public.departments, public.employee_positions to authenticated;
revoke all on public.departments, public.employee_positions from anon;

revoke execute on function private.emp_perms(uuid), private.emp_can_give(uuid, public.member_role, uuid), private.emp_can_manage(uuid, uuid),
  private.staff_with(text, text, text, text), private.access_label(public.member_role, uuid) from public, anon, authenticated;
