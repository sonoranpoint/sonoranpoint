-- Migration 42: Admins are added only by Sonoran Point, and an employee's page can give them dashboard access.
--
-- * Only the console makes, changes or removes Admins (role owner). Customers' Admins and Managers handle everyone else.
-- * An employee can be linked to a dashboard account (employees.user_id). On their page you pick a role: Agent (badge only,
--   no dashboard) or a dashboard role. Picking one for someone without an account sends an invite to the email you enter;
--   accepting it links the account to the employee. Picking Agent again takes the dashboard access away.

alter table public.employees add column if not exists user_id uuid references auth.users(id) on delete set null;
create unique index if not exists employees_user on public.employees (org_id, user_id) where user_id is not null;
alter table public.org_invites add column if not exists employee_id uuid references public.employees(id) on delete set null;

-- Admins: only us. Customer Admins give anything below Admin; anyone else with the Team box only roles whose boxes they have.
create or replace function private.can_manage_role(p_org uuid, p_role public.member_role)
returns boolean language sql stable security definer set search_path = public as $$
  select private.is_platform_operator()
      or (private.has_org_role(p_org, 'owner') and p_role < 'owner')
      or (private.has_perm(p_org, 'team') and p_role < 'admin' and private.role_perms(p_role) <@ private.perms_of(p_org, auth.uid()))
$$;

-- Same as migration 40, plus linking the employee it was sent from.
CREATE OR REPLACE FUNCTION public.accept_invite(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare inv public.org_invites; v_email text;
begin
  if auth.uid() is null then return jsonb_build_object('ok', false, 'error', 'not_signed_in'); end if;
  select * into inv from public.org_invites where token_hash = private.sha256_hex(p_token) for update;
  if not found or inv.accepted_at is not null then return jsonb_build_object('ok', false, 'error', 'invalid_invite'); end if;
  if inv.expires_at < now() then return jsonb_build_object('ok', false, 'error', 'invite_expired'); end if;
  select lower(email) into v_email from auth.users where id = auth.uid();
  if v_email is distinct from inv.email then return jsonb_build_object('ok', false, 'error', 'wrong_account', 'invited_email', inv.email); end if;
  -- An invite for contracts that are gone mustn't turn into a whole-company invite.
  if coalesce(cardinality(inv.contracts), 0) > 0
     and not exists (select 1 from public.contracts c where c.id = any (inv.contracts) and c.org_id = inv.org_id) then
    return jsonb_build_object('ok', false, 'error', 'invite_outdated');
  end if;
  -- Someone already on the team keeps what they had; this adds the invite's contracts (unless they see everything).
  insert into public.org_members (org_id, user_id, role, custom_role_id)
  values (inv.org_id, auth.uid(), inv.role, (select id from public.custom_roles where id = inv.custom_role_id))
  on conflict (org_id, user_id) do update set role = greatest(public.org_members.role, excluded.role);
  insert into public.member_contracts (org_id, user_id, contract_id)
  select inv.org_id, auth.uid(), c from unnest(coalesce(inv.contracts, '{}')) c
  where exists (select 1 from public.contracts where id = c and org_id = inv.org_id)
  on conflict do nothing;
  -- Invited from someone's employee page: their employee record is now this dashboard account.
  update public.employees set user_id = auth.uid() where id = inv.employee_id and org_id = inv.org_id and user_id is null
    and not exists (select 1 from public.employees where org_id = inv.org_id and user_id = auth.uid());
  update public.org_invites set accepted_at = now(), accepted_by = auth.uid() where id = inv.id;
  return jsonb_build_object('ok', true, 'org_id', inv.org_id, 'role', inv.role);
end $function$;

-- Same as migration 40, plus which employee an invite is for.
CREATE OR REPLACE FUNCTION public.list_members(p_org uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare sc uuid[];
begin
  if not private.has_perm(p_org, 'team') then raise exception 'not allowed' using errcode = '42501'; end if;
  sc := private.my_scope(p_org);
  return jsonb_build_object(
    'members', coalesce((select jsonb_agg(jsonb_build_object(
        'user_id', m.user_id, 'email', u.email, 'name', u.raw_user_meta_data->>'full_name', 'role', m.role,
        'joined_at', m.created_at, 'last_sign_in_at', u.last_sign_in_at,
        'contracts', coalesce((select jsonb_agg(mc.contract_id) from public.member_contracts mc where mc.org_id = p_org and mc.user_id = m.user_id), '[]'::jsonb),
        'custom_role_id', m.custom_role_id, 'role_name', (select name from public.custom_roles where id = m.custom_role_id),
        'manage', private.can_manage_member(p_org, m.user_id)) order by m.role desc, u.email)
      from public.org_members m join auth.users u on u.id = m.user_id
      where m.org_id = p_org and (sc is null or m.role = 'owner' or m.user_id = auth.uid()
        or exists (select 1 from public.member_contracts mc where mc.org_id = p_org and mc.user_id = m.user_id and mc.contract_id = any (sc)))), '[]'::jsonb),
    'invites', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'email', i.email, 'role', i.role,
        'custom_role_id', i.custom_role_id, 'role_name', (select name from public.custom_roles where id = i.custom_role_id),
        'employee_id', i.employee_id,
        'created_at', i.created_at, 'expires_at', i.expires_at, 'contracts', coalesce(to_jsonb(i.contracts), '[]'::jsonb)) order by i.created_at desc)
      from public.org_invites i where i.org_id = p_org and i.accepted_at is null and i.expires_at > now()
        and (sc is null or (i.contracts is not null and i.contracts <@ sc))), '[]'::jsonb));
end $function$;

-- An employee's role: Agent (p_role and p_custom_role null: badge only) or a dashboard role. Needs People to edit them,
-- and the right to give that role (checked by invite_member / set_member_role / remove_member).
create or replace function public.set_employee_access(p_employee uuid, p_role public.member_role default null, p_custom_role uuid default null, p_email text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare e public.employees; r jsonb; v_user uuid; i record; v_email text := lower(btrim(coalesce(p_email, '')));
begin
  select * into e from public.employees where id = p_employee;
  if not found or not (private.is_platform_operator() or (private.has_perm(e.org_id, 'people') and private.can_see(e.org_id, e.contract_id))) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if p_role = 'owner' then raise exception 'not allowed' using errcode = '42501'; end if;   -- Admins come from Sonoran Point

  if p_role is null and p_custom_role is null then   -- Agent: no dashboard
    for i in select id from public.org_invites where employee_id = e.id and accepted_at is null loop perform public.cancel_invite(i.id); end loop;
    if e.user_id is not null and exists (select 1 from public.org_members where org_id = e.org_id and user_id = e.user_id) then
      r := public.remove_member(e.org_id, e.user_id);
      if not (r->>'ok')::boolean then return r; end if;
    end if;
    update public.employees set user_id = null where id = e.id;
    return jsonb_build_object('ok', true);
  end if;

  -- Already has an account here: change their role.
  if e.user_id is not null and exists (select 1 from public.org_members where org_id = e.org_id and user_id = e.user_id) then
    return public.set_member_role(e.org_id, e.user_id, coalesce(p_role, 'viewer'), p_custom_role);
  end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then return jsonb_build_object('ok', false, 'error', 'email_needed'); end if;
  -- Someone already on the dashboard with that email: link them and set the role.
  select m.user_id into v_user from public.org_members m join auth.users u on u.id = m.user_id where m.org_id = e.org_id and lower(u.email) = v_email;
  if v_user is not null then
    if exists (select 1 from public.employees where org_id = e.org_id and user_id = v_user and id <> e.id) then
      return jsonb_build_object('ok', false, 'error', 'email_linked');
    end if;
    r := public.set_member_role(e.org_id, v_user, coalesce(p_role, 'viewer'), p_custom_role);
    if (r->>'ok')::boolean then update public.employees set user_id = v_user where id = e.id; end if;
    return r || jsonb_build_object('linked', true);
  end if;
  -- A new invite replaces any older one sent from this employee's page.
  for i in select id from public.org_invites where employee_id = e.id and accepted_at is null loop perform public.cancel_invite(i.id); end loop;
  r := public.invite_member(e.org_id, v_email, coalesce(p_role, 'viewer'), case when e.contract_id is null then null else array[e.contract_id] end, p_custom_role);
  if (r->>'ok')::boolean then update public.org_invites set employee_id = e.id where id = (r->>'invite_id')::uuid; end if;
  return r;
end $$;

revoke execute on function public.set_employee_access(uuid, public.member_role, uuid, text) from public, anon;
grant  execute on function public.set_employee_access(uuid, public.member_role, uuid, text) to authenticated;
