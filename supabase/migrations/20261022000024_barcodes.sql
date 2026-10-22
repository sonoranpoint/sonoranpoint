-- =====================================================================
-- 24: Barcodes
--   Badges and items can have a barcode (what's printed on an existing badge or asset tag) as well
--   as, or instead of, an NFC tag. A handheld scanner (wired or wireless) plugged into the station
--   types it in, and the station treats the scan like a tap.
--   * employees.barcode, equipment.barcode: as printed (trimmed, upper case), unique within a company.
--   * Something with a barcode but no NFC tag gets a tag ID made from the barcode ("B0C0DE" + the
--     barcode's bytes in hex), so every station function works with it unchanged. The station makes the
--     same ID from a scan when it can't match the barcode in its saved lists.
-- =====================================================================
alter table public.employees add column barcode text check (barcode is null or length(barcode) between 1 and 40);
alter table public.equipment add column barcode text check (barcode is null or length(barcode) between 1 and 40);
create unique index employees_barcode on public.employees (org_id, barcode) where barcode is not null;
create unique index equipment_barcode on public.equipment (org_id, barcode) where barcode is not null;
grant insert (barcode), update (barcode) on public.employees to authenticated;
grant insert (barcode), update (barcode) on public.equipment to authenticated;

create function private.barcode_uid(p_code text)
returns text language sql immutable as $$
  select case when nullif(upper(trim(p_code)), '') is null then null
              else 'B0C0DE' || upper(encode(convert_to(upper(trim(p_code)), 'UTF8'), 'hex')) end
$$;
-- The barcode a made-up tag ID stands for (null for a real NFC tag).
create function private.uid_barcode(p_uid text)
returns text language plpgsql immutable as $$
declare t text;
begin
  if p_uid is null or p_uid !~ '^B0C0DE([0-9A-F]{2})+$' then return null; end if;
  begin t := convert_from(decode(substr(p_uid, 7), 'hex'), 'UTF8'); exception when others then return null; end;
  return case when t ~ '^[[:print:]]+$' then t end;
end $$;

create function private.barcode_columns()
returns trigger language plpgsql security definer set search_path = public as $$
declare uid text; old_uid text; old_code text;
begin
  new.barcode := nullif(upper(trim(new.barcode)), '');
  if tg_table_name = 'employees' then uid := private.normalize_uid(new.badge_uid); else uid := private.normalize_uid(new.nfc_uid); end if;
  if tg_op = 'UPDATE' then
    old_code := old.barcode;
    if tg_table_name = 'employees' then old_uid := old.badge_uid; else old_uid := old.nfc_uid; end if;
  end if;
  -- A tag ID made from the old barcode follows the barcode when it changes (or goes when it's cleared).
  if uid is not null and old_code is distinct from new.barcode and uid = private.barcode_uid(old_code) and uid is not distinct from old_uid then
    uid := private.barcode_uid(new.barcode);
  elsif uid is null and new.barcode is not null then
    uid := private.barcode_uid(new.barcode);
  elsif new.barcode is null and private.uid_barcode(uid) is not null then
    new.barcode := private.uid_barcode(uid);    -- registered at a station by scanning
  end if;
  if tg_table_name = 'employees' then new.badge_uid := uid; else new.nfc_uid := uid; end if;
  return new;
end $$;
create trigger barcode_columns before insert or update on public.employees for each row execute function private.barcode_columns();
create trigger barcode_columns before insert or update on public.equipment for each row execute function private.barcode_columns();

-- Stations get the barcodes too, to match scans offline.
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
    -- Contracts this station serves (null = every one): lets it apply the same rules offline.
    'reach', case when s.contract_id is null then null else
               coalesce((select jsonb_agg(c.id) from public.contracts c where c.org_id = s.org_id and private.contracts_share(s.org_id, s.contract_id, c.id)), '[]'::jsonb) end,
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

revoke execute on all functions in schema private from public, anon, authenticated;
grant  execute on function private.has_org_role(uuid, public.member_role) to authenticated;
grant  execute on function private.normalize_uid(text) to anon, authenticated;
grant  execute on function private.resolve_time_limit(public.time_limit_mode, numeric, public.time_limit_type, numeric) to authenticated;
grant  execute on function private.can_manage_logo(text) to authenticated;
grant  execute on function private.can_see(uuid, uuid), private.can_see_equipment(uuid), private.can_see_txn(uuid, uuid, uuid, uuid),
  private.can_see_tap(uuid, uuid, uuid, uuid), private.sees(uuid, uuid, uuid), private.scope_of(uuid, uuid) to authenticated;
