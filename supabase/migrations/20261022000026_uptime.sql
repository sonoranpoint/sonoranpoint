-- =====================================================================
-- 26: Station uptime history
--   Every station sends a heartbeat every 10 seconds. When one comes back after more than 5 minutes
--   of silence, the gap is saved as an outage (from its last heartbeat to its first one back), so
--   the console and dashboard can show real uptime instead of a snapshot. A station that's offline
--   right now is the open stretch since its last heartbeat (worked out when reading, not stored).
--   Time a station spends disconnected, or before it's set up, isn't counted as an outage.
-- =====================================================================
create table public.station_outages (
  id          bigint generated always as identity primary key,
  org_id      uuid not null references public.organizations(id) on delete cascade,
  station_id  uuid not null references public.stations(id) on delete cascade,
  started_at  timestamptz not null,
  ended_at    timestamptz not null,
  check (ended_at > started_at)
);
create index on public.station_outages (station_id, ended_at desc);
create index on public.station_outages (org_id, ended_at desc);
alter table public.station_outages enable row level security;
create policy station_outages_select on public.station_outages for select to authenticated
  using (private.can_see(org_id, (select contract_id from public.stations where id = station_id)));
revoke insert, update, delete on public.station_outages from anon, authenticated;

create function private.record_outage()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.station_outages (org_id, station_id, started_at, ended_at) values (new.org_id, new.id, old.last_seen_at, new.last_seen_at);
  return null;
end $$;
create trigger record_outage after update of last_seen_at on public.stations for each row
  when (old.last_seen_at is not null and new.last_seen_at > old.last_seen_at + interval '5 minutes'
        and old.revoked_at is null and new.activated_at is not distinct from old.activated_at and new.activated_at is not null)
  execute function private.record_outage();

-- Console: outages since a time (default: the last 7 days), for every station.
create function public.platform_outages(p_since timestamptz default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform private.require_operator();
  return coalesce((select jsonb_agg(jsonb_build_object('station_id', station_id, 'started_at', started_at, 'ended_at', ended_at) order by started_at)
    from public.station_outages where ended_at > coalesce(p_since, now() - interval '7 days')), '[]'::jsonb);
end $$;

revoke execute on all functions in schema private from public, anon, authenticated;
grant  execute on function private.has_org_role(uuid, public.member_role) to authenticated;
grant  execute on function private.normalize_uid(text) to anon, authenticated;
grant  execute on function private.resolve_time_limit(public.time_limit_mode, numeric, public.time_limit_type, numeric) to authenticated;
grant  execute on function private.can_manage_logo(text) to authenticated;
grant  execute on function private.can_see(uuid, uuid), private.can_see_equipment(uuid), private.can_see_txn(uuid, uuid, uuid, uuid),
  private.can_see_tap(uuid, uuid, uuid, uuid), private.sees(uuid, uuid, uuid), private.scope_of(uuid, uuid) to authenticated;
revoke execute on function public.platform_outages(timestamptz) from public;
grant  execute on function public.platform_outages(timestamptz) to authenticated;
