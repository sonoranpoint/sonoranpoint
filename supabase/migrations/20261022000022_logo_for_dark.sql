-- =====================================================================
-- 22: A light version of a customer's logo, for dark backgrounds
--   * The dashboard's sidebar is dark blue when the company has a light logo (shown on it), and
--     light when it doesn't (their normal logo or name on white).
--   * Customers add it in Settings next to their logo; you can set it from the console.
-- =====================================================================
alter table public.organizations add column logo_dark_url text check (logo_dark_url is null or length(logo_dark_url) <= 1000);
grant update (logo_dark_url) on public.organizations to authenticated;

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
    logo_dark_url   = case when p ? 'logo_dark_url' then nullif(p->>'logo_dark_url', '') else logo_dark_url end,
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
grant  execute on function private.can_manage_logo(text) to authenticated;
grant  execute on function private.can_see(uuid, uuid), private.can_see_equipment(uuid), private.can_see_txn(uuid, uuid, uuid, uuid),
  private.can_see_tap(uuid, uuid, uuid, uuid), private.sees(uuid, uuid, uuid), private.scope_of(uuid, uuid) to authenticated;
