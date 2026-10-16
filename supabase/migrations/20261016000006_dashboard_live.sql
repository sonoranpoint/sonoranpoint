-- =====================================================================
-- Small helpers the live dashboard needs.
-- =====================================================================

-- Which employees have a station PIN set (PINs themselves stay unreadable).
create function public.dashboard_pin_holders(p_org uuid)
returns uuid[] language plpgsql stable security definer set search_path = public as $$
begin
  if not private.has_org_role(p_org, 'supervisor') then raise exception 'not allowed' using errcode = '42501'; end if;
  return coalesce((select array_agg(p.employee_id) from private.staff_pins p
                   join public.employees e on e.id = p.employee_id where e.org_id = p_org), '{}');
end $$;

-- The companies the signed-in person belongs to, with their role.
create function public.my_companies()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('org_id', o.id, 'name', o.name, 'role', m.role) order by o.name), '[]'::jsonb)
  from public.org_members m join public.organizations o on o.id = m.org_id
  where m.user_id = auth.uid()
$$;

revoke execute on function public.dashboard_pin_holders(uuid), public.my_companies() from public;
grant  execute on function public.dashboard_pin_holders(uuid), public.my_companies() to authenticated;

-- Fleet: also say when each station was created (how long a shipped box has waited for setup).
create or replace function public.platform_fleet()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform private.require_operator();
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', s.id, 'name', s.name, 'org_id', o.id, 'customer', o.name, 'customer_status', o.status, 'location', l.name,
      'activated_at', s.activated_at, 'last_seen_at', s.last_seen_at, 'software_version', s.software_version,
      'admin_claimed_at', s.admin_claimed_at, 'code_expires_at', k.activation_expires_at, 'created_at', s.created_at,
      'online', s.activated_at is not null and s.last_seen_at > now() - interval '5 minutes')
      order by o.name, s.name)
    from public.stations s join public.organizations o on o.id = s.org_id
    left join public.locations l on l.id = s.location_id left join private.station_keys k on k.station_id = s.id
    where s.revoked_at is null), '[]'::jsonb);
end $$;
