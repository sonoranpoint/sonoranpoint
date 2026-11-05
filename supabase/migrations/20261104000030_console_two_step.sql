-- 30: Two-step sign-in (authenticator app) is required for the operator console.
--   Supabase Auth puts "aal": "aal2" in the sign-in token once someone has entered a code from their
--   authenticator app. Every console function (private.require_operator, and the operator side of shared
--   checks like private.is_platform_operator) now needs that. am_platform_operator still answers with a
--   password-only sign-in, so the console knows to ask for the code.
--   Run this only after you've set up your authenticator in the console (it asks the next time you sign in).
--   Lost phone: Supabase dashboard -> Authentication -> Users -> the person -> remove their MFA factor;
--   the console then asks them to set up a new one.

-- True with a two-step sign-in. Also true with no sign-in token at all (the SQL editor, scheduled jobs,
-- database tests), which only someone with database access can do.
create or replace function private.mfa_ok()
returns boolean language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '') = ''
      or (current_setting('request.jwt.claims', true)::jsonb ->> 'aal') = 'aal2'
$$;

create or replace function private.is_platform_member()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from private.platform_operators where user_id = auth.uid())
$$;

create or replace function private.is_platform_operator()
returns boolean language sql stable security definer set search_path = public as $$
  select private.is_platform_member() and private.mfa_ok()
$$;

create or replace function private.require_platform_owner()
returns void language plpgsql stable security definer set search_path = public as $$
begin
  if not exists (select 1 from private.platform_operators where user_id = auth.uid() and role = 'owner') or not private.mfa_ok() then
    raise exception 'not allowed' using errcode = '42501';
  end if;
end $$;

-- The console asks this first; a team member signed in with only a password gets "yes", then the code screen.
create or replace function public.am_platform_operator()
returns boolean language sql stable security definer set search_path = public as $$
  select private.is_platform_member()
$$;

revoke execute on all functions in schema private from public, anon, authenticated;
grant  execute on function private.has_org_role(uuid, public.member_role) to authenticated;
grant  execute on function private.normalize_uid(text) to anon, authenticated;
grant  execute on function private.resolve_time_limit(public.time_limit_mode, numeric, public.time_limit_type, numeric) to authenticated;
grant  execute on function private.can_manage_logo(text) to authenticated;
grant  execute on function private.can_see(uuid, uuid), private.can_see_equipment(uuid), private.can_see_txn(uuid, uuid, uuid, uuid),
  private.can_see_tap(uuid, uuid, uuid, uuid), private.sees(uuid, uuid, uuid), private.scope_of(uuid, uuid) to authenticated;
