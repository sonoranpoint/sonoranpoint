-- =====================================================================
-- New customers start in Sonoran Point colors (night navy + sunset orange).
-- Existing customers keep whatever they have.
-- =====================================================================
alter table public.organizations alter column primary_color set default '#0B2350';
alter table public.organizations alter column accent_color  set default '#F7931E';

create or replace function public.platform_create_customer(p jsonb)
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

  v_inv := private.owner_invite(v_org, p->>'owner_email');
  for r in select value from jsonb_array_elements(coalesce(p->'stations', '[]'::jsonb)) loop
    v_st := v_st || jsonb_build_array(public.create_station(v_org, coalesce(nullif(trim(r #>> '{}'), ''), 'Station')) - 'ok'
                                      || jsonb_build_object('name', coalesce(nullif(trim(r #>> '{}'), ''), 'Station')));
  end loop;
  perform private.plog(v_org, 'created customer', jsonb_build_object('name', v_name, 'stations', jsonb_array_length(v_st), 'owner', v_inv->>'email'));
  return jsonb_build_object('ok', true, 'org_id', v_org, 'owner_invite', v_inv, 'stations', v_st);
end $$;

revoke execute on function public.platform_create_customer(jsonb) from public;
grant  execute on function public.platform_create_customer(jsonb) to authenticated;
