-- =====================================================================
-- 11: Reporting a problem with equipment, and alerts by email
--
-- Problems
--   * Each company has its own list of reasons (starts with Damaged, Not charging,
--     Missing part, Other). Admins add, rename and remove them. A reason can
--     block checkout ("Damaged" does by default).
--   * Anyone can report a problem at the station (badge, tap the item, pick a reason);
--     supervisors can report from the dashboard too.
--   * An item with an open blocking problem can't be checked out until a supervisor
--     clears it (dashboard, or a manager/admin fob at the station). It can always be returned.
--
-- Email alerts
--   * Each dashboard user picks which alerts they get by email (admins can set them for
--     anyone in the company). New owners and admins start with "Problem reported" on.
--   * Emails are queued in private.email_queue, grouped per person every minute and sent
--     through Resend from the database (pg_net). Needs the Resend API key saved in Vault
--     under the name resend_api_key; without it, nothing is sent and the queue just waits.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Problem reasons (per company)
-- ---------------------------------------------------------------------
create table public.problem_reasons (
  id              uuid primary key default gen_random_uuid(),
  org_id          uuid not null references public.organizations(id) on delete cascade,
  label           text not null check (length(trim(label)) between 1 and 40),
  blocks_checkout boolean not null default false,
  sort_order      int not null default 0,
  archived_at     timestamptz,             -- removed from the list; kept so old reports still read right
  created_at      timestamptz not null default now(),
  unique (id, org_id)
);
create unique index problem_reasons_label on public.problem_reasons (org_id, lower(trim(label))) where archived_at is null;
create trigger audit_problem_reasons after insert or update or delete on public.problem_reasons for each row execute function private.audit();

create function private.seed_problem_reasons(p_org uuid)
returns void language sql security definer set search_path = public as $$
  insert into public.problem_reasons (org_id, label, blocks_checkout, sort_order) values
    (p_org, 'Damaged', true, 1), (p_org, 'Not charging', false, 2),
    (p_org, 'Missing part', false, 3), (p_org, 'Other', false, 4);
$$;
create function private.org_seed_problem_reasons()
returns trigger language plpgsql security definer set search_path = public as $$
begin perform private.seed_problem_reasons(new.id); return null; end $$;
create trigger seed_problem_reasons after insert on public.organizations
  for each row execute function private.org_seed_problem_reasons();
select private.seed_problem_reasons(id) from public.organizations;

-- ---------------------------------------------------------------------
-- Reported problems
-- ---------------------------------------------------------------------
create table public.equipment_problems (
  id                   uuid primary key default gen_random_uuid(),
  org_id               uuid not null references public.organizations(id) on delete cascade,
  equipment_id         uuid not null,
  reason_id            uuid,
  reason               text not null,              -- the reason's words when it was reported
  blocks_checkout      boolean not null default false,
  notes                text check (length(notes) <= 500),
  reported_at          timestamptz not null default now(),
  reported_by_employee uuid,                       -- badge at a station
  reported_by_user     uuid references auth.users(id) on delete set null,  -- or a dashboard user
  station_id           uuid,
  client_report_id     uuid,                       -- generated on the station; makes re-uploads safe
  cleared_at           timestamptz,
  cleared_by_user      uuid references auth.users(id) on delete set null,
  cleared_by_employee  uuid,
  clear_notes          text check (length(clear_notes) <= 500),
  unique (station_id, client_report_id),
  foreign key (equipment_id, org_id) references public.equipment(id, org_id) on delete cascade,
  foreign key (reason_id, org_id) references public.problem_reasons(id, org_id) on delete set null (reason_id),
  foreign key (reported_by_employee, org_id) references public.employees(id, org_id) on delete set null (reported_by_employee),
  foreign key (cleared_by_employee, org_id) references public.employees(id, org_id) on delete set null (cleared_by_employee),
  foreign key (station_id, org_id) references public.stations(id, org_id) on delete set null (station_id)
);
create index on public.equipment_problems (equipment_id) where cleared_at is null;
create index on public.equipment_problems (org_id, reported_at desc);

-- The newest open problem on an item (null if none). Blocking problems come first.
create function private.open_problem(p_equipment uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', p.id, 'reason', p.reason, 'blocks_checkout', p.blocks_checkout,
                            'reported_at', p.reported_at, 'notes', p.notes)
  from public.equipment_problems p
  where p.equipment_id = p_equipment and p.cleared_at is null
  order by p.blocks_checkout desc, p.reported_at desc limit 1
$$;

-- Shared by the dashboard and the station.
create function private.add_problem(p_org uuid, p_equipment uuid, p_reason uuid, p_notes text,
  p_employee uuid, p_user uuid, p_station uuid, p_client uuid, p_at timestamptz)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r public.problem_reasons; eq public.equipment; v_id uuid; v_open uuid;
begin
  select * into eq from public.equipment where id = p_equipment and org_id = p_org;
  if not found then return jsonb_build_object('ok', false, 'error', 'unknown_equipment'); end if;
  select * into r from public.problem_reasons where id = p_reason and org_id = p_org;   -- removed reasons still count (offline reports)
  if not found then return jsonb_build_object('ok', false, 'error', 'unknown_reason'); end if;
  -- Same thing already reported and not cleared yet: don't pile up duplicates.
  select id into v_open from public.equipment_problems
   where equipment_id = eq.id and cleared_at is null and reason_id = r.id;
  if v_open is not null then
    if nullif(trim(p_notes), '') is not null then
      update public.equipment_problems set notes = left(coalesce(notes || E'\n', '') || trim(p_notes), 500) where id = v_open;
    end if;
    return jsonb_build_object('ok', true, 'already_reported', true, 'id', v_open,
      'equipment', jsonb_build_object('id', eq.id, 'name', eq.name), 'reason', r.label, 'blocks_checkout', r.blocks_checkout);
  end if;
  insert into public.equipment_problems (org_id, equipment_id, reason_id, reason, blocks_checkout, notes,
      reported_at, reported_by_employee, reported_by_user, station_id, client_report_id)
  values (p_org, eq.id, r.id, r.label, r.blocks_checkout, nullif(left(trim(p_notes), 500), ''),
      least(coalesce(p_at, now()), now()), p_employee, p_user, p_station, p_client)
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id, 'equipment', jsonb_build_object('id', eq.id, 'name', eq.name),
    'reason', r.label, 'blocks_checkout', r.blocks_checkout,
    'held_by_reporter', p_employee is not null and eq.current_employee_id = p_employee);
end $$;

-- Dashboard (supervisor and up)
create function public.report_problem(p_equipment uuid, p_reason uuid, p_notes text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_org uuid;
begin
  select org_id into v_org from public.equipment where id = p_equipment;
  if v_org is null or not private.has_org_role(v_org, 'supervisor') then raise exception 'not allowed' using errcode = '42501'; end if;
  return private.add_problem(v_org, p_equipment, p_reason, p_notes, null, auth.uid(), null, null, now());
end $$;

create function public.clear_problem(p_problem uuid, p_notes text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare p public.equipment_problems;
begin
  select * into p from public.equipment_problems where id = p_problem;
  if not found or not private.has_org_role(p.org_id, 'supervisor') then raise exception 'not allowed' using errcode = '42501'; end if;
  if p.cleared_at is not null then return jsonb_build_object('ok', true, 'already_cleared', true); end if;
  update public.equipment_problems set cleared_at = now(), cleared_by_user = auth.uid(),
         clear_notes = nullif(left(trim(p_notes), 500), '') where id = p.id;
  return jsonb_build_object('ok', true);
end $$;

-- Admins manage the list. p: {id?, label, blocks_checkout, sort_order?}
create function public.save_problem_reason(p_org uuid, p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_label text := trim(coalesce(p->>'label', ''));
begin
  if not private.has_org_role(p_org, 'admin') then raise exception 'not allowed' using errcode = '42501'; end if;
  if length(v_label) = 0 then return jsonb_build_object('ok', false, 'error', 'label_required'); end if;
  if length(v_label) > 40 then return jsonb_build_object('ok', false, 'error', 'label_too_long'); end if;
  if exists (select 1 from public.problem_reasons where org_id = p_org and archived_at is null
             and lower(label) = lower(v_label) and id is distinct from v_id) then
    return jsonb_build_object('ok', false, 'error', 'duplicate_label');
  end if;
  if v_id is null then
    insert into public.problem_reasons (org_id, label, blocks_checkout, sort_order)
    values (p_org, v_label, coalesce((p->>'blocks_checkout')::boolean, false),
            coalesce((p->>'sort_order')::int, (select coalesce(max(sort_order), 0) + 1 from public.problem_reasons where org_id = p_org)))
    returning id into v_id;
  else
    update public.problem_reasons set label = v_label,
           blocks_checkout = coalesce((p->>'blocks_checkout')::boolean, blocks_checkout),
           sort_order = coalesce((p->>'sort_order')::int, sort_order)
     where id = v_id and org_id = p_org and archived_at is null;
    if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  end if;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

create function public.remove_problem_reason(p_reason uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_org uuid;
begin
  select org_id into v_org from public.problem_reasons where id = p_reason;
  if v_org is null or not private.has_org_role(v_org, 'admin') then raise exception 'not allowed' using errcode = '42501'; end if;
  update public.problem_reasons set archived_at = now() where id = p_reason and archived_at is null;
  return jsonb_build_object('ok', true);
end $$;

-- Station: anyone with a badge. Safe to call again with the same p_client_report_id.
create function public.station_report_problem(
  p_device_key text, p_client_report_id uuid, p_badge_uid text, p_equipment_uid text, p_reason uuid,
  p_occurred_at timestamptz default null, p_notes text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.stations; v_emp uuid; v_eq uuid; p public.equipment_problems;
begin
  s := private.station_from_key(p_device_key);
  if s.id is null then return private.station_denied(p_device_key); end if;
  if p_client_report_id is null then return jsonb_build_object('ok', false, 'error', 'missing_client_report_id'); end if;
  update public.stations set last_seen_at = now() where id = s.id;
  select * into p from public.equipment_problems where station_id = s.id and client_report_id = p_client_report_id;
  if found then return jsonb_build_object('ok', true, 'duplicate', true, 'id', p.id, 'reason', p.reason, 'blocks_checkout', p.blocks_checkout); end if;
  select id into v_emp from public.employees where org_id = s.org_id and active and badge_uid = private.normalize_uid(p_badge_uid);
  if v_emp is null then return jsonb_build_object('ok', false, 'error', 'unknown_badge'); end if;
  select id into v_eq from public.equipment where org_id = s.org_id and nfc_uid = private.normalize_uid(p_equipment_uid);
  if v_eq is null then return jsonb_build_object('ok', false, 'error', 'unknown_equipment'); end if;
  return private.add_problem(s.org_id, v_eq, p_reason, p_notes, v_emp, null, s.id, p_client_report_id, p_occurred_at);
end $$;

-- Station: a manager or admin fob clears every open problem on the item.
create function public.station_clear_problem(p_device_key text, p_badge_uid text, p_pin text, p_equipment_uid text, p_notes text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare ss jsonb; eq public.equipment; n int;
begin
  ss := private.staff_session(p_device_key, p_badge_uid, p_pin, 'manager');
  if not (ss->>'ok')::boolean then return ss; end if;
  select * into eq from public.equipment where org_id = (ss->>'org_id')::uuid and nfc_uid = private.normalize_uid(p_equipment_uid);
  if not found then return jsonb_build_object('ok', false, 'error', 'unknown_equipment'); end if;
  update public.equipment_problems set cleared_at = now(), cleared_by_employee = (ss->'staff'->>'id')::uuid,
         clear_notes = nullif(left(trim(p_notes), 500), '')
   where equipment_id = eq.id and cleared_at is null;
  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'cleared', n, 'equipment', jsonb_build_object('id', eq.id, 'name', eq.name));
end $$;

alter table public.problem_reasons enable row level security;
alter table public.equipment_problems enable row level security;
create policy problem_reasons_select on public.problem_reasons for select to authenticated using (private.has_org_role(org_id));
create policy equipment_problems_select on public.equipment_problems for select to authenticated using (private.has_org_role(org_id));
revoke insert, update, delete on public.problem_reasons, public.equipment_problems from anon, authenticated;

-- ---------------------------------------------------------------------
-- Checkout rules, station lists: now aware of problems
-- ---------------------------------------------------------------------
create or replace function private.record_event(
  p_org           uuid,
  p_equipment     uuid,
  p_employee      uuid,
  p_action        public.txn_action,   -- null = decide automatically
  p_occurred_at   timestamptz,
  p_source        public.txn_source,
  p_station       uuid default null,
  p_client_txn_id uuid default null,
  p_recorded_by   uuid default null,
  p_notes         text default null,
  -- true = apply the company's checkout rules and refuse what they don't allow
  -- (a live tap at a station). false = record what physically happened
  -- (a tap a station saved while offline, or a supervisor's correction).
  p_enforce       boolean default false
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  eq        public.equipment;
  org       public.organizations;
  v_action  public.txn_action := p_action;
  v_when    timestamptz := coalesce(p_occurred_at, now());
  v_flags   text[] := '{}';
  v_is_latest boolean;
  v_hours   numeric;
  v_rule    text;
  v_txn     uuid;
  v_due     timestamptz;
  v_allow_return_other boolean;
  v_allow_take_held    boolean;
  v_block   text;
begin
  -- Lock the item so two stations tapping the same item at once are serialized.
  select * into eq from public.equipment where id = p_equipment and org_id = p_org for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'unknown_equipment');
  end if;
  select * into org from public.organizations where id = p_org;
  v_allow_return_other := coalesce((org.settings->>'allow_return_by_other')::boolean, true);
  v_allow_take_held    := coalesce((org.settings->>'allow_checkout_while_held')::boolean, false);

  -- Station clocks drift. Don't accept events "from the future".
  if v_when > now() + interval '5 minutes' then
    v_flags := array_append(v_flags, 'clock_skew');
    v_when := now();
  end if;

  v_is_latest := eq.last_event_at is null or v_when >= eq.last_event_at;

  -- Kiosk flow: what does tapping this item mean?
  --   lost item            -> return it (found)
  --   I have it            -> return it
  --   someone else has it  -> return it for them (if the company allows), otherwise a checkout attempt
  --   it's in the room     -> check it out
  if v_action is null then
    v_action := case
      when eq.status = 'lost' then 'checkin'
      when eq.current_employee_id = p_employee then 'checkin'
      when eq.current_employee_id is not null and v_allow_return_other then 'checkin'
      else 'checkout' end;
  end if;

  -- Company rules for live taps. Refused taps aren't recorded; the station explains why.
  if p_enforce and v_is_latest then
    if v_action = 'checkout' then
      v_block := case
        when eq.status in ('maintenance', 'retired') then 'item_unavailable'
        when eq.status = 'lost' then 'item_lost'
        when exists (select 1 from public.equipment_problems p where p.equipment_id = eq.id
                       and p.cleared_at is null and p.blocks_checkout) then 'item_has_problem'
        when eq.current_employee_id is not null and eq.current_employee_id <> p_employee
             and not v_allow_take_held then 'checked_out_to_other' end;
    elsif eq.current_employee_id is not null and eq.current_employee_id <> p_employee
          and not v_allow_return_other and eq.status <> 'lost' then
      v_block := 'not_your_item';
    end if;
    if v_block is not null then
      return jsonb_build_object(
        'ok', false, 'error', v_block,
        'equipment', jsonb_build_object('id', eq.id, 'name', eq.name, 'status', eq.status),
        'holder', (select jsonb_build_object('id', e.id, 'name', trim(e.first_name || ' ' || e.last_name))
                   from public.employees e where e.id = eq.current_employee_id),
        'checked_out_at', eq.checked_out_at, 'due_at', eq.due_at,
        'problem', private.open_problem(eq.id));
    end if;
  end if;

  if not v_is_latest then
    -- An older event uploaded after newer ones (offline station catching up).
    -- Keep it in history, but don't let it overwrite current custody.
    v_flags := array_append(v_flags, 'late_sync');
  else
    if v_action = 'checkout' then
      if eq.current_employee_id is not null and eq.current_employee_id <> p_employee then
        v_flags := array_append(v_flags, 'conflict_already_held');  -- previous holder never returned it
      end if;
      if eq.status in ('maintenance', 'retired', 'lost') then
        v_flags := array_append(v_flags, 'item_' || eq.status::text);
      end if;
      if exists (select 1 from public.equipment_problems p where p.equipment_id = eq.id and p.cleared_at is null and p.blocks_checkout) then
        v_flags := array_append(v_flags, 'reported_problem');   -- recorded anyway (offline tap or supervisor correction)
      end if;

      -- Work out when it's due.
      select l.rule, l.hours into v_rule, v_hours
        from (select 1) one
        left join public.equipment_categories c on c.id = eq.category_id
        cross join lateral private.resolve_time_limit(eq.time_limit_mode, eq.checkout_hours,
                                                      c.time_limit_type, c.default_checkout_hours) l;
      if v_rule = 'shift_end' then
        v_due := private.employee_shift_end(p_employee, v_when);
        if v_due is null then
          -- Not on a shift right now: fall back to hours if any are set.
          v_flags := array_append(v_flags, 'no_active_shift');
          v_rule := case when v_hours is not null then 'hours' else 'none' end;
        end if;
      end if;
      if v_rule = 'hours' then
        v_due := v_when + make_interval(secs => v_hours * 3600);
      end if;
    else
      if eq.status = 'lost' then
        v_flags := array_append(v_flags, 'found_lost_item');
      elsif eq.current_employee_id is null then
        v_flags := array_append(v_flags, 'return_not_checked_out');
      elsif eq.current_employee_id <> p_employee then
        v_flags := array_append(v_flags, 'returned_by_other');
      end if;
      -- Was it out longer than the "extended" limit?
      if eq.checked_out_at is not null
         and v_when - eq.checked_out_at > make_interval(secs => private.extended_hours(eq.id) * 3600) then
        v_flags := array_append(v_flags, 'returned_after_extended');
      end if;
    end if;
  end if;

  insert into public.transactions
    (org_id, equipment_id, employee_id, previous_employee_id, station_id, action, source, occurred_at,
     client_txn_id, recorded_by, flags, notes)
  values
    (p_org, p_equipment, p_employee,
     case when v_is_latest then eq.current_employee_id end,   -- unknown for late uploads
     p_station, v_action, p_source, v_when,
     p_client_txn_id, p_recorded_by, v_flags, p_notes)
  returning id into v_txn;

  if v_is_latest then
    if v_action = 'checkout' then
      update public.equipment set
        current_employee_id = p_employee,
        checked_out_at      = v_when,
        due_at              = v_due,
        status              = case when status in ('available', 'checked_out') then 'checked_out' else status end,
        last_event_at       = v_when
      where id = p_equipment;
    else
      update public.equipment set
        current_employee_id = null,
        checked_out_at      = null,
        due_at              = null,
        status              = case when status in ('checked_out', 'lost') then 'available' else status end,
        last_event_at       = v_when
      where id = p_equipment;
    end if;
    -- Any open alerts were about the previous checkout; this event ends them.
    update public.equipment_alerts set resolved_at = v_when
     where equipment_id = p_equipment and resolved_at is null;
  end if;

  return jsonb_build_object(
    'ok', true,
    'transaction_id', v_txn,
    'action', v_action,
    'flags', to_jsonb(v_flags),
    'equipment', jsonb_build_object('id', eq.id, 'name', eq.name),
    'employee',  (select jsonb_build_object('id', e.id, 'name', trim(e.first_name || ' ' || e.last_name))
                  from public.employees e where e.id = p_employee),
    'previous_holder', case when v_is_latest and eq.current_employee_id is distinct from p_employee then
                  (select jsonb_build_object('id', e.id, 'name', trim(e.first_name || ' ' || e.last_name))
                   from public.employees e where e.id = eq.current_employee_id) end,
    'due_at', v_due,
    'due_rule', v_rule   -- 'hours' | 'shift_end' | 'none' — lets the station say "Due at end of your shift"
  );
end $$;

create or replace function public.station_sync_cache(p_device_key text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare s public.stations;
begin
  s := private.station_from_key(p_device_key);
  if s.id is null then return private.station_denied(p_device_key); end if;
  return jsonb_build_object(
    'ok', true,
    'generated_at', now(),
    'employees', coalesce((select jsonb_agg(jsonb_build_object(
                    'id', e.id, 'badge_uid', e.badge_uid,
                    'name', trim(e.first_name || ' ' || e.last_name),
                    'role', e.station_role,
                    'has_pin', exists (select 1 from private.staff_pins p where p.employee_id = e.id)))
                  from public.employees e
                  where e.org_id = s.org_id and e.active and e.badge_uid is not null), '[]'::jsonb),
    'equipment', coalesce((select jsonb_agg(jsonb_build_object(
                    'id', e.id, 'nfc_uid', e.nfc_uid, 'name', e.name,
                    'category_id', e.category_id, 'status', e.status,
                    'current_employee_id', e.current_employee_id,
                    'checked_out_at', e.checked_out_at, 'due_at', e.due_at,
                    'extended_alert_hours', private.extended_hours(e.id),
                    'problem', private.open_problem(e.id)))
                  from public.equipment e
                  where e.org_id = s.org_id and e.nfc_uid is not null and e.status <> 'retired'), '[]'::jsonb)
  );
end $$;

create or replace function public.station_config(p_device_key text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare s public.stations; o public.organizations;
begin
  s := private.station_from_key(p_device_key);
  if s.id is null then return private.station_denied(p_device_key); end if;
  select * into o from public.organizations where id = s.org_id;
  return jsonb_build_object(
    'ok', true,
    'station', jsonb_build_object('id', s.id, 'name', s.name,
                 'location', (select name from public.locations where id = s.location_id)),
    'organization', jsonb_build_object(
      'name', o.name, 'logo_url', o.logo_url,
      'primary_color', o.primary_color, 'accent_color', o.accent_color,
      'timezone', o.timezone, 'terminology', o.terminology,
      'settings', o.settings, 'enabled_modules', to_jsonb(o.enabled_modules)),
    'categories', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'icon', icon)
                              order by sort_order, name)
                            from public.equipment_categories where org_id = s.org_id), '[]'::jsonb),
    'problem_reasons', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'label', label, 'blocks_checkout', blocks_checkout)
                              order by sort_order, label)
                            from public.problem_reasons where org_id = s.org_id and archived_at is null), '[]'::jsonb)
  );
end $$;

create or replace function public.station_item_status(p_device_key text, p_equipment_uid text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare s public.stations; eq public.equipment;
begin
  s := private.station_from_key(p_device_key);
  if s.id is null then return private.station_denied(p_device_key); end if;
  select * into eq from public.equipment
   where org_id = s.org_id and nfc_uid = private.normalize_uid(p_equipment_uid);
  if not found then return jsonb_build_object('ok', false, 'error', 'unknown_equipment'); end if;
  return jsonb_build_object(
    'ok', true,
    'equipment', jsonb_build_object('id', eq.id, 'name', eq.name, 'status', eq.status,
                   'category', (select name from public.equipment_categories where id = eq.category_id)),
    'holder', (select jsonb_build_object('id', e.id, 'name', trim(e.first_name || ' ' || e.last_name))
               from public.employees e where e.id = eq.current_employee_id),
    'checked_out_at', eq.checked_out_at,
    'due_at', eq.due_at,
    'is_overdue', eq.due_at is not null and eq.due_at < now(),
    'problem', private.open_problem(eq.id));
end $$;

-- =====================================================================
-- Email alerts
-- =====================================================================
create table private.app_settings (key text primary key, value text not null);
insert into private.app_settings values
  ('email_from', 'Sonoran Point <alerts@sonoranpoint.com>'),
  ('app_url', 'https://app.sonoranpoint.com')
on conflict do nothing;

-- What each dashboard user gets emailed about, per company.
--   problem       an item was reported (damaged, not charging, ...)
--   overdue       an item wasn't back by its due time
--   extended      an item has been out longer than the "out too long" limit
--   shift_report  a shift ended with items not back on time
create table public.notification_prefs (
  org_id     uuid not null,
  user_id    uuid not null,
  kinds      text[] not null default '{}' check (kinds <@ array['problem', 'overdue', 'extended', 'shift_report']),
  updated_at timestamptz not null default now(),
  primary key (org_id, user_id),
  foreign key (org_id, user_id) references public.org_members(org_id, user_id) on delete cascade
);
alter table public.notification_prefs enable row level security;
create policy notification_prefs_select on public.notification_prefs for select to authenticated
  using (user_id = auth.uid() or private.has_org_role(org_id, 'admin'));
revoke insert, update, delete on public.notification_prefs from anon, authenticated;

create function private.member_default_prefs()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.notification_prefs (org_id, user_id, kinds)
  values (new.org_id, new.user_id, case when new.role >= 'admin' then array['problem'] else '{}'::text[] end)
  on conflict do nothing;
  return null;
end $$;
create trigger member_default_prefs after insert on public.org_members for each row execute function private.member_default_prefs();
insert into public.notification_prefs (org_id, user_id, kinds)
select org_id, user_id, case when role >= 'admin' then array['problem'] else '{}'::text[] end from public.org_members
on conflict do nothing;

-- You can change your own; admins can change anyone's in their company.
create function public.set_email_alerts(p_org uuid, p_user uuid, p_kinds text[])
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not (p_user = auth.uid() and private.has_org_role(p_org)) and not private.has_org_role(p_org, 'admin') then
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
end $$;

-- One row per person per thing that happened; grouped into one email per person.
create table private.email_queue (
  id         bigint generated always as identity primary key,
  org_id     uuid not null references public.organizations(id) on delete cascade,
  user_id    uuid,
  to_email   text not null,
  kind       text not null,
  title      text not null,     -- "Radio 03: Damaged"
  detail     text,              -- "Reported by Alex Rivera at Equipment Room 01."
  link       text,              -- dashboard page, e.g. #equipment
  created_at timestamptz not null default now(),
  batch_id   bigint
);
create index on private.email_queue (created_at) where batch_id is null;

create table private.email_batches (
  id          bigint generated always as identity primary key,
  org_id      uuid,
  to_email    text not null,
  subject     text not null,
  html        text not null,
  body_text   text not null,
  created_at  timestamptz not null default now(),
  request_id  bigint,           -- pg_net request
  posted_at   timestamptz,
  status      text not null default 'queued' check (status in ('queued', 'posted', 'sent', 'failed')),
  error       text
);

create function private.enqueue_email(p_org uuid, p_kind text, p_title text, p_detail text, p_link text)
returns void language sql security definer set search_path = public as $$
  insert into private.email_queue (org_id, user_id, to_email, kind, title, detail, link)
  select p_org, u.id, u.email, p_kind, p_title, p_detail, p_link
  from public.notification_prefs n
  join public.org_members m on m.org_id = n.org_id and m.user_id = n.user_id
  join auth.users u on u.id = n.user_id
  where n.org_id = p_org and p_kind = any (n.kinds) and coalesce(u.email, '') like '%@%';
$$;

create function private.emp_name(p_emp uuid) returns text language sql stable security definer set search_path = public as $$
  select trim(first_name || ' ' || last_name) from public.employees where id = p_emp
$$;

create function private.email_on_problem()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_item text; v_station text; v_by text;
begin
  select name into v_item from public.equipment where id = new.equipment_id;
  select name into v_station from public.stations where id = new.station_id;
  v_by := coalesce(private.emp_name(new.reported_by_employee),
                   (select coalesce(nullif(raw_user_meta_data->>'full_name', ''), email) from auth.users where id = new.reported_by_user));
  perform private.enqueue_email(new.org_id, 'problem', v_item || ': ' || new.reason,
    'Reported' || coalesce(' by ' || v_by, '') || coalesce(' at ' || v_station, '') || '.'
      || case when new.blocks_checkout then ' It can''t be checked out until a supervisor clears it.' else '' end
      || coalesce(' Note: "' || new.notes || '"', ''),
    '#equipment');
  return null;
end $$;
create trigger email_on_problem after insert on public.equipment_problems for each row execute function private.email_on_problem();

create function private.email_on_alert()
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
    '#alerts');
  return null;
end $$;
create trigger email_on_alert after insert on public.equipment_alerts for each row execute function private.email_on_alert();

create function private.email_on_shift_report()
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
    '#shifts');
  return null;
end $$;
create trigger email_on_shift_report after insert on public.shift_reports for each row execute function private.email_on_shift_report();

create function private.html_esc(t text) returns text language sql immutable as $$
  select replace(replace(replace(replace(coalesce(t, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;')
$$;

-- Group waiting rows into one email per person per company.
create function private.build_email_batches()
returns int language plpgsql security definer set search_path = public as $$
declare g record; v_id bigint; n int := 0; v_url text; v_org text; rows_html text; rows_text text; v_subject text;
begin
  select value into v_url from private.app_settings where key = 'app_url';
  for g in
    select org_id, to_email, array_agg(id order by created_at) ids, count(*) cnt
    from private.email_queue where batch_id is null group by org_id, to_email
  loop
    select name into v_org from public.organizations where id = g.org_id;
    select string_agg(format('<tr><td style="padding:12px 0;border-top:1px solid #e3e8ef"><a href="%s/%s" style="color:#121a24;font-weight:700;text-decoration:none">%s</a><div style="color:#5b6878;font-size:14px;margin-top:2px">%s</div></td></tr>',
                             v_url, coalesce(q.link, ''), private.html_esc(q.title), private.html_esc(q.detail)), '' order by q.created_at),
           string_agg(q.title || E'\n' || coalesce(q.detail, '') || E'\n', E'\n' order by q.created_at),
           min(q.title)
      into rows_html, rows_text, v_subject
    from private.email_queue q where q.id = any (g.ids);
    if g.cnt > 1 then v_subject := g.cnt || ' equipment alerts at ' || v_org; end if;
    insert into private.email_batches (org_id, to_email, subject, html, body_text)
    values (g.org_id, g.to_email, v_subject,
      format('<div style="font-family:Arial,Helvetica,sans-serif;max-width:560px;margin:0 auto;color:#121a24">'
        || '<p style="font-size:13px;color:#5b6878;margin:0 0 4px">%s</p><h1 style="font-size:20px;margin:0 0 8px">%s</h1>'
        || '<table style="width:100%%;border-collapse:collapse">%s</table>'
        || '<p style="margin:20px 0"><a href="%s" style="background:#1d5fd1;color:#fff;padding:10px 16px;border-radius:8px;text-decoration:none;font-weight:700">Open the dashboard</a></p>'
        || '<p style="font-size:12px;color:#8592a3">You get these emails because of your alert settings. Change them in the dashboard under Settings, Email alerts.</p></div>',
        private.html_esc(v_org), case when g.cnt > 1 then g.cnt || ' things need a look' else 'Something needs a look' end, rows_html, v_url),
      v_org || E'\n\n' || rows_text || E'\nOpen the dashboard: ' || v_url
        || E'\n\nYou get these emails because of your alert settings. Change them in the dashboard under Settings, Email alerts.')
    returning id into v_id;
    update private.email_queue set batch_id = v_id where id = any (g.ids);
    n := n + 1;
  end loop;
  return n;
end $$;

-- Build batches, send them through Resend, and record how earlier sends went.
-- Runs every minute. Does nothing beyond building batches until pg_net is on and
-- the Resend key is in Vault (name: resend_api_key).
create function private.send_emails()
returns int language plpgsql security definer set search_path = public as $$
declare v_key text; v_from text; b record; v_req bigint; n int := 0;
begin
  perform private.build_email_batches();
  if not exists (select 1 from pg_extension where extname = 'pg_net')
     or not exists (select 1 from pg_namespace where nspname = 'vault') then
    return 0;
  end if;
  execute $q$select decrypted_secret from vault.decrypted_secrets where name = 'resend_api_key' limit 1$q$ into v_key;
  if v_key is null then return 0; end if;
  select value into v_from from private.app_settings where key = 'email_from';

  -- Results of earlier sends
  execute $q$
    update private.email_batches b set
      status = case when r.status_code between 200 and 299 then 'sent' else 'failed' end,
      error  = case when r.status_code between 200 and 299 then null else coalesce(r.error_msg, left(r.content::text, 500)) end
    from net._http_response r
    where r.id = b.request_id and b.status = 'posted' and (r.status_code is not null or r.error_msg is not null)$q$;

  -- Don't send a backlog of stale alerts (say, everything queued before email was set up).
  update private.email_batches set status = 'failed', error = 'not sent: more than a day old'
   where status = 'queued' and created_at < now() - interval '1 day';

  for b in select * from private.email_batches where status = 'queued' order by id limit 50 loop
    execute $q$select net.http_post(
        url := 'https://api.resend.com/emails',
        headers := jsonb_build_object('Authorization', 'Bearer ' || $1, 'Content-Type', 'application/json'),
        body := jsonb_build_object('from', $2, 'to', jsonb_build_array($3), 'subject', $4, 'html', $5, 'text', $6))$q$
      into v_req using v_key, v_from, b.to_email, b.subject, b.html, b.body_text;
    update private.email_batches set request_id = v_req, posted_at = now(), status = 'posted' where id = b.id;
    n := n + 1;
  end loop;
  return n;
end $$;

do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_net') then
    execute 'create extension if not exists pg_net';
  end if;
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    execute 'create extension if not exists pg_cron';
    execute $q$select cron.schedule('send-emails', '* * * * *', 'select private.send_emails()')$q$;
  else
    raise notice 'pg_cron not available: call private.send_emails() every minute another way';
  end if;
end $$;

-- =====================================================================
-- Permissions
-- =====================================================================
revoke execute on all functions in schema private from public, anon, authenticated;
grant  execute on function private.has_org_role(uuid, public.member_role) to authenticated;
grant  execute on function private.normalize_uid(text) to anon, authenticated;
grant  execute on function private.resolve_time_limit(public.time_limit_mode, numeric, public.time_limit_type, numeric) to authenticated;
grant  execute on function private.can_manage_logo(text) to authenticated;

revoke execute on function
  public.report_problem(uuid, uuid, text), public.clear_problem(uuid, text),
  public.save_problem_reason(uuid, jsonb), public.remove_problem_reason(uuid),
  public.set_email_alerts(uuid, uuid, text[]),
  public.station_report_problem(text, uuid, text, text, uuid, timestamptz, text),
  public.station_clear_problem(text, text, text, text, text)
from public;
grant execute on function
  public.report_problem(uuid, uuid, text), public.clear_problem(uuid, text),
  public.save_problem_reason(uuid, jsonb), public.remove_problem_reason(uuid),
  public.set_email_alerts(uuid, uuid, text[])
to authenticated;
grant execute on function
  public.station_report_problem(text, uuid, text, text, uuid, timestamptz, text),
  public.station_clear_problem(text, text, text, text, text)
to anon, authenticated;
