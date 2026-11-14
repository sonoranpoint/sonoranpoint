-- Migration 45: customers agree to our Terms of Service and Privacy Policy.
--
-- * Sonoran Point publishes versions of the terms (private.terms_versions). Small changes just get a new version; a version
--   marked must_accept means customers have to agree again.
-- * The first Admin or Manager of a company to sign in after a must_accept version is published agrees on behalf of the company
--   (dashboard gate). Each agreement is kept with who, which version, when, IP address and browser, as proof.
-- * Nothing is asked until the first version is published from the console.

create table if not exists private.terms_versions (
  version text primary key check (version ~ '^[0-9A-Za-z.\-]{1,20}$'),
  published_at timestamptz not null default now(),
  must_accept boolean not null default false,
  notes text check (notes is null or length(notes) <= 500),
  published_by uuid references auth.users(id) on delete set null
);

create table if not exists private.terms_acceptances (
  id bigserial primary key,
  org_id uuid not null references public.organizations(id) on delete cascade,
  version text not null references private.terms_versions(version),
  user_id uuid references auth.users(id) on delete set null,
  name text,
  email text,
  accepted_at timestamptz not null default now(),
  ip text,
  user_agent text
);
create index if not exists terms_acceptances_org on private.terms_acceptances (org_id, accepted_at desc);

-- Where a company stands: the newest version, the newest one they must have agreed to, and their last agreement.
create or replace function private.terms_state(p_org uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  with cur as (select * from private.terms_versions order by published_at desc limit 1),
       req as (select * from private.terms_versions where must_accept order by published_at desc limit 1),
       acc as (select a.*, v.published_at v_at from private.terms_acceptances a join private.terms_versions v on v.version = a.version
               where a.org_id = p_org order by a.accepted_at desc limit 1)
  select jsonb_build_object(
    'current', (select version from cur), 'current_at', (select published_at from cur),
    'required', (select version from req), 'notes', (select notes from req),
    'accepted', (select jsonb_build_object('version', version, 'at', accepted_at, 'name', name, 'email', email) from acc),
    'needs', exists (select 1 from req) and not exists (select 1 from acc where acc.v_at >= (select published_at from req)))
$$;

-- For the dashboard: whether this company still has to agree, and whether the signed-in person can do it (Admins and Managers).
create or replace function public.terms_status(p_org uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not private.has_org_role(p_org) then raise exception 'not allowed' using errcode = '42501'; end if;
  return private.terms_state(p_org) || jsonb_build_object('can_accept', private.has_org_role(p_org, 'admin'));
end $$;

create or replace function public.accept_terms(p_org uuid, p_version text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare h json; u auth.users;
begin
  if not private.has_org_role(p_org, 'admin') then raise exception 'not allowed' using errcode = '42501'; end if;
  if not exists (select 1 from private.terms_versions where version = p_version) then return jsonb_build_object('ok', false, 'error', 'unknown_version'); end if;
  begin h := nullif(current_setting('request.headers', true), '')::json; exception when others then h := null; end;
  select * into u from auth.users where id = auth.uid();
  insert into private.terms_acceptances (org_id, version, user_id, name, email, ip, user_agent)
  values (p_org, p_version, auth.uid(), coalesce(u.raw_user_meta_data->>'full_name', u.email), u.email,
          left(btrim(split_part(coalesce(h->>'cf-connecting-ip', h->>'x-forwarded-for', h->>'x-real-ip', ''), ',', 1)), 64),
          left(h->>'user-agent', 300));
  return jsonb_build_object('ok', true);
end $$;

-- Console: the versions, and publishing a new one (owners).
create or replace function public.platform_terms()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform private.require_operator();
  return jsonb_build_object(
    'versions', coalesce((select jsonb_agg(jsonb_build_object('version', v.version, 'published_at', v.published_at, 'must_accept', v.must_accept, 'notes', v.notes,
        'by', (select coalesce(raw_user_meta_data->>'full_name', email) from auth.users where id = v.published_by),
        'accepted', (select count(distinct org_id) from private.terms_acceptances a where a.version = v.version)) order by v.published_at desc)
      from private.terms_versions v), '[]'::jsonb),
    'waiting', (select count(*) from public.organizations o where o.status <> 'cancelled' and (private.terms_state(o.id)->>'needs')::boolean));
end $$;

create or replace function public.platform_publish_terms(p_version text, p_must_accept boolean default false, p_notes text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform private.require_platform_owner();
  p_version := btrim(coalesce(p_version, ''));
  if p_version !~ '^[0-9A-Za-z.\-]{1,20}$' then return jsonb_build_object('ok', false, 'error', 'bad_version'); end if;
  if exists (select 1 from private.terms_versions where version = p_version) then return jsonb_build_object('ok', false, 'error', 'version_exists'); end if;
  -- The very first version is always one customers must agree to.
  insert into private.terms_versions (version, must_accept, notes, published_by)
  values (p_version, coalesce(p_must_accept, false) or not exists (select 1 from private.terms_versions), nullif(btrim(coalesce(p_notes, '')), ''), auth.uid());
  perform private.plog(null, 'published terms', jsonb_build_object('version', p_version, 'text', case when (select must_accept from private.terms_versions where version = p_version)
    then 'customers must agree again' else 'no new agreement needed' end));
  return jsonb_build_object('ok', true);
end $$;

-- Console: one customer's agreements.
create or replace function public.platform_customer_terms(p_org uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform private.require_operator();
  return private.terms_state(p_org) || jsonb_build_object('history', coalesce((select jsonb_agg(jsonb_build_object('version', version, 'at', accepted_at,
      'name', name, 'email', email, 'ip', ip) order by accepted_at desc) from private.terms_acceptances where org_id = p_org), '[]'::jsonb));
end $$;

revoke all on private.terms_versions, private.terms_acceptances from public, anon, authenticated;
revoke execute on function private.terms_state(uuid) from public, anon, authenticated;
revoke execute on function public.terms_status(uuid), public.accept_terms(uuid, text), public.platform_terms(),
  public.platform_publish_terms(text, boolean, text), public.platform_customer_terms(uuid) from public, anon;
grant execute on function public.terms_status(uuid), public.accept_terms(uuid, text), public.platform_terms(),
  public.platform_publish_terms(text, boolean, text), public.platform_customer_terms(uuid) to authenticated;
