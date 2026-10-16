-- =====================================================================
-- Optional module: Shifts
--   • Define shifts (e.g. "AM 05:00–13:30", "Overnight 22:00–06:30")
--   • Assign employees to shifts
--   • End-of-shift report: what employees on that shift had checked out
--     and did NOT return by the end of the shift (+ grace period)
--   • Reports are generated automatically after each shift and kept,
--     so supervisors can review and sign off.
--
-- Turned on per company by adding 'shifts' to organizations.enabled_modules.
-- =====================================================================

-- Modules are part of what a customer pays for, so customers can't switch
-- them on themselves. Admins may edit everything else about their company.
revoke insert, update on public.organizations from anon, authenticated;
grant update (name, logo_url, primary_color, accent_color, timezone, extended_checkout_hours, terminology, settings)
  on public.organizations to authenticated;

create function private.module_enabled(p_org uuid, p_module text)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select p_module = any(enabled_modules) from public.organizations where id = p_org), false)
$$;

-- ---------------------------------------------------------------------
-- Shift definitions
-- ---------------------------------------------------------------------
create table public.shifts (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references public.organizations(id) on delete cascade,
  name          text not null,
  start_time    time not null,              -- local time in the company's timezone
  end_time      time not null,              -- earlier than start_time = ends next day (overnight)
  days_of_week  smallint[],                 -- ISO days 1=Mon … 7=Sun; null = every day
  location_id   uuid,
  grace_minutes int not null default 15 check (grace_minutes between 0 and 720),
  -- Checkouts this many minutes before the shift starts count as that shift
  -- (people grab equipment before clocking in).
  early_checkout_minutes int not null default 60 check (early_checkout_minutes between 0 and 720),
  active        boolean not null default true,
  created_at    timestamptz not null default now(),
  unique (id, org_id),
  unique (org_id, name),
  check (end_time <> start_time),
  check (days_of_week <@ array[1,2,3,4,5,6,7]::smallint[]),
  foreign key (location_id, org_id) references public.locations(id, org_id) on delete set null (location_id)
);

-- Which employees work which shift (an employee can be on more than one).
create table public.shift_assignments (
  org_id      uuid not null references public.organizations(id) on delete cascade,
  shift_id    uuid not null,
  employee_id uuid not null,
  created_at  timestamptz not null default now(),
  primary key (shift_id, employee_id),
  foreign key (shift_id, org_id)    references public.shifts(id, org_id) on delete cascade,
  foreign key (employee_id, org_id) references public.employees(id, org_id) on delete cascade
);
create index on public.shift_assignments (employee_id);

-- Saved end-of-shift reports (a snapshot, so it doesn't change after the fact).
create table public.shift_reports (
  id                    uuid primary key default gen_random_uuid(),
  org_id                uuid not null references public.organizations(id) on delete cascade,
  shift_id              uuid not null,
  shift_date            date not null,      -- the local date the shift STARTED
  shift_start           timestamptz not null,
  shift_end             timestamptz not null,
  cutoff                timestamptz not null,   -- shift_end + grace
  outstanding_count     int not null,       -- not returned by the cutoff
  still_out_count       int not null,       -- …and still not returned when the report was made
  items                 jsonb not null,
  generated_at          timestamptz not null default now(),
  acknowledged_by       uuid references auth.users(id),
  acknowledged_at       timestamptz,
  acknowledgement_notes text,
  unique (shift_id, shift_date),
  foreign key (shift_id, org_id) references public.shifts(id, org_id) on delete cascade
);
create index on public.shift_reports (org_id, shift_date desc);
create index on public.shift_reports (org_id) where acknowledged_at is null and outstanding_count > 0;

create trigger audit_shifts            after insert or update or delete on public.shifts            for each row execute function private.audit();
create trigger audit_shift_assignments after insert or update or delete on public.shift_assignments for each row execute function private.audit();

-- ---------------------------------------------------------------------
-- "Due at end of shift": replaces the core placeholder.
-- Finds the shift(s) the employee is working at that moment (including the
-- early window before start) and returns when it ends. If they're on two
-- overlapping shifts (a double), the later end wins. null = not on a shift,
-- or the company doesn't have the Shifts module.
-- ---------------------------------------------------------------------
create or replace function private.employee_shift_end(p_employee uuid, p_at timestamptz)
returns timestamptz language sql stable security definer set search_path = public as $$
  select max(w.shift_end)
  from public.shift_assignments a
  join public.shifts s on s.id = a.shift_id and s.active
  join public.organizations o on o.id = s.org_id and 'shifts' = any(o.enabled_modules)
  -- the shift could have started today or yesterday (overnight shifts)
  cross join lateral (values ((p_at at time zone o.timezone)::date),
                             ((p_at at time zone o.timezone)::date - 1)) d(day)
  cross join lateral (select
      (d.day + s.start_time) at time zone o.timezone as shift_start,
      (d.day + s.end_time + case when s.end_time < s.start_time then interval '1 day' else interval '0' end)
        at time zone o.timezone as shift_end) w
  where a.employee_id = p_employee
    and (s.days_of_week is null or extract(isodow from d.day)::smallint = any(s.days_of_week))
    and p_at >= w.shift_start - make_interval(mins => s.early_checkout_minutes)
    and p_at <  w.shift_end
$$;

-- ---------------------------------------------------------------------
-- The report itself
-- ---------------------------------------------------------------------
-- For one shift on one date: every item that, at the cutoff (shift end + grace),
-- was last checked out by an employee assigned to that shift. Built from the
-- transaction history, so it's correct for past dates too and isn't fooled by
-- stations uploading late. Each item gets an outcome:
--   not_returned   – still out right now
--   returned_late  – came back after the cutoff (with when and who)
--   taken_by_other – someone else checked it out after the cutoff
create function private.build_shift_report(p_shift uuid, p_date date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  sh public.shifts;
  tz text;
  v_start timestamptz; v_end timestamptz; v_cutoff timestamptz;
  v_items jsonb;
begin
  select * into sh from public.shifts where id = p_shift;
  if not found then return jsonb_build_object('ok', false, 'error', 'unknown_shift'); end if;
  select timezone into tz from public.organizations where id = sh.org_id;

  v_start  := (p_date + sh.start_time) at time zone tz;
  v_end    := (p_date + sh.end_time
               + case when sh.end_time < sh.start_time then interval '1 day' else interval '0' end)
              at time zone tz;
  v_cutoff := v_end + make_interval(mins => sh.grace_minutes);

  with last_event as (          -- each item's most recent event as of the cutoff
    select distinct on (t.equipment_id) t.equipment_id, t.employee_id, t.action, t.occurred_at
    from public.transactions t
    where t.org_id = sh.org_id and t.occurred_at <= v_cutoff
    order by t.equipment_id, t.occurred_at desc, t.received_at desc
  ), outstanding as (           -- …that is a checkout by someone on this shift
    select le.* from last_event le
    join public.shift_assignments a on a.shift_id = sh.id and a.employee_id = le.employee_id
    where le.action = 'checkout'
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'equipment_id',    e.id,
      'equipment',       e.name,
      'asset_tag',       e.asset_tag,
      'category',        c.name,
      'employee_id',     emp.id,
      'employee',        trim(emp.first_name || ' ' || emp.last_name),
      'employee_number', emp.employee_number,
      'checked_out_at',  o.occurred_at,
      'outcome', case
                   when nx.action = 'checkin' then 'returned_late'
                   when nx.action = 'checkout' and nx.employee_id <> o.employee_id then 'taken_by_other'
                   else 'not_returned' end,
      'resolved_at',     case when nx.action = 'checkin' or nx.employee_id <> o.employee_id then nx.occurred_at end,
      'resolved_by',     case when nx.action = 'checkin' or nx.employee_id <> o.employee_id
                              then trim(nemp.first_name || ' ' || nemp.last_name) end
    ) order by c.name nulls last, e.name), '[]'::jsonb)
  into v_items
  from outstanding o
  join public.equipment e on e.id = o.equipment_id
  join public.employees emp on emp.id = o.employee_id
  left join public.equipment_categories c on c.id = e.category_id
  left join lateral (            -- what happened to the item next
    select t2.action, t2.occurred_at, t2.employee_id from public.transactions t2
    where t2.equipment_id = o.equipment_id and t2.occurred_at > v_cutoff
    order by t2.occurred_at, t2.received_at limit 1
  ) nx on true
  left join public.employees nemp on nemp.id = nx.employee_id;

  return jsonb_build_object(
    'ok', true,
    'shift_id', sh.id, 'shift', sh.name, 'shift_date', p_date,
    'scheduled', sh.days_of_week is null or extract(isodow from p_date)::smallint = any(sh.days_of_week),
    'shift_start', v_start, 'shift_end', v_end, 'cutoff', v_cutoff,
    'in_progress', v_cutoff > now(),
    'outstanding_count', jsonb_array_length(v_items),
    'still_out_count', (select count(*) from jsonb_array_elements(v_items) x where x->>'outcome' = 'not_returned'),
    'items', v_items
  );
end $$;

-- Dashboard: view any shift's report on demand. For a shift still in progress
-- this is a live preview ("if the shift ended now, these would be outstanding").
create function public.shift_report(p_shift uuid, p_date date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_org uuid;
begin
  select org_id into v_org from public.shifts where id = p_shift;
  if v_org is null or not private.has_org_role(v_org) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if not private.module_enabled(v_org, 'shifts') then
    return jsonb_build_object('ok', false, 'error', 'module_not_enabled');
  end if;
  return private.build_shift_report(p_shift, p_date);
end $$;

-- Supervisor sign-off ("reviewed, radio 07 is in the lost & found").
create function public.acknowledge_shift_report(p_report uuid, p_notes text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_org uuid;
begin
  select org_id into v_org from public.shift_reports where id = p_report;
  if v_org is null or not private.has_org_role(v_org, 'supervisor') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  update public.shift_reports
     set acknowledged_by = auth.uid(), acknowledged_at = now(), acknowledgement_notes = p_notes
   where id = p_report;
end $$;

-- Saves reports for every shift that has ended (past its grace period) and
-- doesn't have one yet. Runs on a schedule; safe to run as often as you like.
-- Looks back 2 days so a short outage doesn't skip reports.
create function private.generate_shift_reports()
returns int language plpgsql security definer set search_path = public as $$
declare
  r record; d date; rep jsonb; n int := 0;
begin
  for r in
    select s.*, o.timezone from public.shifts s
    join public.organizations o on o.id = s.org_id
    where s.active and 'shifts' = any(o.enabled_modules)
  loop
    for d in select g::date from generate_series((now() at time zone r.timezone)::date - 2,
                                                 (now() at time zone r.timezone)::date, interval '1 day') g
    loop
      continue when r.days_of_week is not null and extract(isodow from d)::smallint <> all(r.days_of_week);
      continue when exists (select 1 from public.shift_reports where shift_id = r.id and shift_date = d);
      rep := private.build_shift_report(r.id, d);
      continue when (rep->>'cutoff')::timestamptz > now()             -- not over yet
                 or (rep->>'shift_start')::timestamptz < r.created_at; -- before the shift existed
      insert into public.shift_reports
        (org_id, shift_id, shift_date, shift_start, shift_end, cutoff,
         outstanding_count, still_out_count, items)
      values
        (r.org_id, r.id, d, (rep->>'shift_start')::timestamptz, (rep->>'shift_end')::timestamptz,
         (rep->>'cutoff')::timestamptz, (rep->>'outstanding_count')::int,
         (rep->>'still_out_count')::int, rep->'items')
      on conflict (shift_id, shift_date) do nothing;
      n := n + 1;
    end loop;
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------------
-- Security
-- ---------------------------------------------------------------------
alter table public.shifts            enable row level security;
alter table public.shift_assignments enable row level security;
alter table public.shift_reports     enable row level security;

create policy shifts_select on public.shifts for select to authenticated using (private.has_org_role(org_id));
create policy shifts_write  on public.shifts for all to authenticated
  using (private.has_org_role(org_id, 'admin')) with check (private.has_org_role(org_id, 'admin'));

-- Supervisors handle who's on which shift.
create policy assign_select on public.shift_assignments for select to authenticated using (private.has_org_role(org_id));
create policy assign_write  on public.shift_assignments for all to authenticated
  using (private.has_org_role(org_id, 'supervisor')) with check (private.has_org_role(org_id, 'supervisor'));

-- Saved reports are read-only; sign-off goes through acknowledge_shift_report().
create policy reports_select on public.shift_reports for select to authenticated using (private.has_org_role(org_id));
revoke insert, update, delete on public.shift_reports from anon, authenticated;

revoke execute on all functions in schema private from public, anon, authenticated;
grant  execute on function private.has_org_role(uuid, public.member_role) to authenticated;
grant  execute on function private.normalize_uid(text) to anon, authenticated;
grant  execute on function private.resolve_time_limit(public.time_limit_mode, numeric, public.time_limit_type, numeric) to authenticated;

revoke execute on function public.shift_report(uuid, date), public.acknowledge_shift_report(uuid, text) from public;
grant  execute on function public.shift_report(uuid, date), public.acknowledge_shift_report(uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- Schedule: generate reports every 5 minutes (Supabase has pg_cron).
-- ---------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    execute 'create extension if not exists pg_cron';
    execute $q$select cron.schedule('generate-shift-reports', '*/5 * * * *',
                                    'select private.generate_shift_reports()')$q$;
  else
    raise notice 'pg_cron not available: call private.generate_shift_reports() on a schedule another way';
  end if;
end $$;
