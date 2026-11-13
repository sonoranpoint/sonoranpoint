-- Migration 44: shift names only need to be different within a contract.
-- Before this a name was unique across the whole company, so a Delta BW lead couldn't make a "PM" shift when
-- another contract (or the whole company) already had one they can't see.

alter table public.shifts drop constraint if exists shifts_org_id_name_key;
create unique index if not exists shifts_name on public.shifts
  (org_id, coalesce(contract_id, '00000000-0000-0000-0000-000000000000'::uuid), btrim(name));
