-- Migration 39: closes two ways someone limited to contracts could end up seeing the whole company.
-- An Admin whose only contract was deleted (or whose invite's contracts were all deleted) would have had no contracts left,
-- which means "whole company" for an Admin. Now a contract can't be deleted while people (or open invites) are on it,
-- and an invite whose contracts are all gone is refused.

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
    'shifts',    (select count(*) from public.shifts    where contract_id = p_contract and active),
    -- People given it (and open invites for it): taking it away could leave an Admin with no contracts = the whole company.
    'members',   (select count(*) from public.member_contracts where contract_id = p_contract)
               + (select count(*) from public.org_invites where org_id = v_org and accepted_at is null and p_contract = any (contracts)));
  if (select sum(value::int) from jsonb_each_text(n)) > 0 then return jsonb_build_object('ok', false, 'error', 'in_use', 'counts', n); end if;
  update public.stations  set contract_id = null where contract_id = p_contract;
  update public.employees set contract_id = null where contract_id = p_contract;
  update public.equipment set contract_id = null where contract_id = p_contract;
  update public.shifts    set contract_id = null where contract_id = p_contract;
  delete from public.contracts where id = p_contract;
  perform private.plog(v_org, 'removed contract', jsonb_build_object('name', v_name));
  return jsonb_build_object('ok', true);
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
  -- An invite for contracts that are gone mustn't turn into a whole-company invite.
  if coalesce(cardinality(inv.contracts), 0) > 0
     and not exists (select 1 from public.contracts c where c.id = any (inv.contracts) and c.org_id = inv.org_id) then
    return jsonb_build_object('ok', false, 'error', 'invite_outdated');
  end if;
  -- Someone already on the team keeps what they had; this adds the invite's contracts (unless they see everything).
  insert into public.org_members (org_id, user_id, role) values (inv.org_id, auth.uid(), inv.role)
  on conflict (org_id, user_id) do update set role = greatest(public.org_members.role, excluded.role);
  insert into public.member_contracts (org_id, user_id, contract_id)
  select inv.org_id, auth.uid(), c from unnest(coalesce(inv.contracts, '{}')) c
  where exists (select 1 from public.contracts where id = c and org_id = inv.org_id)
  on conflict do nothing;
  update public.org_invites set accepted_at = now(), accepted_by = auth.uid() where id = inv.id;
  return jsonb_build_object('ok', true, 'org_id', inv.org_id, 'role', inv.role);
end $$;
