-- Migration 33: contracts are set up by Sonoran Point, and each lead only sees their own branch.
--
-- * Contracts (and the company's sharing switches) are added, changed and removed from the console only.
--   Customers ask for changes with request_contract_change() (a request in the console).
-- * Closed by default: in a company that has contracts, everyone except its Admins (role owner) sees only the
--   contracts they're assigned and everything under them. Not the groups above, not things with no contract.
--   (Before: no contracts picked = everything; assigned = also the groups above and whole-company things.)
-- * Leads (Managers locked to contracts) only invite, change and remove people inside their own branch, and can't
--   change company-wide things (settings, logo, categories and locations they didn't just add).
-- * Operators can invite people with contracts, change someone's contracts and role, or remove them, from the console.
-- * Members who had no contracts picked in a company with contracts keep seeing every contract (they're given the
--   top-level ones), so nobody is locked out by this migration.

-- ---------------------------------------------------------------------
-- Who sees what
-- ---------------------------------------------------------------------
create or replace function private.scope_of(p_org uuid, p_user uuid)
returns uuid[] language sql stable security definer set search_path = public as $$
  select case
    when exists (select 1 from public.org_members where org_id = p_org and user_id = p_user and role = 'owner') then null
    when not exists (select 1 from public.contracts where org_id = p_org) then null
    else coalesce((
      with recursive down(id) as (
        select contract_id from public.member_contracts where org_id = p_org and user_id = p_user
        union select c.id from public.contracts c join down on c.parent_id = down.id)
      select array_agg(distinct id) from down), '{}')
  end
$$;

create or replace function private.sees(p_org uuid, p_user uuid, p_contract uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select case when private.scope_of(p_org, p_user) is null then true
              else coalesce(p_contract = any (private.scope_of(p_org, p_user)), false) end
$$;

create or replace function private.can_see_txn(p_org uuid, p_eq uuid, p_station uuid, p_emp uuid)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare sc uuid[]; c_eq uuid; c_st uuid; c_emp uuid;
begin
  if not private.has_org_role(p_org) then return false; end if;
  sc := private.scope_of(p_org, auth.uid());
  if sc is null then return true; end if;
  select contract_id into c_eq from public.equipment where id = p_eq;
  select contract_id into c_st from public.stations where id = p_station;
  select contract_id into c_emp from public.employees where id = p_emp;
  return coalesce(c_eq = any (sc), false) or coalesce(c_st = any (sc), false) or coalesce(c_emp = any (sc), false);
end $$;

create or replace function private.can_see_tap(p_org uuid, p_eq uuid, p_station_contract uuid, p_emp uuid)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare sc uuid[]; c_eq uuid; c_emp uuid;
begin
  if not private.has_org_role(p_org) then return false; end if;
  sc := private.scope_of(p_org, auth.uid());
  if sc is null then return true; end if;
  select contract_id into c_eq from public.equipment where id = p_eq;
  select contract_id into c_emp from public.employees where id = p_emp;
  return coalesce(c_eq = any (sc), false) or coalesce(p_station_contract = any (sc), false) or coalesce(c_emp = any (sc), false);
end $$;

-- The signed-in person's limit in a company: null = everything (Admins, operators, companies without contracts).
create or replace function private.my_scope(p_org uuid)
returns uuid[] language sql stable security definer set search_path = public as $$
  select case when private.is_platform_operator() then null else private.scope_of(p_org, auth.uid()) end
$$;
create or replace function private.unscoped(p_org uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select (private.has_org_role(p_org) or private.is_platform_operator()) and private.my_scope(p_org) is null
$$;
-- Can the signed-in person manage this member? Unscoped: yes. A lead: only people whose contracts all sit in their branch.
create or replace function private.in_my_branch(p_org uuid, p_user uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select private.my_scope(p_org) is null
      or (exists (select 1 from public.member_contracts where org_id = p_org and user_id = p_user)
          and not exists (select 1 from public.member_contracts where org_id = p_org and user_id = p_user
                          and not (contract_id = any (private.my_scope(p_org)))))
$$;

-- Nobody loses access: members with no contracts in a company that has some get its top-level contracts.
insert into public.member_contracts (org_id, user_id, contract_id)
select m.org_id, m.user_id, c.id from public.org_members m join public.contracts c on c.org_id = m.org_id and c.parent_id is null
where m.role <> 'owner' and not exists (select 1 from public.member_contracts x where x.org_id = m.org_id and x.user_id = m.user_id)
on conflict do nothing;

-- ---------------------------------------------------------------------
-- Company-wide things stay with the company's Admins
-- ---------------------------------------------------------------------
drop policy if exists org_update on public.organizations;
create policy org_update on public.organizations for update to authenticated
  using (private.has_org_role(id, 'admin') and private.unscoped(id)) with check (private.has_org_role(id, 'admin') and private.unscoped(id));

-- Leads can add a category or location (an import may need one) but not change or delete the company's.
drop policy if exists loc_write on public.locations;
create policy loc_insert on public.locations for insert to authenticated with check (private.has_org_role(org_id, 'admin'));
create policy loc_update on public.locations for update to authenticated
  using (private.has_org_role(org_id, 'admin') and private.unscoped(org_id)) with check (private.has_org_role(org_id, 'admin') and private.unscoped(org_id));
create policy loc_delete on public.locations for delete to authenticated using (private.has_org_role(org_id, 'admin') and private.unscoped(org_id));
drop policy if exists cat_write on public.equipment_categories;
create policy cat_insert on public.equipment_categories for insert to authenticated with check (private.has_org_role(org_id, 'admin'));
create policy cat_update on public.equipment_categories for update to authenticated
  using (private.has_org_role(org_id, 'admin') and private.unscoped(org_id)) with check (private.has_org_role(org_id, 'admin') and private.unscoped(org_id));
create policy cat_delete on public.equipment_categories for delete to authenticated using (private.has_org_role(org_id, 'admin') and private.unscoped(org_id));

create or replace function public.delete_category(p_category uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_org uuid;
begin
  select org_id into v_org from public.equipment_categories where id = p_category;
  if v_org is null or not private.has_org_role(v_org, 'admin') or not private.unscoped(v_org) then raise exception 'not allowed' using errcode = '42501'; end if;
  if exists (select 1 from public.equipment where category_id = p_category) then return jsonb_build_object('ok', false, 'error', 'in_use'); end if;
  delete from public.equipment_categories where id = p_category;
  return jsonb_build_object('ok', true);
end $$;

create or replace function private.can_manage_logo(p_folder text)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare v_org uuid;
begin
  begin v_org := p_folder::uuid; exception when others then return false; end;
  return (private.has_org_role(v_org, 'admin') and private.unscoped(v_org)) or private.is_platform_operator();
end $$;

-- The two sharing switches in settings are part of the contract setup: only operators change them.
create or replace function private.org_contract_settings()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if not private.is_platform_operator() and auth.uid() is not null then
    new.settings := coalesce(new.settings, '{}'::jsonb) - 'share_contracts' - 'move_on_return'
      || jsonb_strip_nulls(jsonb_build_object('share_contracts', old.settings->'share_contracts', 'move_on_return', old.settings->'move_on_return'));
  end if;
  return new;
end $$;
drop trigger if exists org_contract_settings on public.organizations;
create trigger org_contract_settings before update of settings on public.organizations
  for each row execute function private.org_contract_settings();

-- ---------------------------------------------------------------------
-- Contracts: console only
-- ---------------------------------------------------------------------
create or replace function public.save_contract(p_org uuid, p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_parent uuid := nullif(p->>'parent_id', '')::uuid; v_name text := trim(coalesce(p->>'name', ''));
        v_old public.contracts;
begin
  if not private.is_platform_operator() then
    if private.has_org_role(p_org, 'admin') then return jsonb_build_object('ok', false, 'error', 'ask_us'); end if;
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if not exists (select 1 from public.organizations where id = p_org) then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if v_name = '' then return jsonb_build_object('ok', false, 'error', 'name_required'); end if;
  if length(v_name) > 60 then return jsonb_build_object('ok', false, 'error', 'name_too_long'); end if;
  if v_parent is not null and not exists (select 1 from public.contracts where id = v_parent and org_id = p_org) then
    return jsonb_build_object('ok', false, 'error', 'unknown_parent');
  end if;
  if v_id is not null and v_parent is not null and v_id = any (private.contract_path(v_parent)) then
    return jsonb_build_object('ok', false, 'error', 'parent_inside_itself');
  end if;
  if exists (select 1 from public.contracts where org_id = p_org and parent_id is not distinct from v_parent
             and lower(trim(name)) = lower(v_name) and id is distinct from v_id) then
    return jsonb_build_object('ok', false, 'error', 'duplicate_name');
  end if;
  if v_id is null then
    insert into public.contracts (org_id, parent_id, name, share_children, move_on_return, sort_order)
    values (p_org, v_parent, v_name, coalesce((p->>'share_children')::boolean, false), coalesce((p->>'move_on_return')::boolean, false),
            (select coalesce(max(sort_order), 0) + 1 from public.contracts where org_id = p_org and parent_id is not distinct from v_parent))
    returning id into v_id;
    perform private.plog(p_org, 'added contract', jsonb_build_object('name', v_name, 'parent', (select name from public.contracts where id = v_parent)));
  else
    select * into v_old from public.contracts where id = v_id and org_id = p_org;
    if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
    update public.contracts set name = v_name, parent_id = case when p ? 'parent_id' then v_parent else parent_id end,
           share_children = coalesce((p->>'share_children')::boolean, share_children),
           move_on_return = coalesce((p->>'move_on_return')::boolean, move_on_return)
     where id = v_id and org_id = p_org;
    perform private.plog(p_org, 'changed contract', jsonb_build_object('name', v_name)
      || case when v_old.name <> v_name then jsonb_build_object('from', v_old.name) else '{}'::jsonb end);
  end if;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

-- Only an empty contract can be deleted (no contracts under it, nothing assigned to it).
create or replace function public.delete_contract(p_contract uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_org uuid; v_name text; n jsonb;
begin
  select org_id, name into v_org, v_name from public.contracts where id = p_contract;
  if not private.is_platform_operator() then
    if v_org is not null and private.has_org_role(v_org, 'admin') then return jsonb_build_object('ok', false, 'error', 'ask_us'); end if;
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if v_org is null then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  n := jsonb_build_object(
    'contracts', (select count(*) from public.contracts where parent_id = p_contract),
    'stations',  (select count(*) from public.stations  where contract_id = p_contract and revoked_at is null),
    'employees', (select count(*) from public.employees where contract_id = p_contract and active),
    'equipment', (select count(*) from public.equipment where contract_id = p_contract and status <> 'retired'),
    'shifts',    (select count(*) from public.shifts    where contract_id = p_contract and active));
  if (select sum(value::int) from jsonb_each_text(n)) > 0 then return jsonb_build_object('ok', false, 'error', 'in_use', 'counts', n); end if;
  update public.stations  set contract_id = null where contract_id = p_contract;
  update public.employees set contract_id = null where contract_id = p_contract;
  update public.equipment set contract_id = null where contract_id = p_contract;
  update public.shifts    set contract_id = null where contract_id = p_contract;
  delete from public.contracts where id = p_contract;
  perform private.plog(v_org, 'removed contract', jsonb_build_object('name', v_name));
  return jsonb_build_object('ok', true);
end $$;

-- A customer's Admin or lead asks us to add, change or remove a contract. Lands in the console's Requests.
alter table private.contact_requests drop constraint if exists contact_requests_source_check;
alter table private.contact_requests add constraint contact_requests_source_check check (source in ('website', 'console', 'dashboard'));

create or replace function public.request_contract_change(p_org uuid, p_message text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_msg text := btrim(coalesce(p_message, '')); v_email text; v_name text; v_company text; v_id bigint;
        v_ops text[]; v_console text; e text;
begin
  if not private.has_org_role(p_org, 'admin') then raise exception 'not allowed' using errcode = '42501'; end if;
  if v_msg = '' then return jsonb_build_object('ok', false, 'error', 'bad_message'); end if;
  if length(v_msg) > 4000 then return jsonb_build_object('ok', false, 'error', 'too_long'); end if;
  select lower(u.email), coalesce(nullif(trim(u.raw_user_meta_data->>'full_name'), ''), split_part(u.email, '@', 1))
    into v_email, v_name from auth.users u where u.id = auth.uid();
  if (select count(*) from private.contact_requests where source = 'dashboard' and email = v_email and created_at > now() - interval '1 hour') >= 5 then
    return jsonb_build_object('ok', false, 'error', 'too_many'); end if;
  select name into v_company from public.organizations where id = p_org;
  insert into private.contact_requests (name, email, company, topic, message, kind, org_id, source)
  values (v_name, v_email, v_company, 'Contract change', v_msg, 'support', p_org, 'dashboard') returning id into v_id;

  select value into v_console from private.app_settings where key = 'console_url';
  select array_agg(u.email order by po.created_at) into v_ops
  from private.platform_operators po join auth.users u on u.id = po.user_id where coalesce(u.email, '') like '%@%';
  foreach e in array coalesce(v_ops, '{}') loop
    insert into private.email_batches (org_id, to_email, reply_to, subject, html, body_text)
    values (p_org, e, v_email, 'Contract change: ' || v_company || ' (' || v_name || ')',
      private.email_html(v_company, 'Contract change asked for',
        format('<p style="margin:0 0 12px"><b>%s</b> &lt;%s&gt;</p><p style="margin:0 0 12px;white-space:pre-wrap">%s</p><p style="margin:0;color:#5b6878">Reply to this email to answer them.</p>',
          private.html_esc(v_name), private.html_esc(v_email), private.html_esc(v_msg)),
        v_console || '/#request/' || v_id, 'Open it in the console', 'Sent from the ' || v_company || ' dashboard.'),
      v_name || ' <' || v_email || E'>\n' || v_company || E'\n\n' || v_msg);
  end loop;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

-- ---------------------------------------------------------------------
-- Team: invites carry contracts; leads stay inside their branch; operators can do it all from the console
-- ---------------------------------------------------------------------
alter table public.org_invites add column if not exists contracts uuid[];

create or replace function private.can_manage_role(p_org uuid, p_role public.member_role)
returns boolean language sql stable security definer set search_path = public as $$
  select private.is_platform_operator() or private.has_org_role(p_org, 'owner') or (private.has_org_role(p_org, 'admin') and p_role < 'owner')
$$;

-- Checks a list of contracts for someone with this role. Returns an error code, or null when it's fine.
create or replace function private.contracts_problem(p_org uuid, p_role public.member_role, p_contracts uuid[])
returns text language plpgsql stable security definer set search_path = public as $$
declare sc uuid[] := private.my_scope(p_org);
begin
  if p_role = 'owner' then return case when coalesce(cardinality(p_contracts), 0) > 0 then 'owner_sees_all' end; end if;
  if not exists (select 1 from public.contracts where org_id = p_org) then
    return case when coalesce(cardinality(p_contracts), 0) > 0 then 'unknown_contract' end;
  end if;
  if coalesce(cardinality(p_contracts), 0) = 0 then return 'pick_contract'; end if;
  if exists (select 1 from unnest(p_contracts) c where not exists (select 1 from public.contracts where id = c and org_id = p_org)) then return 'unknown_contract'; end if;
  if sc is not null and exists (select 1 from unnest(p_contracts) c where not (c = any (sc))) then return 'outside_scope'; end if;
  return null;
end $$;

drop function if exists public.invite_member(uuid, text, public.member_role);
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
  if coalesce(cardinality(v_contracts), 0) = 0 and p_role <> 'owner' and private.my_scope(p_org) is not null then
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
    and (select role from public.org_members where org_id = inv.org_id and user_id = auth.uid()) <> 'owner'
  on conflict do nothing;
  update public.org_invites set accepted_at = now(), accepted_by = auth.uid() where id = inv.id;
  return jsonb_build_object('ok', true, 'org_id', inv.org_id, 'role', inv.role);
end $$;

-- Team list with emails and contracts. A lead sees the company's Admins and the people in their branch.
create or replace function public.list_members(p_org uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare sc uuid[];
begin
  if not private.has_org_role(p_org, 'admin') then raise exception 'not allowed' using errcode = '42501'; end if;
  sc := private.my_scope(p_org);
  return jsonb_build_object(
    'members', coalesce((select jsonb_agg(jsonb_build_object(
        'user_id', m.user_id, 'email', u.email, 'name', u.raw_user_meta_data->>'full_name', 'role', m.role,
        'joined_at', m.created_at, 'last_sign_in_at', u.last_sign_in_at,
        'contracts', coalesce((select jsonb_agg(mc.contract_id) from public.member_contracts mc where mc.org_id = p_org and mc.user_id = m.user_id), '[]'::jsonb),
        'manage', private.can_manage_role(p_org, m.role) and private.in_my_branch(p_org, m.user_id)) order by m.role desc, u.email)
      from public.org_members m join auth.users u on u.id = m.user_id
      where m.org_id = p_org and (sc is null or m.role = 'owner' or m.user_id = auth.uid()
        or exists (select 1 from public.member_contracts mc where mc.org_id = p_org and mc.user_id = m.user_id and mc.contract_id = any (sc)))), '[]'::jsonb),
    'invites', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'email', i.email, 'role', i.role,
        'created_at', i.created_at, 'expires_at', i.expires_at, 'contracts', coalesce(to_jsonb(i.contracts), '[]'::jsonb)) order by i.created_at desc)
      from public.org_invites i where i.org_id = p_org and i.accepted_at is null and i.expires_at > now()
        and (sc is null or (i.contracts is not null and i.contracts <@ sc))), '[]'::jsonb));
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
  if v_cur = 'owner' and p_role <> 'owner'
     and (select count(*) from public.org_members where org_id = p_org and role = 'owner') = 1 then
    return jsonb_build_object('ok', false, 'error', 'last_owner');
  end if;
  -- An Admin sees everything, so their contract list goes. Someone who stops being an Admin sees nothing until they're
  -- given contracts (set_member_contracts, right after).
  if p_role = 'owner' then delete from public.member_contracts where org_id = p_org and user_id = p_user; end if;
  update public.org_members set role = p_role where org_id = p_org and user_id = p_user;
  if private.is_platform_operator() then perform private.plog(p_org, 'changed team role', jsonb_build_object('email', (select email from auth.users where id = p_user), 'role', p_role)); end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.remove_member(p_org uuid, p_user uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_cur public.member_role;
begin
  select role into v_cur from public.org_members where org_id = p_org and user_id = p_user for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_member'); end if;
  if not private.can_manage_role(p_org, v_cur) or not private.in_my_branch(p_org, p_user) then raise exception 'not allowed' using errcode = '42501'; end if;
  if v_cur = 'owner' and (select count(*) from public.org_members where org_id = p_org and role = 'owner') = 1 then
    return jsonb_build_object('ok', false, 'error', 'last_owner');
  end if;
  if private.is_platform_operator() then perform private.plog(p_org, 'removed from team', jsonb_build_object('email', (select email from auth.users where id = p_user))); end if;
  delete from public.org_members where org_id = p_org and user_id = p_user;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.cancel_invite(p_invite uuid)
returns void language plpgsql security definer set search_path = public as $$
declare inv public.org_invites; sc uuid[];
begin
  select * into inv from public.org_invites where id = p_invite;
  if not found or not private.can_manage_role(inv.org_id, inv.role) then raise exception 'not allowed' using errcode = '42501'; end if;
  sc := private.my_scope(inv.org_id);
  if sc is not null and (inv.contracts is null or not inv.contracts <@ sc) then raise exception 'not allowed' using errcode = '42501'; end if;
  delete from public.org_invites where id = p_invite and accepted_at is null;
  if private.is_platform_operator() then perform private.plog(inv.org_id, 'cancelled invite', jsonb_build_object('email', inv.email)); end if;
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

-- ---------------------------------------------------------------------
-- Console: a customer's members and invites now carry their contracts
-- ---------------------------------------------------------------------
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
        'code_expires_at', k.activation_expires_at, 'created_at', s.created_at, 'contract_id', s.contract_id, 'replaced_at', s.replaced_at) order by s.created_at)
      from public.stations s left join public.locations l on l.id = s.location_id
      left join private.station_keys k on k.station_id = s.id where s.org_id = p_org and s.removed_at is null), '[]'::jsonb),
    'locations', coalesce((select jsonb_agg(l.name order by l.name) from public.locations l where l.org_id = p_org), '[]'::jsonb),
    'station_events', coalesce((select jsonb_agg(jsonb_build_object('station_id', e.station_id, 'at', e.at, 'kind', e.kind, 'details', e.details, 'by', e.by_name)
        order by e.at desc, e.id desc) from (select * from public.station_events where org_id = p_org order by at desc, id desc limit 300) e), '[]'::jsonb),
    'contracts', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'parent_id', c.parent_id, 'name', c.name, 'share', c.share_children, 'move', c.move_on_return,
        'stations', (select count(*) from public.stations s where s.contract_id = c.id and s.revoked_at is null),
        'employees', (select count(*) from public.employees e where e.contract_id = c.id and e.active),
        'equipment', (select count(*) from public.equipment q where q.contract_id = c.id and q.status <> 'retired'))
        order by c.sort_order, c.name) from public.contracts c where c.org_id = p_org), '[]'::jsonb),
    'members', coalesce((select jsonb_agg(jsonb_build_object('user_id', m.user_id, 'email', u.email, 'name', nullif(trim(u.raw_user_meta_data->>'full_name'), ''),
        'role', m.role, 'last_sign_in_at', u.last_sign_in_at,
        'contracts', coalesce((select jsonb_agg(mc.contract_id) from public.member_contracts mc where mc.org_id = p_org and mc.user_id = m.user_id), '[]'::jsonb))
        order by m.role desc, u.email)
      from public.org_members m join auth.users u on u.id = m.user_id where m.org_id = p_org), '[]'::jsonb),
    'invites', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'email', i.email, 'role', i.role, 'expires_at', i.expires_at,
        'contracts', coalesce(to_jsonb(i.contracts), '[]'::jsonb)))
      from public.org_invites i where i.org_id = p_org and i.accepted_at is null and i.expires_at > now()), '[]'::jsonb),
    'log', coalesce((select jsonb_agg(jsonb_build_object('at', g.at, 'action', g.action, 'details', g.details,
        'by', coalesce(po.name, u.email)) order by g.at desc)
      from (select * from private.platform_log where org_id = p_org order by at desc limit 50) g
      left join private.platform_operators po on po.user_id = g.operator left join auth.users u on u.id = g.operator), '[]'::jsonb));
end $$;

-- Sharing switches for the whole company (settings.share_contracts / move_on_return), from the console.
create or replace function public.platform_contract_settings(p_org uuid, p_share boolean, p_move boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform private.require_operator();
  update public.organizations set settings = coalesce(settings, '{}'::jsonb)
    || jsonb_build_object('share_contracts', coalesce(p_share, false), 'move_on_return', coalesce(p_move, false)) where id = p_org;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  perform private.plog(p_org, 'changed contract sharing', jsonb_build_object('text',
    case when p_share then 'Top-level contracts share' else 'Top-level contracts don''t share' end
    || case when p_move then ', items move where returned' else '' end));
  return jsonb_build_object('ok', true);
end $$;

revoke execute on all functions in schema private from public, anon, authenticated;
grant  execute on function private.has_org_role(uuid, public.member_role) to authenticated;
grant  execute on function private.normalize_uid(text) to anon, authenticated;
grant  execute on function private.resolve_time_limit(public.time_limit_mode, numeric, public.time_limit_type, numeric) to authenticated;
grant  execute on function private.can_manage_logo(text) to authenticated;
grant  execute on function private.can_see(uuid, uuid), private.can_see_equipment(uuid), private.can_see_txn(uuid, uuid, uuid, uuid),
  private.can_see_tap(uuid, uuid, uuid, uuid), private.sees(uuid, uuid, uuid), private.scope_of(uuid, uuid),
  private.unscoped(uuid), private.my_scope(uuid) to authenticated;
revoke execute on function public.invite_member(uuid, text, public.member_role, uuid[]), public.request_contract_change(uuid, text),
  public.platform_contract_settings(uuid, boolean, boolean) from public, anon;
grant  execute on function public.invite_member(uuid, text, public.member_role, uuid[]), public.request_contract_change(uuid, text),
  public.platform_contract_settings(uuid, boolean, boolean) to authenticated;
