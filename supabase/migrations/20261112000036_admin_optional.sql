-- Migration 36: a customer doesn't need an Admin. Some companies are run (and billed) contract by contract, with a lead
-- for each and nobody over all of them. New customers can be created without an admin invite, and Sonoran Point can
-- remove or change a company's last Admin from the console (customers still can't remove their own last one).

-- Same as migration 7, with the admin email optional.
create or replace function public.platform_create_customer(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_org uuid; v_inv jsonb; v_st jsonb := '[]'; v_name text; v_slug text; r jsonb;
begin
  perform private.require_operator();
  v_name := trim(p->>'name'); v_slug := lower(trim(p->>'slug'));
  if coalesce(v_name, '') = '' then return jsonb_build_object('ok', false, 'error', 'name_required'); end if;
  if v_slug !~ '^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$' then return jsonb_build_object('ok', false, 'error', 'bad_slug'); end if;
  if exists (select 1 from public.organizations where slug = v_slug) then return jsonb_build_object('ok', false, 'error', 'slug_taken'); end if;
  -- An admin is optional: a company run (and billed) contract by contract may have none, only leads.
  if coalesce(trim(p->>'owner_email'), '') <> '' and (p->>'owner_email') !~ '^\s*[^@\s]+@[^@\s]+\.[^@\s]+\s*$' then
    return jsonb_build_object('ok', false, 'error', 'bad_email');
  end if;

  insert into public.organizations (name, slug, timezone, primary_color, accent_color, logo_url, terminology,
                                    enabled_modules, status, plan, trial_ends_at, station_limit,
                                    contact_name, contact_email, contact_phone)
  values (v_name, v_slug, coalesce(p->>'timezone', 'America/Phoenix'),
          coalesce(p->>'primary_color', '#0B2350'), coalesce(p->>'accent_color', '#F7931E'), nullif(p->>'logo_url', ''),
          '{"equipment":"Equipment","equipment_plural":"Equipment","employee":"Employee","employee_plural":"Employees","checkout":"Check Out","checkin":"Return"}'::jsonb
            || coalesce(p->'terminology', '{}'::jsonb),
          coalesce(array(select jsonb_array_elements_text(p->'modules')), '{}'),
          coalesce((p->>'status')::public.account_status, 'trial'), coalesce(nullif(p->>'plan', ''), 'standard'),
          case when coalesce(p->>'status', 'trial') = 'trial' then now() + make_interval(days => coalesce((p->>'trial_days')::int, 30)) end,
          (p->>'station_limit')::int,
          nullif(p->>'contact_name', ''), nullif(lower(trim(p->>'contact_email')), ''), nullif(p->>'contact_phone', ''))
  returning id into v_org;
  if coalesce(trim(p->>'notes'), '') <> '' then insert into private.customer_notes (org_id, notes) values (v_org, trim(p->>'notes')); end if;

  if coalesce(trim(p->>'owner_email'), '') <> '' then v_inv := private.owner_invite(v_org, p->>'owner_email'); end if;
  for r in select value from jsonb_array_elements(coalesce(p->'stations', '[]'::jsonb)) loop
    v_st := v_st || jsonb_build_array(public.create_station(v_org, coalesce(nullif(trim(r #>> '{}'), ''), 'Station')) - 'ok'
                                      || jsonb_build_object('name', coalesce(nullif(trim(r #>> '{}'), ''), 'Station')));
  end loop;
  perform private.plog(v_org, 'created customer', jsonb_build_object('name', v_name, 'stations', jsonb_array_length(v_st), 'owner', v_inv->>'email'));
  return jsonb_build_object('ok', true, 'org_id', v_org, 'owner_invite', v_inv, 'stations', v_st);
end $$;

-- Same as migration 33; operators may change or remove the last Admin.
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
  if v_cur = 'owner' and not private.is_platform_operator() and (select count(*) from public.org_members where org_id = p_org and role = 'owner') = 1 then
    return jsonb_build_object('ok', false, 'error', 'last_owner');
  end if;
  if private.is_platform_operator() then perform private.plog(p_org, 'removed from team', jsonb_build_object('email', (select email from auth.users where id = p_user))); end if;
  delete from public.org_members where org_id = p_org and user_id = p_user;
  return jsonb_build_object('ok', true);
end $$;
