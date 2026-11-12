-- Migration 35: entries in the contract tree are either a location (a site or terminal, like PHX or T3) or a contract
-- (like Delta BW). Only the labels change: who sees what and which stations share work exactly as before (a lead given
-- a location sees everything under it). Set from the console; existing entries stay contracts until changed there.

alter table public.contracts add column if not exists kind text not null default 'contract' check (kind in ('location', 'contract'));

-- Same as migration 33, plus kind.
create or replace function public.save_contract(p_org uuid, p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_parent uuid := nullif(p->>'parent_id', '')::uuid; v_name text := trim(coalesce(p->>'name', ''));
        v_old public.contracts; v_kind text := coalesce(nullif(p->>'kind', ''), 'contract');
begin
  if not private.is_platform_operator() then
    if private.has_org_role(p_org, 'admin') then return jsonb_build_object('ok', false, 'error', 'ask_us'); end if;
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if not exists (select 1 from public.organizations where id = p_org) then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if v_kind not in ('location', 'contract') then return jsonb_build_object('ok', false, 'error', 'bad_kind'); end if;
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
    insert into public.contracts (org_id, parent_id, name, kind, share_children, move_on_return, sort_order)
    values (p_org, v_parent, v_name, v_kind, coalesce((p->>'share_children')::boolean, false), coalesce((p->>'move_on_return')::boolean, false),
            (select coalesce(max(sort_order), 0) + 1 from public.contracts where org_id = p_org and parent_id is not distinct from v_parent))
    returning id into v_id;
    perform private.plog(p_org, case v_kind when 'location' then 'added location' else 'added contract' end, jsonb_build_object('name', v_name, 'parent', (select name from public.contracts where id = v_parent)));
  else
    select * into v_old from public.contracts where id = v_id and org_id = p_org;
    if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
    update public.contracts set name = v_name, kind = case when p ? 'kind' then v_kind else kind end, parent_id = case when p ? 'parent_id' then v_parent else parent_id end,
           share_children = coalesce((p->>'share_children')::boolean, share_children),
           move_on_return = coalesce((p->>'move_on_return')::boolean, move_on_return)
     where id = v_id and org_id = p_org;
    perform private.plog(p_org, case v_kind when 'location' then 'changed location' else 'changed contract' end, jsonb_build_object('name', v_name)
      || case when v_old.name <> v_name then jsonb_build_object('from', v_old.name) else '{}'::jsonb end);
  end if;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

-- Same as migration 33, plus each contract's kind.
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
    'contracts', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'parent_id', c.parent_id, 'name', c.name, 'kind', c.kind, 'share', c.share_children, 'move', c.move_on_return,
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
