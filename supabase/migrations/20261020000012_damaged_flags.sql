-- =====================================================================
-- 12: "Damaged" flags an item instead of blocking it
--   * Checking out an item with an open problem is allowed (unless its reason is set to
--     stop checkout) and the checkout is flagged 'reported_problem'; the station shows the
--     problem so the person can look it over.
--   * New companies start with no reason that stops checkout. Existing "Damaged" reasons
--     are switched to flag-only. Admins can still turn "Stops checkout" on per reason.
-- =====================================================================
create or replace function private.seed_problem_reasons(p_org uuid)
returns void language sql security definer set search_path = public as $$
  insert into public.problem_reasons (org_id, label, blocks_checkout, sort_order) values
    (p_org, 'Damaged', false, 1), (p_org, 'Not charging', false, 2),
    (p_org, 'Missing part', false, 3), (p_org, 'Other', false, 4);
$$;
update public.problem_reasons set blocks_checkout = false where label = 'Damaged' and blocks_checkout;
update public.equipment_problems set blocks_checkout = false where reason = 'Damaged' and cleared_at is null and blocks_checkout;

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
      -- Checked out with a problem still open (damaged, say): allowed unless the reason stops checkout, but flagged.
      if exists (select 1 from public.equipment_problems p where p.equipment_id = eq.id and p.cleared_at is null) then
        v_flags := array_append(v_flags, 'reported_problem');
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
    'due_rule', v_rule,  -- 'hours' | 'shift_end' | 'none' — lets the station say "Due at end of your shift"
    'problem', case when v_action = 'checkout' then private.open_problem(eq.id) end
  );
end $$;

revoke execute on all functions in schema private from public, anon, authenticated;
grant  execute on function private.has_org_role(uuid, public.member_role) to authenticated;
grant  execute on function private.normalize_uid(text) to anon, authenticated;
grant  execute on function private.resolve_time_limit(public.time_limit_mode, numeric, public.time_limit_type, numeric) to authenticated;
grant  execute on function private.can_manage_logo(text) to authenticated;
