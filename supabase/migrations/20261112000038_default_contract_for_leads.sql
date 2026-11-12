-- Migration 38: things a contract Admin or lead adds go into their own contract when they don't pick one.
-- (Someone limited to contracts can't add things to the whole company, so before this a new station they made
-- landed outside what they can see, and an item or person without a contract was refused.)
-- Their first contract is used (the order they were given them doesn't matter much: most have one).

create or replace function private.default_contract_for_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.contract_id is null and auth.uid() is not null and private.has_org_role(new.org_id)
     and private.scope_of(new.org_id, auth.uid()) is not null then
    new.contract_id := (select mc.contract_id from public.member_contracts mc join public.contracts c on c.id = mc.contract_id
                        where mc.org_id = new.org_id and mc.user_id = auth.uid() order by c.sort_order, c.name limit 1);
  end if;
  return new;
end $$;

drop trigger if exists default_contract_for_user on public.stations;
create trigger default_contract_for_user before insert on public.stations for each row execute function private.default_contract_for_user();
drop trigger if exists default_contract_for_user on public.equipment;
create trigger default_contract_for_user before insert on public.equipment for each row execute function private.default_contract_for_user();
drop trigger if exists default_contract_for_user on public.employees;
create trigger default_contract_for_user before insert on public.employees for each row execute function private.default_contract_for_user();
drop trigger if exists default_contract_for_user on public.shifts;
create trigger default_contract_for_user before insert on public.shifts for each row execute function private.default_contract_for_user();

revoke execute on function private.default_contract_for_user() from public, anon, authenticated;
