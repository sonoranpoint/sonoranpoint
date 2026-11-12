-- Migration 40: custom roles. An Admin picks what a role can do from nine permissions, names it and saves it.
-- Admin stays special (everything in its area, including other Admins). Today's View Only, Supervisor and Manager stay as
-- built-in roles with fixed permissions; a custom role is stored as View Only plus its own permissions.
--
--   people     add and edit employees, badges and who's on which shift
--   status     mark items lost or in maintenance, report and clear problems, lend items
--   alerts     mark alerts seen, sign off shift reports
--   visitors   let people from other contracts use your stations
--   equipment  add and edit equipment, categories (adding), time limits, import, labels, retire
--   stations   add, rename and remove stations, setup codes
--   fobs       give manager or admin fobs and set PINs
--   shifts     create shifts and change their times
--   team       invite and manage dashboard users (and their email alerts)
--
-- Company-wide settings (name, logo, problem reasons, renaming categories) stay with Admins and built-in Managers who see the
-- whole company, as before. Roles are made by a whole-company Admin (for everyone) or a contract Admin (for their contracts).
-- Nobody can give out a permission they don't have.

create table if not exists public.custom_roles (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organizations(id) on delete cascade,
  contract_id uuid,                    -- null = the whole company's; else made by (and for) that contract's Admins
  name        text not null check (length(trim(name)) between 1 and 40),
  perms       text[] not null default '{}',
  created_by  uuid references auth.users(id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (id, org_id),
  foreign key (contract_id, org_id) references public.contracts(id, org_id) on delete cascade,
  check (perms <@ array['people', 'status', 'alerts', 'visitors', 'equipment', 'stations', 'fobs', 'shifts', 'team'])
);
create unique index if not exists custom_roles_name on public.custom_roles (org_id, lower(trim(name)));
alter table public.custom_roles enable row level security;   -- read and written through the functions below
revoke all on public.custom_roles from anon, authenticated;
create trigger audit_custom_roles after insert or update or delete on public.custom_roles for each row execute function private.audit();

alter table public.org_members add column if not exists custom_role_id uuid references public.custom_roles(id) on delete restrict;
alter table public.org_invites add column if not exists custom_role_id uuid references public.custom_roles(id) on delete cascade;

-- ---------------------------------------------------------------------
-- Permissions
-- ---------------------------------------------------------------------
create or replace function private.all_perms() returns text[] language sql immutable as $$
  select array['people', 'status', 'alerts', 'visitors', 'equipment', 'stations', 'fobs', 'shifts', 'team']
$$;
-- What a built-in role can do.
create or replace function private.role_perms(p_role public.member_role) returns text[] language sql immutable as $$
  select case p_role when 'viewer' then '{}'::text[] when 'supervisor' then array['people', 'status', 'alerts', 'visitors']
              else private.all_perms() end
$$;
create or replace function private.perms_of(p_org uuid, p_user uuid)
returns text[] language sql stable security definer set search_path = public as $$
  select coalesce((select case when m.role = 'owner' then private.all_perms()
                               when m.custom_role_id is not null then r.perms
                               else private.role_perms(m.role) end
                   from public.org_members m left join public.custom_roles r on r.id = m.custom_role_id
                   where m.org_id = p_org and m.user_id = p_user), '{}')
$$;
create or replace function private.has_perm(p_org uuid, p_perm text)
returns boolean language sql stable security definer set search_path = public as $$
  select p_perm = any (private.perms_of(p_org, auth.uid()))
$$;
-- Can the signed-in person see (and so use) this role? Company roles: everyone. A contract's roles: people in that contract.
create or replace function private.role_visible(p_org uuid, p_role uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.custom_roles r where r.id = p_role and r.org_id = p_org
                 and (r.contract_id is null or private.my_scope(p_org) is null or r.contract_id = any (private.my_scope(p_org))))
$$;
-- Can the signed-in person give someone this custom role? Admins (and us) in their area; anyone with "team" whose own
-- permissions cover the role's.
create or replace function private.can_give_custom(p_org uuid, p_role uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select private.is_platform_operator()
      or (private.role_visible(p_org, p_role)
          and (private.has_org_role(p_org, 'owner')
               or (private.has_perm(p_org, 'team') and (select r.perms <@ private.perms_of(p_org, auth.uid()) from public.custom_roles r where r.id = p_role))))
$$;
-- Built-in roles: Admins give anything, built-in Managers anything but Admin (as before); a custom role with "team" can give
-- View Only, and Supervisor if it has everything a Supervisor has.
create or replace function private.can_manage_role(p_org uuid, p_role public.member_role)
returns boolean language sql stable security definer set search_path = public as $$
  select private.is_platform_operator() or private.has_org_role(p_org, 'owner')
      or (private.has_org_role(p_org, 'admin') and p_role < 'owner'
          and not exists (select 1 from public.org_members where org_id = p_org and user_id = auth.uid() and custom_role_id is not null))
      or (private.has_perm(p_org, 'team') and p_role < 'admin' and private.role_perms(p_role) <@ private.perms_of(p_org, auth.uid()))
$$;
-- Can the signed-in person change or remove this member? Their role must be one you could give, and they must be in your branch.
create or replace function private.can_manage_member(p_org uuid, p_user uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select private.can_manage_role(p_org, m.role)
                          and (m.custom_role_id is null or private.can_give_custom(p_org, m.custom_role_id))
                          and private.in_my_branch(p_org, p_user)
                   from public.org_members m where m.org_id = p_org and m.user_id = p_user), false)
$$;

-- ---------------------------------------------------------------------
-- Making roles (Admins, for their own area)
-- ---------------------------------------------------------------------
create or replace function public.list_custom_roles(p_org uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not (private.has_org_role(p_org) or private.is_platform_operator()) then raise exception 'not allowed' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'name', r.name, 'perms', to_jsonb(r.perms), 'contract_id', r.contract_id,
      'contract', (select name from public.contracts where id = r.contract_id),
      'members', (select count(*) from public.org_members m where m.custom_role_id = r.id),
      'can_give', private.can_give_custom(p_org, r.id),
      'can_edit', private.is_platform_operator() or (private.has_org_role(p_org, 'owner') and private.role_visible(p_org, r.id)
                  and (r.contract_id is not null or private.my_scope(p_org) is null))) order by r.name)
    from public.custom_roles r where r.org_id = p_org and (private.is_platform_operator() or private.role_visible(p_org, r.id))), '[]'::jsonb);
end $$;

create or replace function public.save_custom_role(p_org uuid, p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_name text := btrim(coalesce(p->>'name', ''));
        v_perms text[] := coalesce(array(select distinct jsonb_array_elements_text(p->'perms')), '{}');
        v_contract uuid := nullif(p->>'contract_id', '')::uuid; sc uuid[]; r public.custom_roles;
begin
  if not (private.has_org_role(p_org, 'owner') or private.is_platform_operator()) then raise exception 'not allowed' using errcode = '42501'; end if;
  sc := private.my_scope(p_org);
  if v_name = '' or length(v_name) > 40 then return jsonb_build_object('ok', false, 'error', 'bad_name'); end if;
  if not v_perms <@ private.all_perms() then return jsonb_build_object('ok', false, 'error', 'unknown_perm'); end if;
  if lower(v_name) in ('admin', 'manager', 'supervisor', 'view only') then return jsonb_build_object('ok', false, 'error', 'built_in_name'); end if;
  -- A contract Admin's roles belong to one of their contracts.
  if sc is not null then
    if v_contract is null then v_contract := (select contract_id from public.member_contracts where org_id = p_org and user_id = auth.uid() limit 1); end if;
    if not (v_contract = any (sc)) then return jsonb_build_object('ok', false, 'error', 'outside_scope'); end if;
  elsif v_contract is not null and not exists (select 1 from public.contracts where id = v_contract and org_id = p_org) then
    return jsonb_build_object('ok', false, 'error', 'unknown_contract');
  end if;
  if exists (select 1 from public.custom_roles where org_id = p_org and lower(btrim(name)) = lower(v_name) and id is distinct from v_id) then
    return jsonb_build_object('ok', false, 'error', 'duplicate_name');
  end if;
  if v_id is null then
    insert into public.custom_roles (org_id, contract_id, name, perms, created_by) values (p_org, v_contract, v_name, v_perms, auth.uid()) returning * into r;
  else
    select * into r from public.custom_roles where id = v_id and org_id = p_org for update;
    if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
    if not private.is_platform_operator() and (not private.role_visible(p_org, v_id) or (r.contract_id is null and sc is not null)) then
      raise exception 'not allowed' using errcode = '42501';
    end if;
    update public.custom_roles set name = v_name, perms = v_perms, contract_id = v_contract, updated_at = now() where id = v_id returning * into r;
  end if;
  if private.is_platform_operator() then perform private.plog(p_org, 'saved role', jsonb_build_object('name', v_name, 'text', array_to_string(v_perms, ', '))); end if;
  return jsonb_build_object('ok', true, 'id', r.id);
end $$;

create or replace function public.delete_custom_role(p_role uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r public.custom_roles; n int;
begin
  select * into r from public.custom_roles where id = p_role;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if not (private.is_platform_operator()
          or (private.has_org_role(r.org_id, 'owner') and private.role_visible(r.org_id, r.id) and (r.contract_id is not null or private.my_scope(r.org_id) is null))) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  n := (select count(*) from public.org_members where custom_role_id = p_role)
     + (select count(*) from public.org_invites where custom_role_id = p_role and accepted_at is null);
  if n > 0 then return jsonb_build_object('ok', false, 'error', 'in_use', 'count', n); end if;
  delete from public.custom_roles where id = p_role;
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------
-- Tables: write rules follow permissions
-- ---------------------------------------------------------------------
drop policy if exists emp_write on public.employees;
create policy emp_write on public.employees for all to authenticated
  using (private.has_perm(org_id, 'people') and private.can_see(org_id, contract_id))
  with check (private.has_perm(org_id, 'people') and private.can_see(org_id, contract_id));
drop policy if exists assign_write on public.shift_assignments;
create policy assign_write on public.shift_assignments for all to authenticated
  using (private.has_perm(org_id, 'people') and private.can_see(org_id, (select s.contract_id from public.shifts s where s.id = shift_assignments.shift_id)))
  with check (private.has_perm(org_id, 'people') and private.can_see(org_id, (select s.contract_id from public.shifts s where s.id = shift_assignments.shift_id)));
drop policy if exists eq_write on public.equipment;
create policy eq_write on public.equipment for all to authenticated
  using (private.has_perm(org_id, 'equipment') and private.can_see(org_id, contract_id))
  with check (private.has_perm(org_id, 'equipment') and private.can_see(org_id, contract_id));
drop policy if exists cat_insert on public.equipment_categories;
create policy cat_insert on public.equipment_categories for insert to authenticated with check (private.has_perm(org_id, 'equipment'));
drop policy if exists loc_insert on public.locations;
create policy loc_insert on public.locations for insert to authenticated with check (private.has_perm(org_id, 'stations'));
drop policy if exists st_update on public.stations;
create policy st_update on public.stations for update to authenticated
  using (private.has_perm(org_id, 'stations') and private.can_see(org_id, contract_id))
  with check (private.has_perm(org_id, 'stations') and private.can_see(org_id, contract_id));
drop policy if exists st_delete on public.stations;
create policy st_delete on public.stations for delete to authenticated using (private.has_perm(org_id, 'stations') and private.can_see(org_id, contract_id));
drop policy if exists shifts_write on public.shifts;
create policy shifts_write on public.shifts for all to authenticated
  using (private.has_perm(org_id, 'shifts') and private.can_see(org_id, contract_id))
  with check (private.has_perm(org_id, 'shifts') and private.can_see(org_id, contract_id));
drop policy if exists invites_select on public.org_invites;
create policy invites_select on public.org_invites for select to authenticated using (private.has_perm(org_id, 'team'));
drop policy if exists member_contracts_select on public.member_contracts;
create policy member_contracts_select on public.member_contracts for select to authenticated
  using (user_id = auth.uid() or private.has_perm(org_id, 'team'));
drop policy if exists notification_prefs_select on public.notification_prefs;
create policy notification_prefs_select on public.notification_prefs for select to authenticated
  using (user_id = auth.uid() or private.has_perm(org_id, 'team'));
-- org_members rows: custom_role_id can only change through set_member_role (members_write needs a whole-company Admin).

-- ---------------------------------------------------------------------
-- Functions: each check now asks for its permission (same as before for the built-in roles)
-- ---------------------------------------------------------------------
drop function if exists public.set_member_role(uuid, uuid, public.member_role);
drop function if exists public.invite_member(uuid, text, public.member_role, uuid[]);

CREATE OR REPLACE FUNCTION public.acknowledge_alert(p_alert uuid, p_notes text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_org uuid;
begin
  select org_id into v_org from public.equipment_alerts where id = p_alert;
  if v_org is null or not private.has_perm(v_org, 'alerts')
     or not private.can_see_equipment((select equipment_id from public.equipment_alerts where id = p_alert)) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  update public.equipment_alerts
     set acknowledged_by = auth.uid(), acknowledged_at = now(), notes = p_notes
   where id = p_alert;
end $function$;

CREATE OR REPLACE FUNCTION public.acknowledge_shift_report(p_report uuid, p_notes text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_org uuid;
begin
  select org_id into v_org from public.shift_reports where id = p_report;
  if v_org is null or not private.has_perm(v_org, 'alerts')
     or not private.can_see(v_org, (select s.contract_id from public.shift_reports r join public.shifts s on s.id = r.shift_id where r.id = p_report)) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  update public.shift_reports
     set acknowledged_by = auth.uid(), acknowledged_at = now(), acknowledgement_notes = p_notes
   where id = p_report;
end $function$;

CREATE OR REPLACE FUNCTION public.clear_problem(p_problem uuid, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare p public.equipment_problems;
begin
  select * into p from public.equipment_problems where id = p_problem;
  if not found or not private.has_perm(p.org_id, 'status') or not private.can_see_equipment(p.equipment_id) then raise exception 'not allowed' using errcode = '42501'; end if;
  if p.cleared_at is not null then return jsonb_build_object('ok', true, 'already_cleared', true); end if;
  update public.equipment_problems set cleared_at = now(), cleared_by_user = auth.uid(),
         clear_notes = nullif(left(trim(p_notes), 500), '') where id = p.id;
  return jsonb_build_object('ok', true);
end $function$;

CREATE OR REPLACE FUNCTION public.report_problem(p_equipment uuid, p_reason uuid, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_org uuid;
begin
  select org_id into v_org from public.equipment where id = p_equipment;
  if v_org is null or not private.has_perm(v_org, 'status') or not private.can_see_equipment(p_equipment) then raise exception 'not allowed' using errcode = '42501'; end if;
  return private.add_problem(v_org, p_equipment, p_reason, p_notes, null, auth.uid(), null, null, now());
end $function$;

CREATE OR REPLACE FUNCTION public.dashboard_record_event(p_equipment uuid, p_employee uuid, p_action txn_action, p_occurred_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_org uuid;
begin
  select org_id into v_org from public.equipment where id = p_equipment;
  if v_org is null or not private.has_perm(v_org, 'status') or not private.can_see_equipment(p_equipment)
     or not private.can_see(v_org, (select contract_id from public.employees where id = p_employee)) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if not exists (select 1 from public.employees where id = p_employee and org_id = v_org) then
    return jsonb_build_object('ok', false, 'error', 'unknown_employee');
  end if;
  return private.record_event(v_org, p_equipment, p_employee, p_action,
                              coalesce(p_occurred_at, now()), 'dashboard',
                              null, null, auth.uid(), p_notes);
end $function$;

CREATE OR REPLACE FUNCTION public.lend_equipment(p_equipment uuid, p_to_contract uuid, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_org uuid;
begin
  select org_id into v_org from public.equipment where id = p_equipment;
  if v_org is null or not private.has_perm(v_org, 'status') or not private.can_see_equipment(p_equipment) then raise exception 'not allowed' using errcode = '42501'; end if;
  return private.lend(v_org, p_equipment, p_to_contract, p_notes, auth.uid(), null, null);
end $function$;

CREATE OR REPLACE FUNCTION public.end_equipment_loan(p_equipment uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_org uuid;
begin
  select org_id into v_org from public.equipment where id = p_equipment;
  if v_org is null or not private.has_perm(v_org, 'status')
     or not (private.can_see_equipment(p_equipment) or private.can_see(v_org, (private.open_loan(p_equipment)).to_contract_id)) then raise exception 'not allowed' using errcode = '42501'; end if;
  return jsonb_build_object('ok', true, 'ended', private.end_loan(p_equipment, 'ended', auth.uid(), null));
end $function$;

CREATE OR REPLACE FUNCTION public.set_equipment_status(p_equipment uuid, p_status equipment_status, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare eq public.equipment;
begin
  select * into eq from public.equipment where id = p_equipment for update;
  if not found or not private.has_perm(eq.org_id, 'status') or not private.can_see(eq.org_id, eq.contract_id) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if p_status = 'retired' and not private.has_perm(eq.org_id, 'equipment') then
    raise exception 'only admins can retire equipment' using errcode = '42501';
  end if;
  update public.equipment set
    status = case
      when p_status in ('available', 'checked_out')       -- "back in service": status follows custody
        then case when current_employee_id is not null then 'checked_out' else 'available' end::public.equipment_status
      else p_status end,
    notes = coalesce(p_notes, notes)
  where id = p_equipment;
  if p_status = 'lost' then
    update public.equipment_alerts set resolved_at = now() where equipment_id = p_equipment and resolved_at is null;
  end if;
  return jsonb_build_object('ok', true, 'status', (select status from public.equipment where id = p_equipment));
end $function$;

CREATE OR REPLACE FUNCTION public.create_visitor_pass(p_org uuid, p_employee uuid, p_contract uuid, p_ends_at timestamp with time zone, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v public.employees; v_id uuid;
begin
  if not private.has_perm(p_org, 'visitors') then raise exception 'not allowed' using errcode = '42501'; end if;
  if p_contract is null or not exists (select 1 from public.contracts where id = p_contract and org_id = p_org) then return jsonb_build_object('ok', false, 'error', 'unknown_contract'); end if;
  if not private.sees(p_org, auth.uid(), p_contract) then return jsonb_build_object('ok', false, 'error', 'outside_scope'); end if;
  select * into v from public.employees where id = p_employee and org_id = p_org and active;
  if not found then return jsonb_build_object('ok', false, 'error', 'unknown_employee'); end if;
  if private.contracts_share(p_org, p_contract, v.contract_id) then return jsonb_build_object('ok', false, 'error', 'already_allowed'); end if;
  if p_ends_at is null or p_ends_at <= now() then return jsonb_build_object('ok', false, 'error', 'bad_end'); end if;
  if p_ends_at > now() + interval '31 days' then return jsonb_build_object('ok', false, 'error', 'too_long'); end if;
  if length(coalesce(p_note, '')) > 200 then return jsonb_build_object('ok', false, 'error', 'note_too_long'); end if;
  update public.visitor_passes set ended_at = now(), ended_by = auth.uid()
   where employee_id = v.id and contract_id = p_contract and ended_at is null and ends_at > now();   -- the new one replaces it
  insert into public.visitor_passes (org_id, employee_id, contract_id, ends_at, note, created_by)
  values (p_org, v.id, p_contract, p_ends_at, nullif(btrim(coalesce(p_note, '')), ''), auth.uid()) returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id);
end $function$;

CREATE OR REPLACE FUNCTION public.end_visitor_pass(p_pass uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare p public.visitor_passes;
begin
  select * into p from public.visitor_passes where id = p_pass;
  if not found or not private.has_perm(p.org_id, 'visitors')
     or not (private.sees(p.org_id, auth.uid(), p.contract_id) or private.sees(p.org_id, auth.uid(), (select contract_id from public.employees where id = p.employee_id))) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  update public.visitor_passes set ended_at = now(), ended_by = auth.uid() where id = p_pass and ended_at is null;
  return jsonb_build_object('ok', true);
end $function$;

CREATE OR REPLACE FUNCTION public.find_visitors(p_org uuid, p_query text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare q text := btrim(coalesce(p_query, ''));
begin
  if not private.has_perm(p_org, 'visitors') then raise exception 'not allowed' using errcode = '42501'; end if;
  if length(q) < 2 then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(x order by x->>'name') from (
    select jsonb_build_object('id', e.id, 'name', trim(e.first_name || ' ' || e.last_name), 'number', e.employee_number,
             'contract_id', e.contract_id, 'contract', (select name from public.contracts where id = e.contract_id)) x
    from public.employees e
    where e.org_id = p_org and e.active
      and (lower(e.employee_number) = lower(q) or upper(e.barcode) = upper(q)
           or (length(q) >= 3 and lower(trim(e.first_name || ' ' || e.last_name)) like '%' || lower(q) || '%'))
    limit 8) y), '[]'::jsonb);
end $function$;

CREATE OR REPLACE FUNCTION public.dashboard_pin_holders(p_org uuid)
 RETURNS uuid[]
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not private.has_perm(p_org, 'people') then raise exception 'not allowed' using errcode = '42501'; end if;
  return coalesce((select array_agg(p.employee_id) from private.staff_pins p
                   join public.employees e on e.id = p.employee_id where e.org_id = p_org), '{}');
end $function$;

CREATE OR REPLACE FUNCTION public.create_station(p_org uuid, p_name text, p_location uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_station uuid; v_code text := private.new_activation_code(); v_limit int;
begin
  if not private.has_perm(p_org, 'stations') and not private.is_platform_operator() then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  select station_limit into v_limit from public.organizations where id = p_org;
  if v_limit is not null and not private.is_platform_operator()
     and (select count(*) from public.stations where org_id = p_org and revoked_at is null) >= v_limit then
    return jsonb_build_object('ok', false, 'error', 'station_limit', 'limit', v_limit);
  end if;
  insert into public.stations (org_id, name, location_id) values (p_org, p_name, p_location) returning id into v_station;
  insert into private.station_keys (station_id, activation_code_hash, activation_expires_at)
  values (v_station, private.sha256_hex(private.normalize_code(v_code)), now() + interval '7 days');
  return jsonb_build_object('ok', true, 'station_id', v_station, 'activation_code', v_code,
                            'expires_at', now() + interval '7 days');
end $function$;

CREATE OR REPLACE FUNCTION public.remove_station(p_station uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare s public.stations;
begin
  select * into s from public.stations where id = p_station;
  if not found or not private.has_perm(s.org_id, 'stations') or not private.can_see(s.org_id, s.contract_id) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  return private.remove_station(p_station);
end $function$;

CREATE OR REPLACE FUNCTION public.reset_station_activation(p_station uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_org uuid; v_removed timestamptz; v_code text := private.new_activation_code();
begin
  select org_id, removed_at into v_org, v_removed from public.stations where id = p_station;
  if v_org is null or not private.has_perm(v_org, 'stations') then
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
end $function$;

CREATE OR REPLACE FUNCTION public.revoke_station(p_station uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_org uuid;
begin
  select org_id into v_org from public.stations where id = p_station;
  if v_org is null or not private.has_perm(v_org, 'stations') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  update private.station_keys set device_key_hash = null, activation_code_hash = null where station_id = p_station;
  update public.stations set revoked_at = now() where id = p_station;
end $function$;

CREATE OR REPLACE FUNCTION public.set_employee_station_role(p_employee uuid, p_role station_role, p_pin text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_org uuid;
begin
  select org_id into v_org from public.employees where id = p_employee;
  if v_org is null or not private.has_perm(v_org, 'fobs') then raise exception 'not allowed' using errcode = '42501'; end if;
  if p_pin is not null and not private.valid_pin(p_pin) then return jsonb_build_object('ok', false, 'error', 'pin_needed'); end if;
  update public.employees set station_role = p_role where id = p_employee;
  if p_pin is not null then perform private.set_pin(p_employee, p_pin); end if;
  if p_role = 'employee' then delete from private.staff_pins where employee_id = p_employee; end if;
  return jsonb_build_object('ok', true);
end $function$;

CREATE OR REPLACE FUNCTION public.set_email_alerts(p_org uuid, p_user uuid, p_kinds text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not (p_user = auth.uid() and private.has_org_role(p_org)) and not private.has_perm(p_org, 'team') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if not exists (select 1 from public.org_members where org_id = p_org and user_id = p_user) then
    return jsonb_build_object('ok', false, 'error', 'not_a_member');
  end if;
  if not coalesce(p_kinds, '{}') <@ array['problem', 'overdue', 'extended', 'shift_report'] then
    return jsonb_build_object('ok', false, 'error', 'unknown_kind');
  end if;
  insert into public.notification_prefs (org_id, user_id, kinds, updated_at)
  values (p_org, p_user, coalesce(p_kinds, '{}'), now())
  on conflict (org_id, user_id) do update set kinds = excluded.kinds, updated_at = now();
  return jsonb_build_object('ok', true);
end $function$;

CREATE OR REPLACE FUNCTION public.request_contract_change(p_org uuid, p_message text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_msg text := btrim(coalesce(p_message, '')); v_email text; v_name text; v_company text; v_id bigint;
        v_ops text[]; v_console text; e text;
begin
  if not (private.has_org_role(p_org, 'owner') or private.has_perm(p_org, 'team')) then raise exception 'not allowed' using errcode = '42501'; end if;
  if v_msg = '' then return jsonb_build_object('ok', false, 'error', 'bad_message'); end if;
  if length(v_msg) > 4000 then return jsonb_build_object('ok', false, 'error', 'too_long'); end if;
  select lower(u.email), coalesce(nullif(trim(u.raw_user_meta_data->>'full_name'), ''), split_part(u.email, '@', 1))
    into v_email, v_name from auth.users u where u.id = auth.uid();
  if (select count(*) from private.contact_requests where source = 'dashboard' and email = v_email and created_at > now() - interval '1 hour') >= 5 then
    return jsonb_build_object('ok', false, 'error', 'too_many'); end if;
  select name into v_company from public.organizations where id = p_org;
  insert into private.contact_requests (name, email, company, topic, message, kind, org_id, source)
  values (v_name, v_email, v_company, 'Contract change', v_msg, 'support', p_org, 'dashboard') returning id into v_id;

  select value into v_console from private.app_settings where key = 'console_url';
  select array_agg(u.email order by po.created_at) into v_ops
  from private.platform_operators po join auth.users u on u.id = po.user_id where coalesce(u.email, '') like '%@%';
  foreach e in array coalesce(v_ops, '{}') loop
    insert into private.email_batches (org_id, to_email, reply_to, subject, html, body_text)
    values (p_org, e, v_email, 'Contract change: ' || v_company || ' (' || v_name || ')',
      private.email_html(v_company, 'Contract change asked for',
        format('<p style="margin:0 0 12px"><b>%s</b> &lt;%s&gt;</p><p style="margin:0 0 12px;white-space:pre-wrap">%s</p><p style="margin:0;color:#5b6878">Reply to this email to answer them.</p>',
          private.html_esc(v_name), private.html_esc(v_email), private.html_esc(v_msg)),
        v_console || '/#request/' || v_id, 'Open it in the console', 'Sent from the ' || v_company || ' dashboard.'),
      v_name || ' <' || v_email || E'>\n' || v_company || E'\n\n' || v_msg);
  end loop;
  return jsonb_build_object('ok', true, 'id', v_id);
end $function$;

CREATE OR REPLACE FUNCTION public.set_member_role(p_org uuid, p_user uuid, p_role member_role, p_custom_role uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_cur public.member_role;
begin
  select role into v_cur from public.org_members where org_id = p_org and user_id = p_user for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_member'); end if;
  -- A custom role (migration 40) sits under Admin: the person is stored as View Only plus the role's boxes.
  if p_custom_role is not null then
    if not exists (select 1 from public.custom_roles where id = p_custom_role and org_id = p_org) then return jsonb_build_object('ok', false, 'error', 'unknown_role'); end if;
    p_role := 'viewer';
  end if;
  if not private.can_manage_member(p_org, p_user)
     or not (case when p_custom_role is null then private.can_manage_role(p_org, p_role) else private.can_give_custom(p_org, p_custom_role) end) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if v_cur = 'owner' and p_role <> 'owner' and not private.is_platform_operator()
     and (select count(*) from public.org_members where org_id = p_org and role = 'owner') = 1 then
    return jsonb_build_object('ok', false, 'error', 'last_owner');
  end if;
  -- Contracts stay as they are: promoting a lead to Admin makes them Admin of the same contracts.
  update public.org_members set role = p_role, custom_role_id = p_custom_role where org_id = p_org and user_id = p_user;
  if private.is_platform_operator() then perform private.plog(p_org, 'changed team role', jsonb_build_object('email', (select email from auth.users where id = p_user), 'role', coalesce((select name from public.custom_roles where id = p_custom_role), p_role::text))); end if;
  return jsonb_build_object('ok', true);
end $function$;

CREATE OR REPLACE FUNCTION public.remove_member(p_org uuid, p_user uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_cur public.member_role;
begin
  select role into v_cur from public.org_members where org_id = p_org and user_id = p_user for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_member'); end if;
  if not private.can_manage_member(p_org, p_user) then raise exception 'not allowed' using errcode = '42501'; end if;
  if v_cur = 'owner' and not private.is_platform_operator() and (select count(*) from public.org_members where org_id = p_org and role = 'owner') = 1 then
    return jsonb_build_object('ok', false, 'error', 'last_owner');
  end if;
  if private.is_platform_operator() then perform private.plog(p_org, 'removed from team', jsonb_build_object('email', (select email from auth.users where id = p_user))); end if;
  delete from public.org_members where org_id = p_org and user_id = p_user;
  return jsonb_build_object('ok', true);
end $function$;

CREATE OR REPLACE FUNCTION public.cancel_invite(p_invite uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare inv public.org_invites; sc uuid[];
begin
  select * into inv from public.org_invites where id = p_invite;
  if not found or not private.can_manage_role(inv.org_id, inv.role)
     or (inv.custom_role_id is not null and not private.can_give_custom(inv.org_id, inv.custom_role_id)) then raise exception 'not allowed' using errcode = '42501'; end if;
  sc := private.my_scope(inv.org_id);
  if sc is not null and (inv.contracts is null or not inv.contracts <@ sc) then raise exception 'not allowed' using errcode = '42501'; end if;
  delete from public.org_invites where id = p_invite and accepted_at is null;
  if private.is_platform_operator() then perform private.plog(inv.org_id, 'cancelled invite', jsonb_build_object('email', inv.email)); end if;
end $function$;

CREATE OR REPLACE FUNCTION public.invite_member(p_org uuid, p_email text, p_role member_role, p_contracts uuid[] DEFAULT NULL::uuid[], p_custom_role uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare v_email text := lower(trim(p_email)); v_token text := encode(extensions.gen_random_bytes(24), 'hex'); v_id uuid; v_err text;
        v_contracts uuid[] := p_contracts;
begin
  if p_custom_role is not null then
    if not exists (select 1 from public.custom_roles where id = p_custom_role and org_id = p_org) then return jsonb_build_object('ok', false, 'error', 'unknown_role'); end if;
    p_role := 'viewer';
    if not private.can_give_custom(p_org, p_custom_role) then raise exception 'not allowed' using errcode = '42501'; end if;
  elsif not private.can_manage_role(p_org, p_role) then raise exception 'not allowed' using errcode = '42501'; end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then return jsonb_build_object('ok', false, 'error', 'bad_email'); end if;
  if exists (select 1 from public.org_members m join auth.users u on u.id = m.user_id where m.org_id = p_org and lower(u.email) = v_email) then
    return jsonb_build_object('ok', false, 'error', 'already_member');
  end if;
  -- A lead who doesn't pick gives the new person their own contracts.
  if coalesce(cardinality(v_contracts), 0) = 0 and private.my_scope(p_org) is not null then
    select array_agg(contract_id) into v_contracts from public.member_contracts where org_id = p_org and user_id = auth.uid();
  end if;
  v_err := private.contracts_problem(p_org, p_role, v_contracts);
  if v_err is not null then return jsonb_build_object('ok', false, 'error', v_err); end if;
  delete from public.org_invites where org_id = p_org and email = v_email and accepted_at is null;   -- re-invite replaces
  insert into public.org_invites (org_id, email, role, invited_by, token_hash, contracts, custom_role_id)
  values (p_org, v_email, p_role, auth.uid(), private.sha256_hex(v_token), nullif(v_contracts, '{}'), p_custom_role) returning id into v_id;
  if private.is_platform_operator() then
    perform private.plog(p_org, 'invited ' || coalesce(lower((select name from public.custom_roles where id = p_custom_role)), case p_role when 'owner' then 'admin' when 'admin' then 'manager' else p_role::text end),
      jsonb_build_object('email', v_email, 'text', (select string_agg(name, ', ' order by name) from public.contracts where id = any (v_contracts))));
  end if;
  return jsonb_build_object('ok', true, 'invite_id', v_id, 'email', v_email, 'token', v_token, 'expires_at', now() + interval '14 days');
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
  update public.org_invites set accepted_at = now(), accepted_by = auth.uid() where id = inv.id;
  return jsonb_build_object('ok', true, 'org_id', inv.org_id, 'role', inv.role);
end $function$;

CREATE OR REPLACE FUNCTION public.list_members(p_org uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare sc uuid[];
begin
  if not private.has_perm(p_org, 'team') then raise exception 'not allowed' using errcode = '42501'; end if;
  sc := private.my_scope(p_org);
  return jsonb_build_object(
    'members', coalesce((select jsonb_agg(jsonb_build_object(
        'user_id', m.user_id, 'email', u.email, 'name', u.raw_user_meta_data->>'full_name', 'role', m.role,
        'joined_at', m.created_at, 'last_sign_in_at', u.last_sign_in_at,
        'contracts', coalesce((select jsonb_agg(mc.contract_id) from public.member_contracts mc where mc.org_id = p_org and mc.user_id = m.user_id), '[]'::jsonb),
        'custom_role_id', m.custom_role_id, 'role_name', (select name from public.custom_roles where id = m.custom_role_id),
        'manage', private.can_manage_member(p_org, m.user_id)) order by m.role desc, u.email)
      from public.org_members m join auth.users u on u.id = m.user_id
      where m.org_id = p_org and (sc is null or m.role = 'owner' or m.user_id = auth.uid()
        or exists (select 1 from public.member_contracts mc where mc.org_id = p_org and mc.user_id = m.user_id and mc.contract_id = any (sc)))), '[]'::jsonb),
    'invites', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'email', i.email, 'role', i.role,
        'custom_role_id', i.custom_role_id, 'role_name', (select name from public.custom_roles where id = i.custom_role_id),
        'created_at', i.created_at, 'expires_at', i.expires_at, 'contracts', coalesce(to_jsonb(i.contracts), '[]'::jsonb)) order by i.created_at desc)
      from public.org_invites i where i.org_id = p_org and i.accepted_at is null and i.expires_at > now()
        and (sc is null or (i.contracts is not null and i.contracts <@ sc))), '[]'::jsonb));
end $function$;

CREATE OR REPLACE FUNCTION public.set_member_contracts(p_org uuid, p_user uuid, p_contracts uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_role public.member_role; v_err text;
begin
  if not (private.has_perm(p_org, 'team') or private.is_platform_operator()) then raise exception 'not allowed' using errcode = '42501'; end if;
  select role into v_role from public.org_members where org_id = p_org and user_id = p_user;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_a_member'); end if;
  if not private.can_manage_member(p_org, p_user) then raise exception 'not allowed' using errcode = '42501'; end if;
  v_err := private.contracts_problem(p_org, v_role, p_contracts);
  if v_err is not null then return jsonb_build_object('ok', false, 'error', v_err); end if;
  delete from public.member_contracts where org_id = p_org and user_id = p_user;
  insert into public.member_contracts (org_id, user_id, contract_id) select distinct p_org, p_user, c from unnest(coalesce(p_contracts, '{}')) c;
  if private.is_platform_operator() then
    perform private.plog(p_org, 'changed contracts', jsonb_build_object('email', (select email from auth.users where id = p_user),
      'text', (select string_agg(name, ', ' order by name) from public.contracts where id = any (p_contracts))));
  end if;
  return jsonb_build_object('ok', true);
end $function$;

CREATE OR REPLACE FUNCTION public.platform_customer(p_org uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    'contracts', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'parent_id', c.parent_id, 'name', c.name, 'kind', c.kind, 'share', c.share_children, 'move', c.move_on_return,
        'stations', (select count(*) from public.stations s where s.contract_id = c.id and s.revoked_at is null),
        'employees', (select count(*) from public.employees e where e.contract_id = c.id and e.active),
        'equipment', (select count(*) from public.equipment q where q.contract_id = c.id and q.status <> 'retired'))
        order by c.sort_order, c.name) from public.contracts c where c.org_id = p_org), '[]'::jsonb),
    'members', coalesce((select jsonb_agg(jsonb_build_object('user_id', m.user_id, 'email', u.email, 'name', nullif(trim(u.raw_user_meta_data->>'full_name'), ''),
        'role', m.role, 'last_sign_in_at', u.last_sign_in_at, 'custom_role_id', m.custom_role_id,
        'contracts', coalesce((select jsonb_agg(mc.contract_id) from public.member_contracts mc where mc.org_id = p_org and mc.user_id = m.user_id), '[]'::jsonb))
        order by m.role desc, u.email)
      from public.org_members m join auth.users u on u.id = m.user_id where m.org_id = p_org), '[]'::jsonb),
    'custom_roles', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'name', r.name, 'perms', to_jsonb(r.perms), 'contract_id', r.contract_id) order by r.name)
      from public.custom_roles r where r.org_id = p_org), '[]'::jsonb),
    'invites', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'email', i.email, 'role', i.role, 'expires_at', i.expires_at, 'custom_role_id', i.custom_role_id,
        'contracts', coalesce(to_jsonb(i.contracts), '[]'::jsonb)))
      from public.org_invites i where i.org_id = p_org and i.accepted_at is null and i.expires_at > now()), '[]'::jsonb),
    'log', coalesce((select jsonb_agg(jsonb_build_object('at', g.at, 'action', g.action, 'details', g.details,
        'by', coalesce(po.name, u.email)) order by g.at desc)
      from (select * from private.platform_log where org_id = p_org order by at desc limit 50) g
      left join private.platform_operators po on po.user_id = g.operator left join auth.users u on u.id = g.operator), '[]'::jsonb));
end $function$;

revoke execute on all functions in schema private from public, anon, authenticated;
grant  execute on function private.has_org_role(uuid, public.member_role) to authenticated;
grant  execute on function private.normalize_uid(text) to anon, authenticated;
grant  execute on function private.resolve_time_limit(public.time_limit_mode, numeric, public.time_limit_type, numeric) to authenticated;
grant  execute on function private.can_manage_logo(text) to authenticated;
grant  execute on function private.can_see(uuid, uuid), private.can_see_equipment(uuid), private.can_see_txn(uuid, uuid, uuid, uuid),
  private.can_see_tap(uuid, uuid, uuid, uuid), private.sees(uuid, uuid, uuid), private.scope_of(uuid, uuid),
  private.unscoped(uuid), private.my_scope(uuid), private.visited_me(uuid), private.has_perm(uuid, text), private.perms_of(uuid, uuid),
  private.all_perms(), private.role_perms(public.member_role) to authenticated;
revoke execute on function public.set_member_role(uuid, uuid, public.member_role, uuid), public.invite_member(uuid, text, public.member_role, uuid[], uuid),
  public.list_custom_roles(uuid), public.save_custom_role(uuid, jsonb), public.delete_custom_role(uuid) from public, anon;
grant  execute on function public.set_member_role(uuid, uuid, public.member_role, uuid), public.invite_member(uuid, text, public.member_role, uuid[], uuid),
  public.list_custom_roles(uuid), public.save_custom_role(uuid, jsonb), public.delete_custom_role(uuid) to authenticated;
