-- =====================================================================
-- 18: The console's Stations page also lists disconnected stations (under All),
--     so it matches what the customer sees on their dashboard.
-- =====================================================================
create or replace function public.platform_fleet()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform private.require_operator();
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', s.id, 'name', s.name, 'org_id', o.id, 'customer', o.name, 'customer_status', o.status, 'location', l.name,
      'activated_at', s.activated_at, 'last_seen_at', s.last_seen_at, 'software_version', s.software_version,
      'admin_claimed_at', s.admin_claimed_at, 'code_expires_at', k.activation_expires_at, 'created_at', s.created_at,
      'revoked_at', s.revoked_at, 'contract_id', s.contract_id,
      'online', s.activated_at is not null and s.revoked_at is null and s.last_seen_at > now() - interval '5 minutes')
      order by o.name, s.name)
    from public.stations s join public.organizations o on o.id = s.org_id
    left join public.locations l on l.id = s.location_id left join private.station_keys k on k.station_id = s.id), '[]'::jsonb);
end $$;
