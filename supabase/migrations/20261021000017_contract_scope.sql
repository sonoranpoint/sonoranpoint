-- =====================================================================
-- 17: Each manager sees only their contracts
--   * An admin (or the owner) picks which contracts a dashboard user covers. They then see
--     those contracts, everything under them, the groups above them, and anything with no
--     contract (it belongs to the whole company). Owners and people with none picked see it all.
--   * Applied in the database itself (row-level security and every dashboard function), so a
--     Delta BW manager can't reach United data even by calling the API directly.
--   * Alert emails only go to people who can see what they're about.
--   * The operator console's customer page gets the contract tree and each station's contract.
-- =====================================================================
create table public.member_contracts (
  org_id      uuid not null,
  user_id     uuid not null,
  contract_id uuid not null,
  primary key (org_id, user_id, contract_id),
  foreign key (org_id, user_id) references public.org_members(org_id, user_id) on delete cascade,
  foreign key (contract_id, org_id) references public.contracts(id, org_id) on delete cascade
);
alter table public.member_contracts enable row level security;
create policy member_contracts_select on public.member_contracts for select to authenticated
  using (user_id = auth.uid() or private.has_org_role(org_id, 'admin'));
revoke insert, update, delete on public.member_contracts from anon, authenticated;

-- What a person can see: null = everything; otherwise their contracts, everything under them, and the groups above.
create function private.scope_of(p_org uuid, p_user uuid)
returns uuid[] language sql stable security definer set search_path = public as $$
  select case
    when exists (select 1 from public.org_members where org_id = p_org and user_id = p_user and role = 'owner') then null
    when not exists (select 1 from public.member_contracts where org_id = p_org and user_id = p_user) then null
    else (
      with recursive down(id) as (
        select contract_id from public.member_contracts where org_id = p_org and user_id = p_user
        union select c.id from public.contracts c join down on c.parent_id = down.id),
      up(id, parent_id) as (
        select c.id, c.parent_id from public.contracts c join public.member_contracts m on m.contract_id = c.id where m.org_id = p_org and m.user_id = p_user
        union select c.id, c.parent_id from public.contracts c join up on c.id = up.parent_id)
      select array_agg(distinct id) from (select id from down union select id from up) x)
  end
$$;

create function private.sees(p_org uuid, p_user uuid, p_contract uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select p_contract is null or coalesce(p_contract = any (private.scope_of(p_org, p_user)), true)
$$;

-- Used by row-level security: a member of the company who covers this contract.
create function private.can_see(p_org uuid, p_contract uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select private.has_org_role(p_org) and private.sees(p_org, auth.uid(), p_contract)
$$;
create function private.can_see_equipment(p_equipment uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select private.can_see(e.org_id, e.contract_id) from public.equipment e where e.id = p_equipment
$$;

-- Admins choose who covers what (owners always see everything).
create function public.set_member_contracts(p_org uuid, p_user uuid, p_contracts uuid[])
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not private.has_org_role(p_org, 'admin') then raise exception 'not allowed' using errcode = '42501'; end if;
  if private.scope_of(p_org, auth.uid()) is not null then return jsonb_build_object('ok', false, 'error', 'scoped_admin'); end if;
  if not exists (select 1 from public.org_members where org_id = p_org and user_id = p_user) then return jsonb_build_object('ok', false, 'error', 'not_a_member'); end if;
  if (select role from public.org_members where org_id = p_org and user_id = p_user) = 'owner' and coalesce(cardinality(p_contracts), 0) > 0 then
    return jsonb_build_object('ok', false, 'error', 'owner_sees_all');
  end if;
  if exists (select 1 from unnest(coalesce(p_contracts, '{}')) c where not exists (select 1 from public.contracts where id = c and org_id = p_org)) then
    return jsonb_build_object('ok', false, 'error', 'unknown_contract');
  end if;
  delete from public.member_contracts where org_id = p_org and user_id = p_user;
  insert into public.member_contracts (org_id, user_id, contract_id) select p_org, p_user, c from unnest(coalesce(p_contracts, '{}')) c;
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------
-- Row-level security: every table a manager reads or edits
-- ---------------------------------------------------------------------
drop policy eq_select on public.equipment;
create policy eq_select on public.equipment for select to authenticated using (private.can_see(org_id, contract_id));
drop policy eq_write on public.equipment;
create policy eq_write on public.equipment for all to authenticated
  using (private.has_org_role(org_id, 'admin') and private.can_see(org_id, contract_id))
  with check (private.has_org_role(org_id, 'admin') and private.can_see(org_id, contract_id));

drop policy st_select on public.stations;
create policy st_select on public.stations for select to authenticated using (private.can_see(org_id, contract_id));
drop policy st_update on public.stations;
create policy st_update on public.stations for update to authenticated
  using (private.has_org_role(org_id, 'admin') and private.can_see(org_id, contract_id))
  with check (private.has_org_role(org_id, 'admin') and private.can_see(org_id, contract_id));
drop policy st_delete on public.stations;
create policy st_delete on public.stations for delete to authenticated
  using (private.has_org_role(org_id, 'admin') and private.can_see(org_id, contract_id));

drop policy emp_select on public.employees;
create policy emp_select on public.employees for select to authenticated using (private.can_see(org_id, contract_id));
drop policy emp_write on public.employees;
create policy emp_write on public.employees for all to authenticated
  using (private.has_org_role(org_id, 'supervisor') and private.can_see(org_id, contract_id))
  with check (private.has_org_role(org_id, 'supervisor') and private.can_see(org_id, contract_id));

-- History: visible if it involved one of your contracts (the item, the station or the person).
drop policy txn_select on public.transactions;
-- (A person with no contract, like the admin office, doesn't make a United tap visible to Delta.)
create function private.can_see_txn(p_org uuid, p_eq uuid, p_station uuid, p_emp uuid)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare sc uuid[]; c_eq uuid; c_st uuid; c_emp uuid;
begin
  if not private.has_org_role(p_org) then return false; end if;
  sc := private.scope_of(p_org, auth.uid());
  if sc is null then return true; end if;
  select contract_id into c_eq from public.equipment where id = p_eq;
  select contract_id into c_st from public.stations where id = p_station;
  select contract_id into c_emp from public.employees where id = p_emp;
  return c_eq = any (sc) or c_st = any (sc) or c_emp = any (sc) or (c_eq is null and c_st is null);
end $$;
create policy txn_select on public.transactions for select to authenticated
  using (private.can_see_txn(org_id, equipment_id, station_id, employee_id));

drop policy alerts_select on public.equipment_alerts;
create policy alerts_select on public.equipment_alerts for select to authenticated using (private.can_see_equipment(equipment_id));
drop policy equipment_problems_select on public.equipment_problems;
create policy equipment_problems_select on public.equipment_problems for select to authenticated using (private.can_see_equipment(equipment_id));
drop policy equipment_loans_select on public.equipment_loans;
create policy equipment_loans_select on public.equipment_loans for select to authenticated
  using (private.can_see_equipment(equipment_id) or private.can_see(org_id, to_contract_id));

drop policy shifts_select on public.shifts;
create policy shifts_select on public.shifts for select to authenticated using (private.can_see(org_id, contract_id));
drop policy shifts_write on public.shifts;
create policy shifts_write on public.shifts for all to authenticated
  using (private.has_org_role(org_id, 'admin') and private.can_see(org_id, contract_id))
  with check (private.has_org_role(org_id, 'admin') and private.can_see(org_id, contract_id));
grant insert (contract_id), update (contract_id) on public.shifts to authenticated;
drop policy assign_select on public.shift_assignments;
create policy assign_select on public.shift_assignments for select to authenticated
  using (private.can_see(org_id, (select contract_id from public.shifts where id = shift_id)));
drop policy assign_write on public.shift_assignments;
create policy assign_write on public.shift_assignments for all to authenticated
  using (private.has_org_role(org_id, 'supervisor') and private.can_see(org_id, (select contract_id from public.shifts where id = shift_id)))
  with check (private.has_org_role(org_id, 'supervisor') and private.can_see(org_id, (select contract_id from public.shifts where id = shift_id)));
drop policy reports_select on public.shift_reports;
create policy reports_select on public.shift_reports for select to authenticated
  using (private.can_see(org_id, (select contract_id from public.shifts where id = shift_id)));

-- The tree itself: your branch and the groups above it.
drop policy contracts_select on public.contracts;
create policy contracts_select on public.contracts for select to authenticated using (private.can_see(org_id, id));

-- ---------------------------------------------------------------------
-- Dashboard functions check the contract too
-- ---------------------------------------------------------------------
create or replace function public.set_equipment_status(p_equipment uuid, p_status public.equipment_status, p_notes text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare eq public.equipment;
begin
  select * into eq from public.equipment where id = p_equipment for update;
  if not found or not private.has_org_role(eq.org_id, 'supervisor') or not private.can_see(eq.org_id, eq.contract_id) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if p_status = 'retired' and not private.has_org_role(eq.org_id, 'admin') then
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
end $$;

create or replace function public.dashboard_record_event(
  p_equipment uuid, p_employee uuid, p_action public.txn_action,
  p_occurred_at timestamptz default null, p_notes text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_org uuid;
begin
  select org_id into v_org from public.equipment where id = p_equipment;
  if v_org is null or not private.has_org_role(v_org, 'supervisor') or not private.can_see_equipment(p_equipment)
     or not private.can_see(v_org, (select contract_id from public.employees where id = p_employee)) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if not exists (select 1 from public.employees where id = p_employee and org_id = v_org) then
    return jsonb_build_object('ok', false, 'error', 'unknown_employee');
  end if;
  return private.record_event(v_org, p_equipment, p_employee, p_action,
                              coalesce(p_occurred_at, now()), 'dashboard',
                              null, null, auth.uid(), p_notes);
end $$;

create or replace function public.acknowledge_alert(p_alert uuid, p_notes text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_org uuid;
begin
  select org_id into v_org from public.equipment_alerts where id = p_alert;
  if v_org is null or not private.has_org_role(v_org, 'supervisor')
     or not private.can_see_equipment((select equipment_id from public.equipment_alerts where id = p_alert)) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  update public.equipment_alerts
     set acknowledged_by = auth.uid(), acknowledged_at = now(), notes = p_notes
   where id = p_alert;
end $$;

create or replace function public.acknowledge_shift_report(p_report uuid, p_notes text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_org uuid;
begin
  select org_id into v_org from public.shift_reports where id = p_report;
  if v_org is null or not private.has_org_role(v_org, 'supervisor')
     or not private.can_see(v_org, (select s.contract_id from public.shift_reports r join public.shifts s on s.id = r.shift_id where r.id = p_report)) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  update public.shift_reports
     set acknowledged_by = auth.uid(), acknowledged_at = now(), acknowledgement_notes = p_notes
   where id = p_report;
end $$;

create or replace function public.shift_report(p_shift uuid, p_date date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_org uuid;
begin
  select org_id into v_org from public.shifts where id = p_shift;
  if v_org is null or not private.can_see(v_org, (select contract_id from public.shifts where id = p_shift)) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if not private.module_enabled(v_org, 'shifts') then
    return jsonb_build_object('ok', false, 'error', 'module_not_enabled');
  end if;
  return private.build_shift_report(p_shift, p_date);
end $$;

create or replace function public.report_problem(p_equipment uuid, p_reason uuid, p_notes text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_org uuid;
begin
  select org_id into v_org from public.equipment where id = p_equipment;
  if v_org is null or not private.has_org_role(v_org, 'supervisor') or not private.can_see_equipment(p_equipment) then raise exception 'not allowed' using errcode = '42501'; end if;
  return private.add_problem(v_org, p_equipment, p_reason, p_notes, null, auth.uid(), null, null, now());
end $$;

create or replace function public.clear_problem(p_problem uuid, p_notes text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare p public.equipment_problems;
begin
  select * into p from public.equipment_problems where id = p_problem;
  if not found or not private.has_org_role(p.org_id, 'supervisor') or not private.can_see_equipment(p.equipment_id) then raise exception 'not allowed' using errcode = '42501'; end if;
  if p.cleared_at is not null then return jsonb_build_object('ok', true, 'already_cleared', true); end if;
  update public.equipment_problems set cleared_at = now(), cleared_by_user = auth.uid(),
         clear_notes = nullif(left(trim(p_notes), 500), '') where id = p.id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.lend_equipment(p_equipment uuid, p_to_contract uuid, p_notes text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_org uuid;
begin
  select org_id into v_org from public.equipment where id = p_equipment;
  if v_org is null or not private.has_org_role(v_org, 'supervisor') or not private.can_see_equipment(p_equipment) then raise exception 'not allowed' using errcode = '42501'; end if;
  return private.lend(v_org, p_equipment, p_to_contract, p_notes, auth.uid(), null, null);
end $$;

create or replace function public.end_equipment_loan(p_equipment uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_org uuid;
begin
  select org_id into v_org from public.equipment where id = p_equipment;
  if v_org is null or not private.has_org_role(v_org, 'supervisor')
     or not (private.can_see_equipment(p_equipment) or private.can_see(v_org, (private.open_loan(p_equipment)).to_contract_id)) then raise exception 'not allowed' using errcode = '42501'; end if;
  return jsonb_build_object('ok', true, 'ended', private.end_loan(p_equipment, 'ended', auth.uid(), null));
end $$;

-- ---------------------------------------------------------------------
-- Alert emails: only to people who can see what they're about
-- ---------------------------------------------------------------------
create or replace function private.enqueue_email(p_org uuid, p_kind text, p_title text, p_detail text, p_link text, p_at timestamptz, p_contract uuid)
returns void language sql security definer set search_path = public as $$
  insert into private.email_queue (org_id, user_id, to_email, kind, title, detail, link, at)
  select p_org, u.id, u.email, p_kind, p_title, p_detail, p_link, coalesce(p_at, now())
  from public.notification_prefs n
  join public.org_members m on m.org_id = n.org_id and m.user_id = n.user_id
  join auth.users u on u.id = n.user_id
  where n.org_id = p_org and p_kind = any (n.kinds) and coalesce(u.email, '') like '%@%'
    and private.sees(p_org, n.user_id, p_contract);
$$;
create or replace function private.email_on_problem()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_item text; v_station text; v_by text;
begin
  select name into v_item from public.equipment where id = new.equipment_id;
  select name into v_station from public.stations where id = new.station_id;
  v_by := coalesce(private.emp_name(new.reported_by_employee),
                   (select coalesce(nullif(raw_user_meta_data->>'full_name', ''), email) from auth.users where id = new.reported_by_user));
  perform private.enqueue_email(new.org_id, 'problem', v_item || ': ' || new.reason,
    'Reported' || coalesce(' by ' || v_by, '') || case when new.station_id is not null then coalesce(' at ' || v_station, ' at a station') else ' on the dashboard' end || '.'
      || case when new.blocks_checkout then ' It can''t be checked out until a supervisor clears it.' else '' end
      || coalesce(' Note: "' || new.notes || '"', ''),
    private.dash_link(new.org_id, 'equipment', 'equipment:' || new.equipment_id), new.reported_at,
    (select contract_id from public.equipment where id = new.equipment_id));
  return null;
end $$;

create or replace function private.email_on_alert()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_item text; v_who text; v_tz text;
begin
  select e.name, o.timezone into v_item, v_tz from public.equipment e join public.organizations o on o.id = e.org_id where e.id = new.equipment_id;
  v_who := private.emp_name(new.employee_id);
  perform private.enqueue_email(new.org_id, case new.kind when 'overdue' then 'overdue' else 'extended' end,
    v_item || case new.kind when 'overdue' then ' is overdue' else ' has been out too long' end,
    coalesce('With ' || v_who || ' since ', 'Out since ')
      || to_char(new.checked_out_at at time zone v_tz, 'Dy Mon FMDD, FMHH12:MI AM') || '.'
      || case new.kind when 'overdue' then ' It was due ' || to_char(new.threshold_at at time zone v_tz, 'FMHH12:MI AM') || '.' else '' end,
    private.dash_link(new.org_id, 'equipment', 'equipment:' || new.equipment_id), new.threshold_at,
    (select contract_id from public.equipment where id = new.equipment_id));
  return null;
end $$;

create or replace function private.email_on_shift_report()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_shift text;
begin
  if new.outstanding_count = 0 then return null; end if;
  select name into v_shift from public.shifts where id = new.shift_id;
  perform private.enqueue_email(new.org_id, 'shift_report',
    v_shift || ' shift, ' || to_char(new.shift_date, 'Dy Mon FMDD') || ': ' || new.outstanding_count
      || case when new.outstanding_count = 1 then ' item' else ' items' end || ' not back on time',
    case when new.still_out_count > 0 then new.still_out_count || ' still out.' else 'All back now.' end
      || ' ' || coalesce((select string_agg(i->>'name', ', ') from jsonb_array_elements(new.items) i), ''),
    private.dash_link(new.org_id, 'shifts', 'report:' || new.id), new.cutoff,
    (select contract_id from public.shifts where id = new.shift_id));
  return null;
end $$;
drop function if exists private.enqueue_email(uuid, text, text, text, text, timestamptz);

-- ---------------------------------------------------------------------
-- Operator console: contracts on the customer page
-- ---------------------------------------------------------------------
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
        'code_expires_at', k.activation_expires_at, 'created_at', s.created_at, 'contract_id', s.contract_id) order by s.created_at)
      from public.stations s left join public.locations l on l.id = s.location_id
      left join private.station_keys k on k.station_id = s.id where s.org_id = p_org), '[]'::jsonb),
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
revoke execute on function public.set_member_contracts(uuid, uuid, uuid[]) from public;
grant  execute on function public.set_member_contracts(uuid, uuid, uuid[]) to authenticated;
