-- =====================================================================
-- 23: Stations get the company's light logo too
--   The station's top bar follows the logos, like the dashboard menu: their main color with the
--   light logo when they have one, white with their normal logo when they don't.
-- =====================================================================
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
                 'contract', (select jsonb_build_object('id', c.id, 'name', c.name) from public.contracts c where c.id = s.contract_id),
                 'location', (select name from public.locations where id = s.location_id)),
    'organization', jsonb_build_object(
      'name', o.name, 'logo_url', o.logo_url, 'logo_dark_url', o.logo_dark_url,
      'primary_color', o.primary_color, 'accent_color', o.accent_color,
      'timezone', o.timezone, 'terminology', o.terminology,
      'settings', o.settings, 'enabled_modules', to_jsonb(o.enabled_modules)),
    'categories', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'icon', icon)
                              order by sort_order, name)
                            from public.equipment_categories where org_id = s.org_id), '[]'::jsonb),
    'contracts', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'parent_id', parent_id) order by sort_order, name)
                            from public.contracts where org_id = s.org_id), '[]'::jsonb),
    'problem_reasons', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'label', label, 'blocks_checkout', blocks_checkout)
                              order by sort_order, label)
                            from public.problem_reasons where org_id = s.org_id and archived_at is null), '[]'::jsonb)
  );
end $$;

revoke execute on all functions in schema private from public, anon, authenticated;
grant  execute on function private.has_org_role(uuid, public.member_role) to authenticated;
grant  execute on function private.normalize_uid(text) to anon, authenticated;
grant  execute on function private.resolve_time_limit(public.time_limit_mode, numeric, public.time_limit_type, numeric) to authenticated;
grant  execute on function private.can_manage_logo(text) to authenticated;
grant  execute on function private.can_see(uuid, uuid), private.can_see_equipment(uuid), private.can_see_txn(uuid, uuid, uuid, uuid),
  private.can_see_tap(uuid, uuid, uuid, uuid), private.sees(uuid, uuid, uuid), private.scope_of(uuid, uuid) to authenticated;
