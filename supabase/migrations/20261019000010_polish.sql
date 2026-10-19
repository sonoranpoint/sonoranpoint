-- =====================================================================
-- Polish, part 1
--   1. The console's customer page shows each team member's name (not just email).
--   2. Logo uploads: a public "logos" bucket in Supabase Storage. A company's
--      admins (and you) can upload into their company's folder: logos/<org id>/...
--      The dashboard and console turn every upload into a PNG first, so no SVG
--      (which can carry scripts) is ever stored.
-- =====================================================================

-- 1. Member names on the console's customer page
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
        'code_expires_at', k.activation_expires_at, 'created_at', s.created_at) order by s.created_at)
      from public.stations s left join public.locations l on l.id = s.location_id
      left join private.station_keys k on k.station_id = s.id where s.org_id = p_org), '[]'::jsonb),
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

-- True when the signed-in person may change this company's logo.
create or replace function private.can_manage_logo(p_folder text)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare v_org uuid;
begin
  begin v_org := p_folder::uuid; exception when others then return false; end;
  return private.has_org_role(v_org, 'admin') or private.is_platform_operator();
end $$;
revoke execute on function private.can_manage_logo(text) from public, anon;
grant execute on function private.can_manage_logo(text) to authenticated;

-- 2. Logo storage (skipped where Supabase Storage isn't installed, like the test database)
do $do$
begin
  if not exists (select 1 from pg_namespace where nspname = 'storage') then
    raise notice 'storage schema not found: skipping the logos bucket';
    return;
  end if;
  insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('logos', 'logos', true, 1048576, array['image/png', 'image/jpeg', 'image/webp'])
  on conflict (id) do update set public = true, file_size_limit = 1048576, allowed_mime_types = array['image/png', 'image/jpeg', 'image/webp'];

  -- Who may write into logos/<org id>/: that company's admins and owners, and platform operators.
  execute $p$drop policy if exists logos_insert on storage.objects$p$;
  execute $p$drop policy if exists logos_update on storage.objects$p$;
  execute $p$drop policy if exists logos_delete on storage.objects$p$;
  execute $p$create policy logos_insert on storage.objects for insert to authenticated
    with check (bucket_id = 'logos' and private.can_manage_logo((storage.foldername(name))[1]))$p$;
  execute $p$create policy logos_update on storage.objects for update to authenticated
    using (bucket_id = 'logos' and private.can_manage_logo((storage.foldername(name))[1]))
    with check (bucket_id = 'logos' and private.can_manage_logo((storage.foldername(name))[1]))$p$;
  execute $p$create policy logos_delete on storage.objects for delete to authenticated
    using (bucket_id = 'logos' and private.can_manage_logo((storage.foldername(name))[1]))$p$;
end
$do$;
