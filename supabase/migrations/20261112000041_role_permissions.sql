-- Migration 41: permissions split the way Dez's crews work, and the built-in roles set to match.
--
--   Supervisor: add and edit employees and badges (not deactivate), mark items lost or in maintenance, report and clear
--               problems, lend items, sign off shift reports, let visitors in.
--   Manager:    Supervisor + deactivate employees, add/edit/remove equipment, mark alerts seen, shifts, team (only View Only
--               and Supervisor, never other Managers or Admins).
--   Admin:      everything, including stations and station fobs.
--
-- New boxes: remove_people (deactivate and reactivate employees) and reports (sign off shift reports, split from alerts).
-- Custom roles keep what they could do: one with "people" also gets "remove_people", one with "alerts" also gets "reports".

alter table public.custom_roles drop constraint if exists custom_roles_perms_check;
update public.custom_roles set perms = perms || array['remove_people'] where 'people' = any (perms) and not 'remove_people' = any (perms);
update public.custom_roles set perms = perms || array['reports'] where 'alerts' = any (perms) and not 'reports' = any (perms);
alter table public.custom_roles add constraint custom_roles_perms_check
  check (perms <@ array['people', 'remove_people', 'status', 'reports', 'alerts', 'visitors', 'equipment', 'stations', 'fobs', 'shifts', 'team']);

create or replace function private.all_perms() returns text[] language sql immutable as $$
  select array['people', 'remove_people', 'status', 'reports', 'alerts', 'visitors', 'equipment', 'stations', 'fobs', 'shifts', 'team']
$$;
create or replace function private.role_perms(p_role public.member_role) returns text[] language sql immutable as $$
  select case p_role
    when 'viewer' then '{}'::text[]
    when 'supervisor' then array['people', 'status', 'reports', 'visitors']
    when 'admin' then array['people', 'remove_people', 'status', 'reports', 'alerts', 'visitors', 'equipment', 'shifts', 'team']
    else private.all_perms() end
$$;

-- Team, limited: anyone below Admin with the Team box can give only roles whose boxes they have themselves and never
-- Manager or Admin. (Built-in Managers used to be able to make other Managers.) Admins give anything in their area.
create or replace function private.can_manage_role(p_org uuid, p_role public.member_role)
returns boolean language sql stable security definer set search_path = public as $$
  select private.is_platform_operator() or private.has_org_role(p_org, 'owner')
      or (private.has_perm(p_org, 'team') and p_role < 'admin' and private.role_perms(p_role) <@ private.perms_of(p_org, auth.uid()))
$$;

-- Deactivating or reactivating an employee needs its own box (the dashboard does it with a plain update).
create or replace function private.guard_employee_active()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  -- Station admin menus (a manager fob, app.station_id set by staff_session) have their own rules.
  -- Only dashboard requests (role authenticated); not the SQL editor, not a company being deleted.
  if current_setting('role', true) = 'authenticated' and auth.uid() is not null and coalesce(current_setting('app.station_id', true), '') = ''
     and not private.is_platform_operator() and not private.has_perm(coalesce(new.org_id, old.org_id), 'remove_people')
     and (tg_op = 'DELETE' or new.active is distinct from old.active) then
    raise exception 'not allowed' using errcode = '42501', hint = 'remove_people';
  end if;
  return coalesce(new, old);
end $$;
drop trigger if exists guard_employee_active on public.employees;
create trigger guard_employee_active before update of active or delete on public.employees
  for each row execute function private.guard_employee_active();

-- Signing off shift reports is its own box now (alerts = marking alerts seen).
CREATE OR REPLACE FUNCTION public.acknowledge_shift_report(p_report uuid, p_notes text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_org uuid;
begin
  select org_id into v_org from public.shift_reports where id = p_report;
  if v_org is null or not private.has_perm(v_org, 'reports')
     or not private.can_see(v_org, (select s.contract_id from public.shift_reports r join public.shifts s on s.id = r.shift_id where r.id = p_report)) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  update public.shift_reports
     set acknowledged_by = auth.uid(), acknowledged_at = now(), acknowledgement_notes = p_notes
   where id = p_report;
end $function$;

revoke execute on function private.guard_employee_active() from public, anon, authenticated;
grant  execute on function private.all_perms(), private.role_perms(public.member_role) to authenticated;
