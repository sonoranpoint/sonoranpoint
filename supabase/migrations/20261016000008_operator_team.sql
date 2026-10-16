-- =====================================================================
-- Your team in the operator console.
--
--   owner     everything, including adding/removing operators and changing roles
--   operator  everything except managing the operator team
--
-- Operators are invited by email (the console emails a sign-in link that
-- accepts the invite). Everyone sets their own display name, which is what the
-- activity log shows. There's always at least one owner.
-- =====================================================================
alter table private.platform_operators add column role text not null default 'operator' check (role in ('owner', 'operator'));
update private.platform_operators set role = 'owner';                -- whoever is here now set it up

create table private.platform_invites (
  id          uuid primary key default gen_random_uuid(),
  email       text not null check (email = lower(trim(email))),
  name        text,
  role        text not null check (role in ('owner', 'operator')),
  token_hash  text not null unique,
  invited_by  uuid references auth.users(id) on delete set null,
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null default now() + interval '14 days',
  accepted_at timestamptz
);
create unique index platform_invites_one_open on private.platform_invites (email) where accepted_at is null;
alter table private.platform_invites enable row level security;
revoke all on private.platform_invites from public, anon, authenticated;

create function private.require_platform_owner()
returns void language plpgsql stable security definer set search_path = public as $$
begin
  if not exists (select 1 from private.platform_operators where user_id = auth.uid() and role = 'owner') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
end $$;

-- Who am I in the console?
create function public.platform_me()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce((select jsonb_build_object('operator', true, 'name', coalesce(nullif(po.name, ''), u.raw_user_meta_data->>'full_name', split_part(u.email, '@', 1)),
                          'role', po.role, 'email', u.email)
                   from private.platform_operators po join auth.users u on u.id = po.user_id where po.user_id = auth.uid()),
                  jsonb_build_object('operator', false))
$$;

create function public.platform_set_my_name(p_name text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := nullif(regexp_replace(trim(coalesce(p_name, '')), '\s+', ' ', 'g'), '');
begin
  perform private.require_operator();
  if v is null or length(v) > 60 then return jsonb_build_object('ok', false, 'error', 'bad_name'); end if;
  update private.platform_operators set name = v where user_id = auth.uid();
  return jsonb_build_object('ok', true, 'name', v);
end $$;

create function public.platform_team()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform private.require_operator();
  return jsonb_build_object(
    'operators', coalesce((select jsonb_agg(jsonb_build_object('user_id', po.user_id, 'name', coalesce(nullif(po.name, ''), split_part(u.email, '@', 1)),
        'email', u.email, 'role', po.role, 'since', po.created_at, 'last_sign_in_at', u.last_sign_in_at, 'me', po.user_id = auth.uid())
        order by po.role desc, po.name)
      from private.platform_operators po join auth.users u on u.id = po.user_id), '[]'::jsonb),
    'invites', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'email', i.email, 'name', i.name, 'role', i.role, 'expires_at', i.expires_at) order by i.created_at desc)
      from private.platform_invites i where i.accepted_at is null and i.expires_at > now()), '[]'::jsonb));
end $$;

create function public.platform_invite_operator(p_email text, p_role text, p_name text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_email text := lower(trim(p_email)); v_token text := encode(extensions.gen_random_bytes(24), 'hex');
begin
  perform private.require_platform_owner();
  if p_role not in ('owner', 'operator') then return jsonb_build_object('ok', false, 'error', 'bad_role'); end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then return jsonb_build_object('ok', false, 'error', 'bad_email'); end if;
  if exists (select 1 from private.platform_operators po join auth.users u on u.id = po.user_id where lower(u.email) = v_email) then
    return jsonb_build_object('ok', false, 'error', 'already_operator');
  end if;
  delete from private.platform_invites where email = v_email and accepted_at is null;
  insert into private.platform_invites (email, name, role, token_hash, invited_by)
  values (v_email, nullif(trim(p_name), ''), p_role, private.sha256_hex(v_token), auth.uid());
  perform private.plog(null, 'invited operator', jsonb_build_object('email', v_email, 'role', p_role));
  return jsonb_build_object('ok', true, 'email', v_email, 'token', v_token);
end $$;

-- Opened from the emailed link while signed in as the invited address.
create function public.platform_accept_invite(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare inv private.platform_invites; v_email text;
begin
  if auth.uid() is null then return jsonb_build_object('ok', false, 'error', 'not_signed_in'); end if;
  select * into inv from private.platform_invites where token_hash = private.sha256_hex(p_token) for update;
  if not found or inv.accepted_at is not null then return jsonb_build_object('ok', false, 'error', 'invalid_invite'); end if;
  if inv.expires_at < now() then return jsonb_build_object('ok', false, 'error', 'invite_expired'); end if;
  select lower(email) into v_email from auth.users where id = auth.uid();
  if v_email is distinct from inv.email then return jsonb_build_object('ok', false, 'error', 'wrong_account', 'invited_email', inv.email); end if;
  insert into private.platform_operators (user_id, name, role) values (auth.uid(), inv.name, inv.role)
  on conflict (user_id) do update set role = case when excluded.role = 'owner' then 'owner' else private.platform_operators.role end,
                                      name = coalesce(private.platform_operators.name, excluded.name);
  update private.platform_invites set accepted_at = now() where id = inv.id;
  perform private.plog(null, 'joined the console', jsonb_build_object('role', inv.role));
  return jsonb_build_object('ok', true, 'role', inv.role);
end $$;

create function public.platform_set_operator_role(p_user uuid, p_role text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_cur text;
begin
  perform private.require_platform_owner();
  if p_role not in ('owner', 'operator') then return jsonb_build_object('ok', false, 'error', 'bad_role'); end if;
  select role into v_cur from private.platform_operators where user_id = p_user for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_operator'); end if;
  if v_cur = 'owner' and p_role <> 'owner' and (select count(*) from private.platform_operators where role = 'owner') = 1 then
    return jsonb_build_object('ok', false, 'error', 'last_owner');
  end if;
  update private.platform_operators set role = p_role where user_id = p_user;
  perform private.plog(null, 'changed operator role', jsonb_build_object('email', (select email from auth.users where id = p_user), 'role', p_role));
  return jsonb_build_object('ok', true);
end $$;

create function public.platform_remove_operator(p_user uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_cur text;
begin
  perform private.require_platform_owner();
  select role into v_cur from private.platform_operators where user_id = p_user for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_operator'); end if;
  if v_cur = 'owner' and (select count(*) from private.platform_operators where role = 'owner') = 1 then
    return jsonb_build_object('ok', false, 'error', 'last_owner');
  end if;
  delete from private.platform_operators where user_id = p_user;
  perform private.plog(null, 'removed operator', jsonb_build_object('email', (select email from auth.users where id = p_user)));
  return jsonb_build_object('ok', true);
end $$;

create function public.platform_cancel_operator_invite(p_invite uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform private.require_platform_owner();
  delete from private.platform_invites where id = p_invite and accepted_at is null;
end $$;

-- The activity log now records only what actually changed.
create or replace function public.platform_update_customer(p_org uuid, p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare o public.organizations; v_new jsonb; v_changed jsonb; v_old_notes text;
begin
  perform private.require_operator();
  select * into o from public.organizations where id = p_org for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if p ? 'name' and coalesce(trim(p->>'name'), '') = '' then return jsonb_build_object('ok', false, 'error', 'name_required'); end if;
  update public.organizations set
    name            = case when p ? 'name' then trim(p->>'name') else name end,
    timezone        = case when p ? 'timezone' then p->>'timezone' else timezone end,
    primary_color   = case when p ? 'primary_color' then p->>'primary_color' else primary_color end,
    accent_color    = case when p ? 'accent_color' then p->>'accent_color' else accent_color end,
    logo_url        = case when p ? 'logo_url' then nullif(p->>'logo_url', '') else logo_url end,
    terminology     = case when p ? 'terminology' then terminology || (p->'terminology') else terminology end,
    enabled_modules = case when p ? 'modules' then array(select jsonb_array_elements_text(p->'modules')) else enabled_modules end,
    status          = case when p ? 'status' then (p->>'status')::public.account_status else status end,
    plan            = case when p ? 'plan' then p->>'plan' else plan end,
    trial_ends_at   = case when p ? 'trial_ends_at' then (p->>'trial_ends_at')::timestamptz else trial_ends_at end,
    station_limit   = case when p ? 'station_limit' then (p->>'station_limit')::int else station_limit end,
    contact_name    = case when p ? 'contact_name' then nullif(p->>'contact_name', '') else contact_name end,
    contact_email   = case when p ? 'contact_email' then nullif(lower(trim(p->>'contact_email')), '') else contact_email end,
    contact_phone   = case when p ? 'contact_phone' then nullif(p->>'contact_phone', '') else contact_phone end
  where id = p_org;
  v_old_notes := (select notes from private.customer_notes where org_id = p_org);
  if p ? 'notes' then
    if coalesce(trim(p->>'notes'), '') = '' then delete from private.customer_notes where org_id = p_org;
    else insert into private.customer_notes (org_id, notes) values (p_org, trim(p->>'notes'))
         on conflict (org_id) do update set notes = excluded.notes, updated_at = now(); end if;
  end if;
  -- Log only what actually changed (new values; notes just say they changed).
  v_new := (select to_jsonb(x) from public.organizations x where id = p_org);
  v_changed := coalesce((select jsonb_object_agg(k, v_new -> k) from jsonb_object_keys(v_new) k
                         where k not in ('id', 'created_at') and (v_new -> k) is distinct from (to_jsonb(o) -> k)), '{}'::jsonb);
  if p ? 'notes' and nullif(trim(p->>'notes'), '') is distinct from v_old_notes then v_changed := v_changed || '{"notes": "changed"}'; end if;
  if v_changed <> '{}'::jsonb then
    perform private.plog(p_org,
      case when v_changed ? 'status' then 'status: ' || (v_changed->>'status') else 'updated customer' end, v_changed);
  end if;
  return jsonb_build_object('ok', true);
end $$;


revoke execute on all functions in schema private from public, anon, authenticated;
grant  execute on function private.has_org_role(uuid, public.member_role) to authenticated;
grant  execute on function private.normalize_uid(text) to anon, authenticated;
grant  execute on function private.resolve_time_limit(public.time_limit_mode, numeric, public.time_limit_type, numeric) to authenticated;

revoke execute on function public.platform_me(), public.platform_set_my_name(text), public.platform_team(), public.platform_invite_operator(text, text, text),
  public.platform_accept_invite(text), public.platform_set_operator_role(uuid, text), public.platform_remove_operator(uuid),
  public.platform_cancel_operator_invite(uuid), public.platform_update_customer(uuid, jsonb) from public;
grant execute on function public.platform_me(), public.platform_set_my_name(text), public.platform_team(), public.platform_invite_operator(text, text, text),
  public.platform_accept_invite(text), public.platform_set_operator_role(uuid, text), public.platform_remove_operator(uuid),
  public.platform_cancel_operator_invite(uuid), public.platform_update_customer(uuid, jsonb) to authenticated;
