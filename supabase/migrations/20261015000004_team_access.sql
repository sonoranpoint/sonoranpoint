-- =====================================================================
-- Team access: who can sign in to the dashboard, and with which role.
--
--   viewer      sees everything, changes nothing
--   supervisor  + employees, lost/maintenance, alerts, shift sign-off
--   admin       + equipment, categories, stations, settings, team access (not owners)
--   owner       everything, including other owners
--
-- People are invited by email. The API layer emails the invite link
-- (Supabase Auth); accepting only works when signed in with that email.
-- A company always keeps at least one owner.
-- (Dashboard roles are separate from station fobs: employees.station_role.)
-- =====================================================================

create table public.org_invites (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organizations(id) on delete cascade,
  email       text not null check (email = lower(trim(email)) and email like '%_@_%._%'),
  role        public.member_role not null,
  invited_by  uuid references auth.users(id) on delete set null,
  token_hash  text not null unique,
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null default now() + interval '14 days',
  accepted_at timestamptz,
  accepted_by uuid references auth.users(id) on delete set null
);
create unique index org_invites_one_open on public.org_invites (org_id, email) where accepted_at is null;
alter table public.org_invites enable row level security;
create policy invites_select on public.org_invites for select to authenticated using (private.has_org_role(org_id, 'admin'));
revoke insert, update, delete on public.org_invites from anon, authenticated;
create trigger audit_org_invites after insert or update or delete on public.org_invites for each row execute function private.audit();

-- Who may give/change/remove this role? Owners: anything. Admins: anything except owners.
create function private.can_manage_role(p_org uuid, p_role public.member_role)
returns boolean language sql stable security definer set search_path = public as $$
  select private.has_org_role(p_org, 'owner') or (private.has_org_role(p_org, 'admin') and p_role < 'owner')
$$;

create function public.invite_member(p_org uuid, p_email text, p_role public.member_role)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_email text := lower(trim(p_email)); v_token text := encode(extensions.gen_random_bytes(24), 'hex'); v_id uuid;
begin
  if not private.can_manage_role(p_org, p_role) then raise exception 'not allowed' using errcode = '42501'; end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then return jsonb_build_object('ok', false, 'error', 'bad_email'); end if;
  if exists (select 1 from public.org_members m join auth.users u on u.id = m.user_id where m.org_id = p_org and lower(u.email) = v_email) then
    return jsonb_build_object('ok', false, 'error', 'already_member');
  end if;
  delete from public.org_invites where org_id = p_org and email = v_email and accepted_at is null;   -- re-invite replaces
  insert into public.org_invites (org_id, email, role, invited_by, token_hash)
  values (p_org, v_email, p_role, auth.uid(), private.sha256_hex(v_token)) returning id into v_id;
  -- The token goes in the emailed link; only its hash is stored.
  return jsonb_build_object('ok', true, 'invite_id', v_id, 'token', v_token, 'expires_at', now() + interval '14 days');
end $$;

create function public.accept_invite(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare inv public.org_invites; v_email text;
begin
  if auth.uid() is null then return jsonb_build_object('ok', false, 'error', 'not_signed_in'); end if;
  select * into inv from public.org_invites where token_hash = private.sha256_hex(p_token) for update;
  if not found or inv.accepted_at is not null then return jsonb_build_object('ok', false, 'error', 'invalid_invite'); end if;
  if inv.expires_at < now() then return jsonb_build_object('ok', false, 'error', 'invite_expired'); end if;
  select lower(email) into v_email from auth.users where id = auth.uid();
  if v_email is distinct from inv.email then return jsonb_build_object('ok', false, 'error', 'wrong_account', 'invited_email', inv.email); end if;
  insert into public.org_members (org_id, user_id, role) values (inv.org_id, auth.uid(), inv.role)
  on conflict (org_id, user_id) do update set role = greatest(public.org_members.role, excluded.role);
  update public.org_invites set accepted_at = now(), accepted_by = auth.uid() where id = inv.id;
  return jsonb_build_object('ok', true, 'org_id', inv.org_id, 'role', inv.role);
end $$;

-- Team list with emails (auth.users isn't readable from the API), plus open invites. Admins and owners.
create function public.list_members(p_org uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not private.has_org_role(p_org, 'admin') then raise exception 'not allowed' using errcode = '42501'; end if;
  return jsonb_build_object(
    'members', coalesce((select jsonb_agg(jsonb_build_object(
        'user_id', m.user_id, 'email', u.email, 'name', u.raw_user_meta_data->>'full_name', 'role', m.role,
        'joined_at', m.created_at, 'last_sign_in_at', u.last_sign_in_at) order by m.role desc, u.email)
      from public.org_members m join auth.users u on u.id = m.user_id where m.org_id = p_org), '[]'::jsonb),
    'invites', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'email', i.email, 'role', i.role,
        'created_at', i.created_at, 'expires_at', i.expires_at) order by i.created_at desc)
      from public.org_invites i where i.org_id = p_org and i.accepted_at is null and i.expires_at > now()), '[]'::jsonb));
end $$;

create function public.set_member_role(p_org uuid, p_user uuid, p_role public.member_role)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_cur public.member_role;
begin
  select role into v_cur from public.org_members where org_id = p_org and user_id = p_user for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_member'); end if;
  if not private.can_manage_role(p_org, v_cur) or not private.can_manage_role(p_org, p_role) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if v_cur = 'owner' and p_role <> 'owner'
     and (select count(*) from public.org_members where org_id = p_org and role = 'owner') = 1 then
    return jsonb_build_object('ok', false, 'error', 'last_owner');
  end if;
  update public.org_members set role = p_role where org_id = p_org and user_id = p_user;
  return jsonb_build_object('ok', true);
end $$;

create function public.remove_member(p_org uuid, p_user uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_cur public.member_role;
begin
  select role into v_cur from public.org_members where org_id = p_org and user_id = p_user for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_member'); end if;
  if not private.can_manage_role(p_org, v_cur) then raise exception 'not allowed' using errcode = '42501'; end if;
  if v_cur = 'owner' and (select count(*) from public.org_members where org_id = p_org and role = 'owner') = 1 then
    return jsonb_build_object('ok', false, 'error', 'last_owner');
  end if;
  delete from public.org_members where org_id = p_org and user_id = p_user;
  return jsonb_build_object('ok', true);
end $$;

create function public.cancel_invite(p_invite uuid)
returns void language plpgsql security definer set search_path = public as $$
declare inv public.org_invites;
begin
  select * into inv from public.org_invites where id = p_invite;
  if not found or not private.can_manage_role(inv.org_id, inv.role) then raise exception 'not allowed' using errcode = '42501'; end if;
  delete from public.org_invites where id = p_invite and accepted_at is null;
end $$;

-- Categories with no equipment can be deleted (equipment keeps history, so in-use ones can't).
create function public.delete_category(p_category uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_org uuid;
begin
  select org_id into v_org from public.equipment_categories where id = p_category;
  if v_org is null or not private.has_org_role(v_org, 'admin') then raise exception 'not allowed' using errcode = '42501'; end if;
  if exists (select 1 from public.equipment where category_id = p_category) then return jsonb_build_object('ok', false, 'error', 'in_use'); end if;
  delete from public.equipment_categories where id = p_category;
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------
revoke execute on all functions in schema private from public, anon, authenticated;
grant  execute on function private.has_org_role(uuid, public.member_role) to authenticated;
grant  execute on function private.normalize_uid(text) to anon, authenticated;
grant  execute on function private.resolve_time_limit(public.time_limit_mode, numeric, public.time_limit_type, numeric) to authenticated;

revoke execute on function public.invite_member(uuid, text, public.member_role), public.accept_invite(text),
  public.list_members(uuid), public.set_member_role(uuid, uuid, public.member_role), public.remove_member(uuid, uuid),
  public.cancel_invite(uuid), public.delete_category(uuid) from public;
grant execute on function public.invite_member(uuid, text, public.member_role), public.accept_invite(text),
  public.list_members(uuid), public.set_member_role(uuid, uuid, public.member_role), public.remove_member(uuid, uuid),
  public.cancel_invite(uuid), public.delete_category(uuid) to authenticated;
