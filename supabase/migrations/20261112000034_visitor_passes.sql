-- Migration 34: visitor passes.
--
-- Someone from another contract (a PDX crew member working a few days at PHX) can check out at a station that
-- doesn't serve their contract while they hold a pass for it. Nobody signs up again: it's the same badge.
-- * At the station: their badge is refused, a manager from that station taps their fob (and PIN) and the visitor
--   is let in until the end of the day (station_visitor_pass).
-- * Ahead of time on the dashboard: a supervisor or manager who covers the host contract adds a pass with an end
--   date, up to 30 days (find_visitors, create_visitor_pass, end_visitor_pass, list_visitor_passes).
-- Checkouts on a pass get the 'visitor' flag. Hosts see the visitor's name in their history (employees RLS);
-- the visitor's own lead still sees everything they did (their contract).

create table if not exists public.visitor_passes (
  id                   uuid primary key default gen_random_uuid(),
  org_id               uuid not null references public.organizations(id) on delete cascade,
  employee_id          uuid not null references public.employees(id) on delete cascade,
  contract_id          uuid not null,   -- the contract they're visiting (stations that share with it let them in)
  starts_at            timestamptz not null default now(),
  ends_at              timestamptz not null,
  note                 text check (length(note) <= 200),
  created_at           timestamptz not null default now(),
  created_by           uuid references auth.users(id) on delete set null,        -- from the dashboard
  approved_by_employee uuid references public.employees(id) on delete set null, -- a manager's fob at a station
  station_id           uuid references public.stations(id) on delete set null,
  ended_at             timestamptz,
  ended_by             uuid references auth.users(id) on delete set null,
  check (ends_at > starts_at),
  foreign key (contract_id, org_id) references public.contracts(id, org_id) on delete cascade
);
create index if not exists visitor_passes_emp on public.visitor_passes (employee_id, ends_at);
create index if not exists visitor_passes_org on public.visitor_passes (org_id, ends_at);
alter table public.visitor_passes enable row level security;   -- no policies: read and written through the functions below
revoke all on public.visitor_passes from anon, authenticated;
create trigger audit_visitor_passes after insert or update or delete on public.visitor_passes for each row execute function private.audit();

-- Does this person hold a pass for a station in this contract right now?
create or replace function private.on_pass(p_emp uuid, p_station_contract uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.visitor_passes p where p.employee_id = p_emp and p.ended_at is null
                 and now() >= p.starts_at and now() < p.ends_at
                 and private.contracts_share(p.org_id, p.contract_id, p_station_contract))
$$;

-- Midnight tonight in the company's time zone.
create or replace function private.end_of_today(p_org uuid)
returns timestamptz language sql stable security definer set search_path = public as $$
  select (date_trunc('day', now() at time zone tz) + interval '1 day') at time zone tz
  from (select coalesce(timezone, 'America/Phoenix') tz from public.organizations where id = p_org) o
$$;

-- Employees: hosts can see who visited them (names in their history), for 60 days after the pass started.
create or replace function private.visited_me(p_emp uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.visitor_passes p where p.employee_id = p_emp and p.starts_at > now() - interval '60 days'
                 and private.has_org_role(p.org_id) and private.sees(p.org_id, auth.uid(), p.contract_id))
$$;
drop policy if exists emp_select on public.employees;
create policy emp_select on public.employees for select to authenticated
  using (private.can_see(org_id, contract_id) or private.visited_me(id));

-- ---------------------------------------------------------------------
-- Station: same as migration 16, plus passes
-- ---------------------------------------------------------------------
create or replace function public.station_tap(
  p_device_key    text,
  p_client_txn_id uuid,
  p_badge_uid     text,
  p_equipment_uid text,
  p_occurred_at   timestamptz default null,
  p_action        public.txn_action default null,
  p_queued        boolean default false)   -- true = saved while offline; record it even if rules would refuse it now
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  s     public.stations;
  v_emp uuid;
  v_eq  uuid;
  t     public.transactions;
  e     public.employees;
  eq    public.equipment;
  v_out boolean;
  r     jsonb;
  ln    public.equipment_loans;
  v_visit boolean := false;
begin
  s := private.station_from_key(p_device_key);
  if s.id is null then return private.station_denied(p_device_key); end if;
  if p_client_txn_id is null then return jsonb_build_object('ok', false, 'error', 'missing_client_txn_id'); end if;

  update public.stations set last_seen_at = now() where id = s.id;

  select * into t from public.transactions where station_id = s.id and client_txn_id = p_client_txn_id;
  if found then
    return jsonb_build_object('ok', true, 'duplicate', true, 'transaction_id', t.id,
                              'action', t.action, 'flags', to_jsonb(t.flags));
  end if;

  select id into v_emp from public.employees
   where org_id = s.org_id and active and badge_uid = private.normalize_uid(p_badge_uid);
  if v_emp is null then return jsonb_build_object('ok', false, 'error', 'unknown_badge'); end if;

  select id into v_eq from public.equipment
   where org_id = s.org_id and nfc_uid = private.normalize_uid(p_equipment_uid);
  if v_eq is null then return jsonb_build_object('ok', false, 'error', 'unknown_equipment'); end if;

  -- Contracts: this station only serves people from contracts it shares with, or visitors with a pass for it.
  select * into e from public.employees where id = v_emp;
  select * into eq from public.equipment where id = v_eq;
  if not private.contracts_share(s.org_id, s.contract_id, e.contract_id) then
    v_visit := private.on_pass(e.id, s.contract_id);
    if not v_visit and not coalesce(p_queued, false) then
      return jsonb_build_object('ok', false, 'error', 'other_contract',
        'station_contract', (select name from public.contracts where id = s.contract_id),
        'employee_contract', (select name from public.contracts where id = e.contract_id),
        'employee', jsonb_build_object('id', e.id, 'name', trim(e.first_name || ' ' || e.last_name)));
    end if;
  end if;

  ln := private.open_loan(eq.id);
  if ln.id is not null and s.contract_id is not null
     and private.contracts_share(s.org_id, s.contract_id, ln.from_contract_id)
     and not private.contracts_share(s.org_id, s.contract_id, ln.to_contract_id) then
    perform private.end_loan(eq.id, 'returned', null, v_emp);
    if eq.current_employee_id is null and not coalesce(p_queued, false) then
      return jsonb_build_object('ok', true, 'action', 'loan_returned', 'flags', '[]'::jsonb,
        'equipment', jsonb_build_object('id', eq.id, 'name', eq.name),
        'borrower', (select name from public.contracts where id = ln.to_contract_id));
    end if;
    ln := null;
  end if;

  if not coalesce(p_queued, false) then
    v_out := coalesce(p_action = 'checkout', not (eq.status = 'lost' or eq.current_employee_id is not distinct from v_emp
               or (eq.current_employee_id is not null
                   and coalesce(((select settings from public.organizations where id = s.org_id)->>'allow_return_by_other')::boolean, true))));
    if v_out and not private.contracts_share(s.org_id, s.contract_id, eq.contract_id)
       and not (ln.id is not null and private.contracts_share(s.org_id, s.contract_id, ln.to_contract_id)) then
      return jsonb_build_object('ok', false, 'error', 'other_contract_item',
        'equipment', jsonb_build_object('id', eq.id, 'name', eq.name),
        'item_contract', (select name from public.contracts where id = eq.contract_id),
        'loaned_to', (select name from public.contracts where id = ln.to_contract_id));
    end if;
  end if;

  r := private.record_event(s.org_id, v_eq, v_emp, p_action, p_occurred_at,
                            'station', s.id, p_client_txn_id, null, null,
                            not coalesce(p_queued, false));

  -- Checked out by a visitor: mark it so both sides can see.
  if (r->>'ok')::boolean and v_visit then
    update public.transactions set flags = array_append(flags, 'visitor') where id = (r->>'transaction_id')::uuid;
    r := jsonb_set(r, '{flags}', (r->'flags') || '["visitor"]'::jsonb);
  end if;

  if (r->>'ok')::boolean and r->>'action' = 'checkout' and ln.id is not null then
    update public.transactions set flags = array_append(flags, 'on_loan') where id = (r->>'transaction_id')::uuid;
    r := jsonb_set(r, '{flags}', (r->'flags') || '["on_loan"]'::jsonb)
         || jsonb_build_object('loan_from', (select name from public.contracts where id = ln.from_contract_id));
  end if;

  if (r->>'ok')::boolean and r->>'action' = 'checkin' and s.contract_id is not null
     and eq.contract_id is distinct from s.contract_id and not (r->'flags') ? 'late_sync' then
    update public.transactions set flags = array_append(flags, 'returned_other_contract') where id = (r->>'transaction_id')::uuid;
    r := jsonb_set(r, '{flags}', (r->'flags') || '["returned_other_contract"]'::jsonb);
    if ln.id is null and private.contracts_move(s.org_id, eq.contract_id, s.contract_id) then
      update public.equipment set contract_id = s.contract_id where id = eq.id;
      r := r || jsonb_build_object('moved_to', (select name from public.contracts where id = s.contract_id));
    end if;
  end if;
  return r;
exception when unique_violation then
  select * into t from public.transactions where station_id = s.id and client_txn_id = p_client_txn_id;
  return jsonb_build_object('ok', true, 'duplicate', true, 'transaction_id', t.id,
                            'action', t.action, 'flags', to_jsonb(t.flags));
end $$;

-- Same as migration 24, plus 'visitors': {employee id: pass end} for passes good at this station (offline too).
create or replace function public.station_sync_cache(p_device_key text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
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
                    'role', e.station_role, 'contract_id', e.contract_id,
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
end $$;

-- A manager from this station lets a visitor's badge in until the end of the day.
create or replace function public.station_visitor_pass(p_device_key text, p_badge_uid text, p_pin text, p_visitor_badge text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r jsonb; s public.stations; m public.employees; v public.employees; v_end timestamptz; p public.visitor_passes;
begin
  r := private.staff_session(p_device_key, p_badge_uid, p_pin, 'manager');
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
end $$;

-- ---------------------------------------------------------------------
-- Dashboard
-- ---------------------------------------------------------------------
-- Look someone up in the whole company to give them a pass (name, employee # or badge barcode). Supervisors and up.
create or replace function public.find_visitors(p_org uuid, p_query text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare q text := btrim(coalesce(p_query, ''));
begin
  if not private.has_org_role(p_org, 'supervisor') then raise exception 'not allowed' using errcode = '42501'; end if;
  if length(q) < 2 then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(x order by x->>'name') from (
    select jsonb_build_object('id', e.id, 'name', trim(e.first_name || ' ' || e.last_name), 'number', e.employee_number,
             'contract_id', e.contract_id, 'contract', (select name from public.contracts where id = e.contract_id)) x
    from public.employees e
    where e.org_id = p_org and e.active
      and (lower(e.employee_number) = lower(q) or upper(e.barcode) = upper(q)
           or (length(q) >= 3 and lower(trim(e.first_name || ' ' || e.last_name)) like '%' || lower(q) || '%'))
    limit 8) y), '[]'::jsonb);
end $$;

create or replace function public.create_visitor_pass(p_org uuid, p_employee uuid, p_contract uuid, p_ends_at timestamptz, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v public.employees; v_id uuid;
begin
  if not private.has_org_role(p_org, 'supervisor') then raise exception 'not allowed' using errcode = '42501'; end if;
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
end $$;

create or replace function public.end_visitor_pass(p_pass uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare p public.visitor_passes;
begin
  select * into p from public.visitor_passes where id = p_pass;
  if not found or not private.has_org_role(p.org_id, 'supervisor')
     or not (private.sees(p.org_id, auth.uid(), p.contract_id) or private.sees(p.org_id, auth.uid(), (select contract_id from public.employees where id = p.employee_id))) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  update public.visitor_passes set ended_at = now(), ended_by = auth.uid() where id = p_pass and ended_at is null;
  return jsonb_build_object('ok', true);
end $$;

-- Passes into your contracts (visitors) and out of them (your people visiting elsewhere), current and last 7 days.
create or replace function public.list_visitor_passes(p_org uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not private.has_org_role(p_org) then raise exception 'not allowed' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', p.id, 'employee_id', p.employee_id, 'name', trim(e.first_name || ' ' || e.last_name), 'number', e.employee_number,
      'home_contract_id', e.contract_id, 'home_contract', (select name from public.contracts where id = e.contract_id),
      'contract_id', p.contract_id, 'contract', (select name from public.contracts where id = p.contract_id),
      'starts_at', p.starts_at, 'ends_at', p.ends_at, 'ended_at', p.ended_at, 'note', p.note,
      'by', coalesce(trim(a.first_name || ' ' || a.last_name), nullif(trim(u.raw_user_meta_data->>'full_name'), ''), u.email),
      'station', st.name, 'here', private.sees(p_org, auth.uid(), p.contract_id)) order by p.ends_at desc)
    from public.visitor_passes p join public.employees e on e.id = p.employee_id
    left join public.employees a on a.id = p.approved_by_employee left join auth.users u on u.id = p.created_by
    left join public.stations st on st.id = p.station_id
    where p.org_id = p_org and p.ends_at > now() - interval '7 days'
      and (private.sees(p_org, auth.uid(), p.contract_id) or private.sees(p_org, auth.uid(), e.contract_id))), '[]'::jsonb);
end $$;

revoke execute on all functions in schema private from public, anon, authenticated;
grant  execute on function private.has_org_role(uuid, public.member_role) to authenticated;
grant  execute on function private.normalize_uid(text) to anon, authenticated;
grant  execute on function private.resolve_time_limit(public.time_limit_mode, numeric, public.time_limit_type, numeric) to authenticated;
grant  execute on function private.can_manage_logo(text) to authenticated;
grant  execute on function private.can_see(uuid, uuid), private.can_see_equipment(uuid), private.can_see_txn(uuid, uuid, uuid, uuid),
  private.can_see_tap(uuid, uuid, uuid, uuid), private.sees(uuid, uuid, uuid), private.scope_of(uuid, uuid),
  private.unscoped(uuid), private.my_scope(uuid), private.visited_me(uuid) to authenticated;
revoke execute on function public.station_visitor_pass(text, text, text, text) from public;
grant  execute on function public.station_visitor_pass(text, text, text, text) to anon, authenticated;
revoke execute on function public.find_visitors(uuid, text), public.create_visitor_pass(uuid, uuid, uuid, timestamptz, text),
  public.end_visitor_pass(uuid), public.list_visitor_passes(uuid) from public, anon;
grant  execute on function public.find_visitors(uuid, text), public.create_visitor_pass(uuid, uuid, uuid, timestamptz, text),
  public.end_visitor_pass(uuid), public.list_visitor_passes(uuid) to authenticated;
