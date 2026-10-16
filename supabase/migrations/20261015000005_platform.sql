-- =====================================================================
-- Platform (vendor) side: the people who sell and run the service.
--
-- Operators are NOT members of any customer company. They:
--   * create customer companies and invite each customer's first owner
--   * set branding, modules, plan, account status and station limit
--   * create stations + activation codes to ship with each Pi
--   * see every station's health across all customers (the "fleet")
--   * pause a customer (their stations stop recording until resumed)
--
-- Operators are added by hand in the Supabase SQL editor (the private schema
-- isn't reachable from the API):
--   insert into private.platform_operators (user_id, name)
--   select id, 'Dez' from auth.users where email = 'g.ryan@sonoranpoint.com';
--
-- Operators can't read customers' equipment, employees or history through the
-- normal tables (RLS still applies); they get counts and station health only.
-- =====================================================================

create table private.platform_operators (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  name       text,
  created_at timestamptz not null default now()
);

create function private.is_platform_operator()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from private.platform_operators where user_id = auth.uid())
$$;

create function private.require_operator()
returns void language plpgsql stable security definer set search_path = public as $$
begin
  if not private.is_platform_operator() then raise exception 'not allowed' using errcode = '42501'; end if;
end $$;

-- What operators did, for your own records.
create table private.platform_log (
  id         bigint generated always as identity primary key,
  at         timestamptz not null default now(),
  operator   uuid references auth.users(id) on delete set null,
  org_id     uuid references public.organizations(id) on delete set null,
  action     text not null,
  details    jsonb not null default '{}'
);
create function private.plog(p_org uuid, p_action text, p_details jsonb default '{}')
returns void language sql security definer set search_path = public as $$
  insert into private.platform_log (operator, org_id, action, details) values (auth.uid(), p_org, p_action, coalesce(p_details, '{}'))
$$;

-- ---------------------------------------------------------------------
-- Account fields on each customer. Customers can't change these: the
-- column-level update grant for organizations doesn't include them.
-- ---------------------------------------------------------------------
create type public.account_status as enum ('trial', 'active', 'paused', 'cancelled');

alter table public.organizations
  add column status         public.account_status not null default 'active',
  add column plan           text not null default 'standard' check (length(plan) between 1 and 40),
  add column trial_ends_at  timestamptz,
  add column station_limit  int check (station_limit is null or station_limit >= 0),   -- null = no limit
  add column contact_name   text,
  add column contact_email  text,
  add column contact_phone  text;

-- Your private notes on a customer: unreachable from the API, never shown to them.
create table private.customer_notes (
  org_id     uuid primary key references public.organizations(id) on delete cascade,
  notes      text not null,
  updated_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Paused / cancelled customers: their stations stop recording (taps stay
-- queued on the station and sync after the account is resumed) and say why,
-- instead of unpairing themselves.
-- ---------------------------------------------------------------------
create or replace function private.station_from_key(p_device_key text)
returns public.stations
language sql stable security definer set search_path = public as $$
  select s.* from public.stations s
  join private.station_keys k on k.station_id = s.id
  join public.organizations o on o.id = s.org_id
  where k.device_key_hash = private.sha256_hex(p_device_key)
    and s.activated_at is not null
    and s.revoked_at is null
    and o.status in ('trial', 'active')
$$;

create or replace function private.station_denied(p_device_key text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_status public.account_status;
begin
  select o.status into v_status from public.stations s
  join private.station_keys k on k.station_id = s.id
  join public.organizations o on o.id = s.org_id
  where k.device_key_hash = private.sha256_hex(p_device_key) and s.activated_at is not null and s.revoked_at is null;
  if v_status in ('paused', 'cancelled') then
    return jsonb_build_object('ok', false, 'error', 'account_paused');
  end if;
  return jsonb_build_object('ok', false, 'error', 'station_not_authorized');
end $$;

-- ---------------------------------------------------------------------
-- New companies are created by you, not by anyone who signs up.
-- ---------------------------------------------------------------------
create or replace function public.create_organization(p_name text, p_slug text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_org uuid;
begin
  perform private.require_operator();
  insert into public.organizations (name, slug) values (p_name, lower(p_slug)) returning id into v_org;
  insert into public.org_members (org_id, user_id, role) values (v_org, auth.uid(), 'owner');
  return v_org;
end $$;

-- Station limit applies when a customer adds stations themselves.
create or replace function public.create_station(p_org uuid, p_name text, p_location uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_station uuid; v_code text := private.new_activation_code(); v_limit int;
begin
  if not private.has_org_role(p_org, 'admin') and not private.is_platform_operator() then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  select station_limit into v_limit from public.organizations where id = p_org;
  if v_limit is not null and not private.is_platform_operator()
     and (select count(*) from public.stations where org_id = p_org and revoked_at is null) >= v_limit then
    return jsonb_build_object('ok', false, 'error', 'station_limit', 'limit', v_limit);
  end if;
  insert into public.stations (org_id, name, location_id) values (p_org, p_name, p_location) returning id into v_station;
  insert into private.station_keys (station_id, activation_code_hash, activation_expires_at)
  values (v_station, private.sha256_hex(private.normalize_code(v_code)), now() + interval '7 days');
  return jsonb_build_object('ok', true, 'station_id', v_station, 'activation_code', v_code,
                            'expires_at', now() + interval '7 days');
end $$;

-- ---------------------------------------------------------------------
-- Operator functions
-- ---------------------------------------------------------------------

-- One row per customer, with the numbers you care about.
create function public.platform_customers()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform private.require_operator();
  return coalesce((select jsonb_agg(row_to_json(c)::jsonb order by c.name) from (
    select o.id, o.name, o.slug, o.status, o.plan, o.trial_ends_at, o.station_limit, o.enabled_modules,
           o.primary_color, o.accent_color, o.logo_url, o.contact_name, o.contact_email, o.created_at,
           (select count(*) from public.stations s where s.org_id = o.id and s.revoked_at is null) as stations,
           (select count(*) from public.stations s where s.org_id = o.id and s.revoked_at is null
              and s.activated_at is not null and s.last_seen_at > now() - interval '5 minutes') as stations_online,
           (select count(*) from public.stations s where s.org_id = o.id and s.revoked_at is null and s.activated_at is null) as stations_waiting,
           (select count(*) from public.employees e where e.org_id = o.id and e.active) as employees,
           (select count(*) from public.equipment q where q.org_id = o.id and q.status <> 'retired') as equipment,
           (select count(*) from public.transactions t where t.org_id = o.id and t.occurred_at > now() - interval '7 days') as taps_7d,
           (select max(t.occurred_at) from public.transactions t where t.org_id = o.id) as last_tap_at,
           (select count(*) from public.org_members m where m.org_id = o.id) as members,
           exists (select 1 from public.org_members m where m.org_id = o.id and m.role = 'owner') as has_owner
    from public.organizations o) c), '[]'::jsonb);
end $$;

-- One customer: account, branding, stations, team. Not their equipment or people.
create function public.platform_customer(p_org uuid)
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
    'members', coalesce((select jsonb_agg(jsonb_build_object('email', u.email, 'role', m.role, 'last_sign_in_at', u.last_sign_in_at)
        order by m.role desc, u.email)
      from public.org_members m join auth.users u on u.id = m.user_id where m.org_id = p_org), '[]'::jsonb),
    'invites', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'email', i.email, 'role', i.role, 'expires_at', i.expires_at))
      from public.org_invites i where i.org_id = p_org and i.accepted_at is null and i.expires_at > now()), '[]'::jsonb),
    'log', coalesce((select jsonb_agg(jsonb_build_object('at', g.at, 'action', g.action, 'details', g.details,
        'by', coalesce(po.name, u.email)) order by g.at desc)
      from (select * from private.platform_log where org_id = p_org order by at desc limit 50) g
      left join private.platform_operators po on po.user_id = g.operator left join auth.users u on u.id = g.operator), '[]'::jsonb));
end $$;

create function private.owner_invite(p_org uuid, p_email text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_email text := lower(trim(p_email)); v_token text := encode(extensions.gen_random_bytes(24), 'hex');
begin
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then return jsonb_build_object('ok', false, 'error', 'bad_email'); end if;
  if exists (select 1 from public.org_members m join auth.users u on u.id = m.user_id where m.org_id = p_org and lower(u.email) = v_email) then
    return jsonb_build_object('ok', false, 'error', 'already_member');
  end if;
  delete from public.org_invites where org_id = p_org and email = v_email and accepted_at is null;
  insert into public.org_invites (org_id, email, role, invited_by, token_hash)
  values (p_org, v_email, 'owner', auth.uid(), private.sha256_hex(v_token));
  return jsonb_build_object('ok', true, 'email', v_email, 'token', v_token, 'expires_at', now() + interval '14 days');
end $$;

-- New customer in one step. Returns the owner's invite token (the API layer
-- emails the link) and one activation code per station to ship.
create function public.platform_create_customer(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_org uuid; v_inv jsonb; v_st jsonb := '[]'; v_name text; v_slug text; r jsonb;
begin
  perform private.require_operator();
  v_name := trim(p->>'name'); v_slug := lower(trim(p->>'slug'));
  if coalesce(v_name, '') = '' then return jsonb_build_object('ok', false, 'error', 'name_required'); end if;
  if v_slug !~ '^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$' then return jsonb_build_object('ok', false, 'error', 'bad_slug'); end if;
  if exists (select 1 from public.organizations where slug = v_slug) then return jsonb_build_object('ok', false, 'error', 'slug_taken'); end if;
  if (p->>'owner_email') is null or (p->>'owner_email') !~ '^\s*[^@\s]+@[^@\s]+\.[^@\s]+\s*$' then
    return jsonb_build_object('ok', false, 'error', 'bad_email');
  end if;

  insert into public.organizations (name, slug, timezone, primary_color, accent_color, logo_url, terminology,
                                    enabled_modules, status, plan, trial_ends_at, station_limit,
                                    contact_name, contact_email, contact_phone)
  values (v_name, v_slug, coalesce(p->>'timezone', 'America/Phoenix'),
          coalesce(p->>'primary_color', '#1F4E79'), coalesce(p->>'accent_color', '#F2A900'), nullif(p->>'logo_url', ''),
          '{"equipment":"Equipment","equipment_plural":"Equipment","employee":"Employee","employee_plural":"Employees","checkout":"Check Out","checkin":"Return"}'::jsonb
            || coalesce(p->'terminology', '{}'::jsonb),
          coalesce(array(select jsonb_array_elements_text(p->'modules')), '{}'),
          coalesce((p->>'status')::public.account_status, 'trial'), coalesce(nullif(p->>'plan', ''), 'standard'),
          case when coalesce(p->>'status', 'trial') = 'trial' then now() + make_interval(days => coalesce((p->>'trial_days')::int, 30)) end,
          (p->>'station_limit')::int,
          nullif(p->>'contact_name', ''), nullif(lower(trim(p->>'contact_email')), ''), nullif(p->>'contact_phone', ''))
  returning id into v_org;
  if coalesce(trim(p->>'notes'), '') <> '' then insert into private.customer_notes (org_id, notes) values (v_org, trim(p->>'notes')); end if;

  v_inv := private.owner_invite(v_org, p->>'owner_email');
  for r in select value from jsonb_array_elements(coalesce(p->'stations', '[]'::jsonb)) loop
    v_st := v_st || jsonb_build_array(public.create_station(v_org, coalesce(nullif(trim(r #>> '{}'), ''), 'Station')) - 'ok'
                                      || jsonb_build_object('name', coalesce(nullif(trim(r #>> '{}'), ''), 'Station')));
  end loop;
  perform private.plog(v_org, 'created customer', jsonb_build_object('name', v_name, 'stations', jsonb_array_length(v_st), 'owner', v_inv->>'email'));
  return jsonb_build_object('ok', true, 'org_id', v_org, 'owner_invite', v_inv, 'stations', v_st);
end $$;

-- Change any account/branding field. Only keys present in p are changed.
create function public.platform_update_customer(p_org uuid, p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare o public.organizations;
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
  if p ? 'notes' then
    if coalesce(trim(p->>'notes'), '') = '' then delete from private.customer_notes where org_id = p_org;
    else insert into private.customer_notes (org_id, notes) values (p_org, trim(p->>'notes'))
         on conflict (org_id) do update set notes = excluded.notes, updated_at = now(); end if;
  end if;
  perform private.plog(p_org,
    case when p ? 'status' and (p->>'status') is distinct from o.status::text then 'status: ' || (p->>'status') else 'updated customer' end,
    p - 'notes');
  return jsonb_build_object('ok', true);
end $$;

create function public.platform_invite_owner(p_org uuid, p_email text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r jsonb;
begin
  perform private.require_operator();
  r := private.owner_invite(p_org, p_email);
  if (r->>'ok')::boolean then perform private.plog(p_org, 'invited owner', jsonb_build_object('email', r->>'email')); end if;
  return r;
end $$;

create function public.platform_add_station(p_org uuid, p_name text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r jsonb;
begin
  perform private.require_operator();
  r := public.create_station(p_org, p_name);
  perform private.plog(p_org, 'added station', jsonb_build_object('name', p_name));
  return r;
end $$;

create function public.platform_station_code(p_station uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_org uuid; v_code text := private.new_activation_code();
begin
  perform private.require_operator();
  select org_id into v_org from public.stations where id = p_station;
  if v_org is null then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  update private.station_keys set device_key_hash = null,
    activation_code_hash = private.sha256_hex(private.normalize_code(v_code)), activation_expires_at = now() + interval '7 days'
  where station_id = p_station;
  update public.stations set activated_at = null, revoked_at = null, admin_claimed_at = null where id = p_station;
  perform private.plog(v_org, 'new activation code', jsonb_build_object('station', (select name from public.stations where id = p_station)));
  return jsonb_build_object('ok', true, 'station_id', p_station, 'activation_code', v_code, 'expires_at', now() + interval '7 days');
end $$;

create function public.platform_revoke_station(p_station uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_org uuid;
begin
  perform private.require_operator();
  select org_id into v_org from public.stations where id = p_station;
  if v_org is null then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  update private.station_keys set device_key_hash = null, activation_code_hash = null where station_id = p_station;
  update public.stations set revoked_at = now() where id = p_station;
  perform private.plog(v_org, 'disconnected station', jsonb_build_object('station', (select name from public.stations where id = p_station)));
  return jsonb_build_object('ok', true);
end $$;

-- Every station at every customer: is it up?
create function public.platform_fleet()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform private.require_operator();
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', s.id, 'name', s.name, 'org_id', o.id, 'customer', o.name, 'customer_status', o.status, 'location', l.name,
      'activated_at', s.activated_at, 'last_seen_at', s.last_seen_at, 'software_version', s.software_version,
      'admin_claimed_at', s.admin_claimed_at, 'code_expires_at', k.activation_expires_at,
      'online', s.activated_at is not null and s.last_seen_at > now() - interval '5 minutes')
      order by o.name, s.name)
    from public.stations s join public.organizations o on o.id = s.org_id
    left join public.locations l on l.id = s.location_id left join private.station_keys k on k.station_id = s.id
    where s.revoked_at is null), '[]'::jsonb);
end $$;

create function public.platform_log(p_limit int default 200)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform private.require_operator();
  return coalesce((select jsonb_agg(jsonb_build_object('at', g.at, 'customer', o.name, 'org_id', g.org_id, 'action', g.action,
      'details', g.details, 'by', coalesce(po.name, u.email)) order by g.at desc)
    from (select * from private.platform_log order by at desc limit least(p_limit, 1000)) g
    left join public.organizations o on o.id = g.org_id
    left join private.platform_operators po on po.user_id = g.operator left join auth.users u on u.id = g.operator), '[]'::jsonb);
end $$;

-- Lets the console know whether to show itself.
create function public.am_platform_operator()
returns boolean language sql stable security definer set search_path = public as $$
  select private.is_platform_operator()
$$;

-- Private tables: no API access at all (RLS on with no policies; only this file's
-- security-definer functions, which run as the table owner, can read or write them).
alter table private.platform_operators enable row level security;
alter table private.platform_log       enable row level security;
alter table private.customer_notes     enable row level security;
revoke all on private.platform_operators, private.platform_log, private.customer_notes from public, anon, authenticated;

-- ---------------------------------------------------------------------
revoke execute on all functions in schema private from public, anon, authenticated;
grant  execute on function private.has_org_role(uuid, public.member_role) to authenticated;
grant  execute on function private.normalize_uid(text) to anon, authenticated;
grant  execute on function private.resolve_time_limit(public.time_limit_mode, numeric, public.time_limit_type, numeric) to authenticated;

revoke execute on function public.platform_customers(), public.platform_customer(uuid), public.platform_create_customer(jsonb),
  public.platform_update_customer(uuid, jsonb), public.platform_invite_owner(uuid, text), public.platform_add_station(uuid, text),
  public.platform_station_code(uuid), public.platform_revoke_station(uuid), public.platform_fleet(), public.platform_log(int),
  public.am_platform_operator() from public;
grant execute on function public.platform_customers(), public.platform_customer(uuid), public.platform_create_customer(jsonb),
  public.platform_update_customer(uuid, jsonb), public.platform_invite_owner(uuid, text), public.platform_add_station(uuid, text),
  public.platform_station_code(uuid), public.platform_revoke_station(uuid), public.platform_fleet(), public.platform_log(int),
  public.am_platform_operator() to authenticated;
