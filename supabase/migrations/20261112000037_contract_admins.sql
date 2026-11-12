-- Migration 37: an Admin per contract. Admin (role owner) given contracts runs only those (everything under them),
-- with full admin powers there: their people, including other Admins in their branch. Given several, they run all of them.
-- An Admin with no contracts still runs the whole company. Only someone who sees the whole company (or Sonoran Point)
-- can make a whole-company Admin. Company-wide settings stay with whole-company Admins (private.unscoped).

create or replace function private.scope_of(p_org uuid, p_user uuid)
returns uuid[] language sql stable security definer set search_path = public as $$
  select case
    when not exists (select 1 from public.contracts where org_id = p_org) then null
    -- An Admin with no contracts runs the whole company; an Admin given contracts runs only those.
    when exists (select 1 from public.org_members where org_id = p_org and user_id = p_user and role = 'owner')
         and not exists (select 1 from public.member_contracts where org_id = p_org and user_id = p_user) then null
    else coalesce((
      with recursive down(id) as (
        select contract_id from public.member_contracts where org_id = p_org and user_id = p_user
        union select c.id from public.contracts c join down on c.parent_id = down.id)
      select array_agg(distinct id) from down), '{}')
  end
$$;

create or replace function private.contracts_problem(p_org uuid, p_role public.member_role, p_contracts uuid[])
returns text language plpgsql stable security definer set search_path = public as $$
declare sc uuid[] := private.my_scope(p_org);
begin
  if not exists (select 1 from public.contracts where org_id = p_org) then
    return case when coalesce(cardinality(p_contracts), 0) > 0 then 'unknown_contract' end;
  end if;
  -- No contracts: only an Admin over the whole company, and only someone who sees the whole company can make one.
  if coalesce(cardinality(p_contracts), 0) = 0 then
    return case when p_role = 'owner' and sc is null then null else 'pick_contract' end;
  end if;
  if exists (select 1 from unnest(p_contracts) c where not exists (select 1 from public.contracts where id = c and org_id = p_org)) then return 'unknown_contract'; end if;
  if sc is not null and exists (select 1 from unnest(p_contracts) c where not (c = any (sc))) then return 'outside_scope'; end if;
  return null;
end $$;

create or replace function public.invite_member(p_org uuid, p_email text, p_role public.member_role, p_contracts uuid[] default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_email text := lower(trim(p_email)); v_token text := encode(extensions.gen_random_bytes(24), 'hex'); v_id uuid; v_err text;
        v_contracts uuid[] := p_contracts;
begin
  if not private.can_manage_role(p_org, p_role) then raise exception 'not allowed' using errcode = '42501'; end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then return jsonb_build_object('ok', false, 'error', 'bad_email'); end if;
  if exists (select 1 from public.org_members m join auth.users u on u.id = m.user_id where m.org_id = p_org and lower(u.email) = v_email) then
    return jsonb_build_object('ok', false, 'error', 'already_member');
  end if;
  -- A lead who doesn't pick gives the new person their own contracts.
  if coalesce(cardinality(v_contracts), 0) = 0 and private.my_scope(p_org) is not null then
    select array_agg(contract_id) into v_contracts from public.member_contracts where org_id = p_org and user_id = auth.uid();
  end if;
  v_err := private.contracts_problem(p_org, p_role, v_contracts);
  if v_err is not null then return jsonb_build_object('ok', false, 'error', v_err); end if;
  delete from public.org_invites where org_id = p_org and email = v_email and accepted_at is null;   -- re-invite replaces
  insert into public.org_invites (org_id, email, role, invited_by, token_hash, contracts)
  values (p_org, v_email, p_role, auth.uid(), private.sha256_hex(v_token), nullif(v_contracts, '{}')) returning id into v_id;
  if private.is_platform_operator() then
    perform private.plog(p_org, 'invited ' || case p_role when 'owner' then 'admin' when 'admin' then 'manager' else p_role::text end,
      jsonb_build_object('email', v_email, 'text', (select string_agg(name, ', ' order by name) from public.contracts where id = any (v_contracts))));
  end if;
  return jsonb_build_object('ok', true, 'invite_id', v_id, 'email', v_email, 'token', v_token, 'expires_at', now() + interval '14 days');
end $$;

create or replace function public.accept_invite(p_token text)
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
  insert into public.member_contracts (org_id, user_id, contract_id)
  select inv.org_id, auth.uid(), c from unnest(coalesce(inv.contracts, '{}')) c
  where exists (select 1 from public.contracts where id = c and org_id = inv.org_id)
  on conflict do nothing;
  update public.org_invites set accepted_at = now(), accepted_by = auth.uid() where id = inv.id;
  return jsonb_build_object('ok', true, 'org_id', inv.org_id, 'role', inv.role);
end $$;

create or replace function public.set_member_role(p_org uuid, p_user uuid, p_role public.member_role)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_cur public.member_role;
begin
  select role into v_cur from public.org_members where org_id = p_org and user_id = p_user for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_member'); end if;
  if not private.can_manage_role(p_org, v_cur) or not private.can_manage_role(p_org, p_role) or not private.in_my_branch(p_org, p_user) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if v_cur = 'owner' and p_role <> 'owner' and not private.is_platform_operator()
     and (select count(*) from public.org_members where org_id = p_org and role = 'owner') = 1 then
    return jsonb_build_object('ok', false, 'error', 'last_owner');
  end if;
  -- Contracts stay as they are: promoting a lead to Admin makes them Admin of the same contracts.
  update public.org_members set role = p_role where org_id = p_org and user_id = p_user;
  if private.is_platform_operator() then perform private.plog(p_org, 'changed team role', jsonb_build_object('email', (select email from auth.users where id = p_user), 'role', p_role)); end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.set_member_contracts(p_org uuid, p_user uuid, p_contracts uuid[])
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_role public.member_role; v_err text;
begin
  if not (private.has_org_role(p_org, 'admin') or private.is_platform_operator()) then raise exception 'not allowed' using errcode = '42501'; end if;
  select role into v_role from public.org_members where org_id = p_org and user_id = p_user;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_a_member'); end if;
  if not private.can_manage_role(p_org, v_role) or not private.in_my_branch(p_org, p_user) then raise exception 'not allowed' using errcode = '42501'; end if;
  v_err := private.contracts_problem(p_org, v_role, p_contracts);
  if v_err is not null then return jsonb_build_object('ok', false, 'error', v_err); end if;
  delete from public.member_contracts where org_id = p_org and user_id = p_user;
  insert into public.member_contracts (org_id, user_id, contract_id) select distinct p_org, p_user, c from unnest(coalesce(p_contracts, '{}')) c;
  if private.is_platform_operator() then
    perform private.plog(p_org, 'changed contracts', jsonb_build_object('email', (select email from auth.users where id = p_user),
      'text', (select string_agg(name, ', ' order by name) from public.contracts where id = any (p_contracts))));
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- The members table is only changed through the team functions; whole-company Admins could also write it directly before.
drop policy if exists members_write on public.org_members;
create policy members_write on public.org_members for all to authenticated
  using (private.has_org_role(org_id, 'owner') and private.unscoped(org_id)) with check (private.has_org_role(org_id, 'owner') and private.unscoped(org_id));
