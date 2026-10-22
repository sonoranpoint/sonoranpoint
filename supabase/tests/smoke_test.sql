-- Scenario tests. Run on a fresh DB after local_supabase_stub.sql, the migration and seed.sql:
--   psql -v ON_ERROR_STOP=1 -d <db> -f tests/smoke_test.sql
\set QUIET on
\pset tuples_only on
\pset format unaligned

create function pg_temp.ok(cond boolean, msg text) returns text language plpgsql as $$
begin
  if cond is distinct from true then raise exception 'FAIL: %', msg; end if;
  return 'pass  ' || msg;
end $$;

-- Two dashboard users: A owns the demo company, B will make their own company.
insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'owner-a@example.com'),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'owner-b@example.com'),
  ('cccccccc-0000-0000-0000-000000000003', 'viewer@example.com');
insert into org_members (org_id, user_id, role) values
  ('00000000-0000-0000-0000-00000000d3e0', 'aaaaaaaa-0000-0000-0000-000000000001', 'owner'),
  ('00000000-0000-0000-0000-00000000d3e0', 'cccccccc-0000-0000-0000-000000000003', 'viewer');

\echo '--- Station activation'
set role anon;
select pg_temp.ok((activate_station('WRONG-CODE')->>'ok')::boolean = false, 'wrong activation code rejected');
select activate_station('demo 0001', 'station-0.1.0') as act \gset
select pg_temp.ok((:'act'::jsonb->>'ok')::boolean, 'activation code works (any case/spacing)');
select :'act'::jsonb->>'device_key' as key \gset
select pg_temp.ok(:'act'::jsonb->'organization'->>'name' = 'Demo Air Services', 'activation returns company branding');
select pg_temp.ok(jsonb_array_length(:'act'::jsonb->'categories') = 6, 'activation returns 6 categories');
select pg_temp.ok((activate_station('DEMO-0001')->>'ok')::boolean = false, 'activation code is single-use');
select pg_temp.ok((station_config('not-a-real-key')->>'ok')::boolean = false, 'bad device key rejected');
select pg_temp.ok(jsonb_array_length(station_sync_cache(:'key')->'employees') = 5, 'offline cache has 5 badges (3 staff + manager + admin fobs)');

\echo '--- Checkout and return'
select station_tap(:'key', '11111111-0000-0000-0000-000000000001', '04:ba:00:00:00:01', '04DE000101') as r \gset
select pg_temp.ok(:'r'::jsonb->>'action' = 'checkout', 'Alex taps Vacuum 01 -> checkout');
select pg_temp.ok(:'r'::jsonb->>'due_at' is not null, 'due time set from category (8h)');
select pg_temp.ok(:'r'::jsonb->'flags' = '[]'::jsonb, 'no flags on a clean checkout');
select station_tap(:'key', '11111111-0000-0000-0000-000000000001', '04:ba:00:00:00:01', '04DE000101') as r \gset
select pg_temp.ok((:'r'::jsonb->>'duplicate')::boolean, 're-upload of same event is a harmless duplicate');
select station_tap(:'key', '11111111-0000-0000-0000-000000000002', '04BA00000001', '04DE000101') as r \gset
select pg_temp.ok(:'r'::jsonb->>'action' = 'checkin', 'Alex taps it again -> return');

\echo '--- Someone else has it: return it for them, never grab it'
select station_tap(:'key', '11111111-0000-0000-0000-000000000003', '04BA00000002', '04DE000501') as r \gset
select pg_temp.ok(:'r'::jsonb->>'action' = 'checkout', 'Jordan checks out Radio 01');
select station_tap(:'key', gen_random_uuid(), '04BA00000001', '04DE000501', null, 'checkout') as r \gset
select pg_temp.ok(:'r'::jsonb->>'error' = 'checked_out_to_other' and :'r'::jsonb->'holder'->>'name' = 'Jordan Lee',
                  'Alex tries to check out Jordan''s radio -> refused, names Jordan');
reset role;
select pg_temp.ok((select count(*) from transactions t join equipment e on e.id = t.equipment_id where e.nfc_uid = '04DE000501') = 1,
                  'refused tap is not recorded');
set role anon;
select station_tap(:'key', gen_random_uuid(), '04BA00000003', '04DE000501') as r \gset
select pg_temp.ok(:'r'::jsonb->>'action' = 'checkin' and :'r'::jsonb->'flags' ? 'returned_by_other'
                  and :'r'::jsonb->'previous_holder'->>'name' = 'Jordan Lee',
                  'Sam taps Jordan''s radio -> returns it for Jordan (response names Jordan)');
select station_tap(:'key', gen_random_uuid(), '04BA00000003', '04DE000501') as r \gset
select pg_temp.ok(:'r'::jsonb->>'action' = 'checkout', 'Sam taps it again -> now checked out to Sam');
reset role;
update organizations set settings = settings || '{"allow_return_by_other": false}' where slug = 'demo';
set role anon;
select station_tap(:'key', gen_random_uuid(), '04BA00000001', '04DE000501') as r \gset
select pg_temp.ok(:'r'::jsonb->>'error' = 'checked_out_to_other',
                  'company turns off returning for others -> Alex''s tap is refused');
select station_tap(:'key', gen_random_uuid(), '04BA00000001', '04DE000501', now(), 'checkout', true) as r \gset
select pg_temp.ok(:'r'::jsonb->>'action' = 'checkout' and :'r'::jsonb->'flags' ? 'conflict_already_held',
                  'a tap saved offline is still recorded (it already happened), flagged as a conflict');
reset role;
update organizations set settings = settings || '{"allow_return_by_other": true}' where slug = 'demo';
insert into equipment (org_id, category_id, name, nfc_uid)
select org_id, id, 'Radio 09', '04DE000509' from equipment_categories where name = 'Radio';
set role anon;
select pg_temp.ok((station_item_status(:'key', '04:de:00:05:01')->'holder'->>'name') = 'Alex Rivera'
                  and (station_item_status(:'key', '04DE000509')->'holder') = 'null'::jsonb
                  and (station_item_status(:'key', '04DE000509')->'equipment'->>'status') = 'available',
                  'tap an item with no badge -> shows who has it, or that it''s available');
select pg_temp.ok(station_item_status(:'key', 'FFFFFFFF')->>'error' = 'unknown_equipment', 'item lookup: unknown tag');
select pg_temp.ok((station_item_status('bad-key', '04DE000509')->>'error') = 'station_not_authorized', 'item lookup needs a valid station');

\echo '--- Lost and found, maintenance'
select station_tap(:'key', gen_random_uuid(), '04BA00000002', '04DE000509') \g /dev/null
reset role;
set role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false) \g /dev/null
select set_equipment_status((select id from equipment where nfc_uid = '04DE000509'), 'lost', 'Jordan lost it on the ramp') \g /dev/null
reset role;
set role anon;
select pg_temp.ok((station_item_status(:'key', '04DE000509')->'equipment'->>'status') = 'lost', 'supervisor marks Radio 09 lost');
select pg_temp.ok(station_tap(:'key', gen_random_uuid(), '04BA00000001', '04DE000509', null, 'checkout')->>'error' = 'item_lost',
                  'a lost item can''t be checked out');
select station_tap(:'key', gen_random_uuid(), '04BA00000003', '04DE000509') as r \gset
select pg_temp.ok(:'r'::jsonb->>'action' = 'checkin' and :'r'::jsonb->'flags' ? 'found_lost_item',
                  'Sam finds it and taps it -> returned as found');
select pg_temp.ok((station_item_status(:'key', '04DE000509')->'equipment'->>'status') = 'available'
                  and (station_item_status(:'key', '04DE000509')->'holder') = 'null'::jsonb,
                  'found item is back to available, nobody holds it');
reset role;
set role authenticated;
select set_equipment_status((select id from equipment where nfc_uid = '04DE000509'), 'maintenance') \g /dev/null
reset role;
set role anon;
select pg_temp.ok(station_tap(:'key', gen_random_uuid(), '04BA00000001', '04DE000509')->>'error' = 'item_unavailable',
                  'item in maintenance can''t be checked out');
reset role;
set role authenticated;
select set_equipment_status((select id from equipment where nfc_uid = '04DE000509'), 'available') \g /dev/null
select set_config('request.jwt.claim.sub', 'cccccccc-0000-0000-0000-000000000003', false) \g /dev/null
do $$ begin
  perform set_equipment_status((select id from equipment where nfc_uid = '04DE000509'), 'lost');
  raise exception 'FAIL: viewer marked lost';
exception when insufficient_privilege then null; end $$;
select pg_temp.ok(true, 'viewer cannot mark items lost');
reset role;
set role anon;
select pg_temp.ok(station_tap(:'key', gen_random_uuid(), '04BA00000001', '04DE000509')->>'action' = 'checkout',
                  'back in service -> can be checked out again');
select station_tap(:'key', gen_random_uuid(), '04BA00000001', '04DE000509') \g /dev/null
select pg_temp.ok((station_tap(:'key', gen_random_uuid(), '04BA00000099', '04DE000501')->>'error') = 'unknown_badge', 'unknown badge rejected');
select pg_temp.ok((station_tap(:'key', gen_random_uuid(), '04BA00000001', 'FFFFFFFF')->>'error') = 'unknown_equipment', 'unknown tag rejected');

\echo '--- Offline station catching up'
select station_tap(:'key', gen_random_uuid(), '04BA00000002', '04DE000201', now() - interval '10 minutes') as r \gset
select station_tap(:'key', gen_random_uuid(), '04BA00000001', '04DE000201', now() - interval '1 hour') as r \gset
select pg_temp.ok(:'r'::jsonb->'flags' ? 'late_sync', 'older event uploaded late is flagged late_sync');
select station_tap(:'key', gen_random_uuid(), '04BA00000003', '04DE000301', now() + interval '2 hours') as r \gset
select pg_temp.ok(:'r'::jsonb->'flags' ? 'clock_skew', 'event from the future is clamped + flagged');
reset role;
select pg_temp.ok((select trim(e.first_name) from equipment q join employees e on e.id = q.current_employee_id
                   where q.nfc_uid = '04DE000201') = 'Jordan', 'late event did NOT overwrite current holder of Blower 01');
select pg_temp.ok((select current_employee_id is null and status = 'available' from equipment where nfc_uid = '04DE000101'),
                  'Vacuum 01 back to available after return');

\echo '--- Data isolation between companies'
set role anon;
select pg_temp.ok((select count(*) from equipment) = 0, 'anonymous API key sees no equipment');
select pg_temp.ok((select count(*) from transactions) = 0, 'anonymous API key sees no history');
reset role;

-- Only platform operators create companies; make B one just long enough to create theirs.
set role authenticated;
select set_config('request.jwt.claim.sub', 'bbbbbbbb-0000-0000-0000-000000000002', false) \g /dev/null
do $$ begin perform create_organization('Sneaky Co', 'sneaky'); raise exception 'FAIL: anyone could create a company'; exception when insufficient_privilege then null; end $$;
reset role;
insert into private.platform_operators (user_id) values ('bbbbbbbb-0000-0000-0000-000000000002');
set role authenticated;
select create_organization('Other Ground Co', 'otherco') as org_b \gset
reset role;
delete from private.platform_operators;
set role authenticated;
select pg_temp.ok((select count(*) from equipment) = 0, 'company B sees none of company A''s equipment');
select pg_temp.ok((select count(*) from organizations) = 1, 'company B sees only its own company');
select pg_temp.ok((select count(*) from employees) = 0, 'company B sees none of company A''s employees');
update equipment set name = 'hacked' where org_id = '00000000-0000-0000-0000-00000000d3e0';
reset role;
select pg_temp.ok((select count(*) from equipment where name = 'hacked') = 0, 'company B cannot edit company A''s equipment');
set role authenticated;
do $$ begin
  perform create_station('00000000-0000-0000-0000-00000000d3e0', 'sneaky');
  raise exception 'FAIL: company B created a station in company A';
exception when insufficient_privilege then null; end $$;
select pg_temp.ok(true, 'company B cannot add a station to company A');

select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false) \g /dev/null
select pg_temp.ok((select count(*) from equipment) = 13, 'company A owner sees all 13 items');
select pg_temp.ok((select count(*) from equipment_overview where current_holder is not null) = 3, 'overview shows 3 items out');
select pg_temp.ok((select count(*) from transactions where flags && array['conflict_already_held','late_sync','clock_skew']) = 3,
                  'owner can list the 3 problem transactions');

\echo '--- Permissions inside a company'
do $$ begin
  update equipment set current_employee_id = null;
  raise exception 'FAIL: custody edited directly';
exception when insufficient_privilege then null; end $$;
select pg_temp.ok(true, 'nobody can edit custody columns directly (only taps / manual events)');
do $$ begin
  delete from transactions;
  raise exception 'FAIL: history deleted';
exception when insufficient_privilege then null; end $$;
select pg_temp.ok(true, 'checkout history cannot be deleted, even by the owner');
select dashboard_record_event((select id from equipment where nfc_uid = '04DE000501'),
                              (select id from employees where employee_number = 'E1003'),
                              'checkin', null, 'returned at desk') as r \gset
select pg_temp.ok(:'r'::jsonb->>'action' = 'checkin', 'owner can record a manual return');

select set_config('request.jwt.claim.sub', 'cccccccc-0000-0000-0000-000000000003', false) \g /dev/null
update equipment set name = 'viewer-edit';
select pg_temp.ok((select count(*) from equipment where name = 'viewer-edit') = 0, 'viewer cannot edit equipment');
do $$ begin
  perform dashboard_record_event((select id from equipment limit 1), (select id from employees limit 1), 'checkout');
  raise exception 'FAIL: viewer recorded event';
exception when insufficient_privilege then null; end $$;
select pg_temp.ok(true, 'viewer cannot record checkouts');
reset role;

\echo '--- Time limits: per category and per item'
-- Van Keys category has its limit turned off; give Van Keys 02 its own 2h limit;
-- set Vacuum 02 to "no limit" even though Vacuums are 8h.
update equipment set time_limit_mode = 'hours', checkout_hours = 2 where nfc_uid = '04DE000602';
update equipment set time_limit_mode = 'none' where nfc_uid = '04DE000102';
set role anon;
select pg_temp.ok((station_tap(:'key', gen_random_uuid(), '04BA00000001', '04DE000601')->>'due_at') is null,
                  'category set to no limit -> no due time');
select station_tap(:'key', gen_random_uuid(), '04BA00000001', '04DE000602') as r \gset
select pg_temp.ok(abs(extract(epoch from ((:'r'::jsonb->>'due_at')::timestamptz - now())) - 7200) < 60,
                  'item with its own 2h -> due in 2h, even though its category has no limit');
select pg_temp.ok((station_tap(:'key', gen_random_uuid(), '04BA00000001', '04DE000102')->>'due_at') is null,
                  'item set to no limit -> no due time, even though Vacuums are 8h');
select station_tap(:'key', gen_random_uuid(), '04BA00000002', '04DE000401') as r \gset
select pg_temp.ok(abs(extract(epoch from ((:'r'::jsonb->>'due_at')::timestamptz - now())) - 36000) < 60,
                  'item following its category -> PDA 10h');
reset role;
select pg_temp.ok((select effective_checkout_hours from equipment_overview where asset_tag = 'VAN-002') = 2,
                  'dashboard overview shows each item''s effective limit');
do $$ begin
  update equipment set time_limit_mode = 'hours', checkout_hours = null where asset_tag = 'VAC-001';
  raise exception 'FAIL: item hours without a number accepted';
exception when check_violation then null; end $$;
select pg_temp.ok(true, 'item set to hours requires a number of hours');
do $$ begin
  update equipment_categories set time_limit_type = 'hours', default_checkout_hours = null where name = 'Radio';
  raise exception 'FAIL: enabled category without hours accepted';
exception when check_violation then null; end $$;
select pg_temp.ok(true, 'category set to hours requires a number of hours');

\echo '--- Shifts module: end-of-shift reports'
-- Demo shifts (Phoenix time): AM 05:00-13:30 (Alex, Jordan), Overnight 21:00-05:30 (Sam), PM (nobody). Grace 15 min.
select ((now() at time zone 'America/Phoenix')::date - 1) as d \gset
create function pg_temp.at(p_day date, p_time text) returns timestamptz language sql as
  $$ select (p_day + p_time::time) at time zone 'America/Phoenix' $$;
create function pg_temp.ev(p_tag text, p_emp text, p_action txn_action, p_when timestamptz) returns void language sql as $$
  select private.record_event('00000000-0000-0000-0000-00000000d3e0',
    (select id from equipment where nfc_uid = p_tag), (select id from employees where employee_number = p_emp),
    p_action, p_when, 'dashboard') $$;
insert into equipment (org_id, category_id, name, asset_tag, nfc_uid)
select org_id, id, 'Radio 03', 'RAD-003', '04DE000503' from equipment_categories where name = 'Radio';

-- AM shift on day D
select pg_temp.ev('04DE000302', 'E1001', 'checkout', pg_temp.at(:'d', '06:00')),   -- Battery 02: Alex, returned in time
       pg_temp.ev('04DE000302', 'E1001', 'checkin',  pg_temp.at(:'d', '12:00')),
       pg_temp.ev('04DE000402', 'E1001', 'checkout', pg_temp.at(:'d', '07:00')),   -- PDA 02: Alex, never returned
       pg_temp.ev('04DE000502', 'E1002', 'checkout', pg_temp.at(:'d', '08:00')),   -- Radio 02: Jordan, back at 15:00 (late)
       pg_temp.ev('04DE000502', 'E1002', 'checkin',  pg_temp.at(:'d', '15:00')),
       pg_temp.ev('04DE000202', 'E1002', 'checkout', pg_temp.at(:'d', '09:00')),   -- Blower 02: Jordan, Sam took it at 14:00
       pg_temp.ev('04DE000202', 'E1003', 'checkout', pg_temp.at(:'d', '14:00')),
       pg_temp.ev('04DE000401', 'E1002', 'checkout', pg_temp.at(:'d', '10:00')),   -- PDA 01: back at 13:40, inside grace
       pg_temp.ev('04DE000401', 'E1002', 'checkin',  pg_temp.at(:'d', '13:40')) \g /dev/null
-- Overnight shift starting D-1, ending D 05:30
select pg_temp.ev('04DE000503', 'E1003', 'checkout', pg_temp.at(:'d'::date - 1, '23:00')),  -- Radio 03: Sam, never returned
       pg_temp.ev('04DE000501', 'E1003', 'checkout', pg_temp.at(:'d'::date - 1, '23:30'))   -- Radio 01: uploaded late by a station
  \g /dev/null

select shift_report((select id from shifts where name = 'AM'), :'d') as am \gset
select pg_temp.ok((:'am'::jsonb->>'outstanding_count')::int = 3, 'AM report: 3 items not back by end of shift + grace');
select pg_temp.ok((:'am'::jsonb->>'still_out_count')::int = 1, 'AM report: 1 of them is still out');
select pg_temp.ok(exists (select 1 from jsonb_array_elements(:'am'::jsonb->'items') x
                  where x->>'equipment' = 'PDA 02' and x->>'outcome' = 'not_returned' and x->>'employee' = 'Alex Rivera'),
                  'PDA 02 -> not returned, Alex');
select pg_temp.ok(exists (select 1 from jsonb_array_elements(:'am'::jsonb->'items') x
                  where x->>'equipment' = 'Radio 02' and x->>'outcome' = 'returned_late' and x->>'resolved_by' = 'Jordan Lee'),
                  'Radio 02 -> returned late (15:00), by Jordan');
select pg_temp.ok(exists (select 1 from jsonb_array_elements(:'am'::jsonb->'items') x
                  where x->>'equipment' = 'Blower 02' and x->>'outcome' = 'taken_by_other' and x->>'resolved_by' = 'Sam Patel'),
                  'Blower 02 -> picked up by Sam after the shift');
select pg_temp.ok(not exists (select 1 from jsonb_array_elements(:'am'::jsonb->'items') x where x->>'equipment' in ('Battery 02', 'PDA 01')),
                  'items returned on time or within the grace period are not listed');
select shift_report((select id from shifts where name = 'Overnight'), :'d'::date - 1) as ov \gset
select pg_temp.ok((:'ov'::jsonb->>'outstanding_count')::int = 2
                  and exists (select 1 from jsonb_array_elements(:'ov'::jsonb->'items') x where x->>'equipment' = 'Radio 03' and x->>'outcome' = 'not_returned')
                  and exists (select 1 from jsonb_array_elements(:'ov'::jsonb->'items') x where x->>'equipment' = 'Radio 01'),
                  'overnight shift across midnight: Radio 03 + late-uploaded Radio 01');
select pg_temp.ok((shift_report((select id from shifts where name = 'PM'), :'d')->>'outstanding_count')::int = 0,
                  'shift with nobody assigned: empty report');

-- Automatic saved reports
update shifts set created_at = now() - interval '5 days';
select private.generate_shift_reports() > 0 as made \gset
select pg_temp.ok(:'made', 'scheduler saves reports for shifts that have ended');
select pg_temp.ok((select outstanding_count from shift_reports r join shifts s on s.id = r.shift_id
                   where s.name = 'AM' and r.shift_date = :'d') = 3, 'saved AM report matches');
select pg_temp.ok(private.generate_shift_reports() = 0, 'running the scheduler again creates no duplicates');

set role authenticated;
select set_config('request.jwt.claim.sub', 'cccccccc-0000-0000-0000-000000000003', false) \g /dev/null
do $$ begin
  perform acknowledge_shift_report((select id from shift_reports limit 1));
  raise exception 'FAIL: viewer signed off';
exception when insufficient_privilege then null; end $$;
select pg_temp.ok(true, 'viewer cannot sign off a report');
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false) \g /dev/null
select acknowledge_shift_report((select r.id from shift_reports r join shifts s on s.id = r.shift_id
                                 where s.name = 'AM' and r.shift_date = :'d'), 'PDA 02 found in van 4') \g /dev/null
select pg_temp.ok((select acknowledged_at is not null from shift_reports r join shifts s on s.id = r.shift_id
                   where s.name = 'AM' and r.shift_date = :'d'), 'supervisor/owner can sign off with a note');
do $$ begin
  update organizations set enabled_modules = array['shifts', 'everything'];
  raise exception 'FAIL: customer enabled modules';
exception when insufficient_privilege then null; end $$;
select pg_temp.ok(true, 'customers cannot switch on paid modules themselves');
update organizations set name = 'Demo Air Services' where slug = 'demo';
select pg_temp.ok(true, 'customers can still edit their own name/branding');
reset role;

-- Module off for company B
insert into shifts (org_id, name, start_time, end_time)
select id, 'Day', '06:00', '14:00' from organizations where slug = 'otherco';
set role authenticated;
select set_config('request.jwt.claim.sub', 'bbbbbbbb-0000-0000-0000-000000000002', false) \g /dev/null
select pg_temp.ok(shift_report((select id from shifts where name = 'Day'), :'d')->>'error' = 'module_not_enabled',
                  'company without the Shifts module gets no reports');
select pg_temp.ok((select count(*) from shifts) = 1 and (select count(*) from shift_reports) = 0,
                  'company B cannot see company A''s shifts or reports');
reset role;

\echo '--- Due at end of shift'
-- AM 05:00-13:30 (Alex, Jordan), Overnight 21:00-05:30 (Sam). Radios = end of shift, 10h fallback.
create function pg_temp.co(p_name text, p_emp text, p_when timestamptz) returns jsonb language sql as $$
  select private.record_event('00000000-0000-0000-0000-00000000d3e0',
    (select id from equipment where name = p_name), (select id from employees where employee_number = p_emp),
    'checkout', p_when, 'dashboard') $$;
insert into equipment (org_id, category_id, name, nfc_uid)
select org_id, id, n, null from equipment_categories, unnest(array['Radio 04','Radio 05','Radio 06','Radio 07','Radio 08']) n
where name = 'Radio';
insert into equipment (org_id, category_id, name, time_limit_mode)
select org_id, id, 'Vacuum 03', 'shift_end' from equipment_categories where name = 'Vacuum';
insert into equipment (org_id, category_id, name, time_limit_mode)
select org_id, id, 'Van Keys 03', 'shift_end' from equipment_categories where name = 'Van Keys';

select pg_temp.co('Radio 04', 'E1001', pg_temp.at(:'d', '09:00')) as r \gset
select pg_temp.ok((:'r'::jsonb->>'due_at')::timestamptz = pg_temp.at(:'d', '13:30') and :'r'::jsonb->>'due_rule' = 'shift_end',
                  'Alex (AM) takes a radio at 09:00 -> due 13:30, end of his shift');
select pg_temp.co('Radio 05', 'E1001', pg_temp.at(:'d', '04:30')) as r \gset
select pg_temp.ok((:'r'::jsonb->>'due_at')::timestamptz = pg_temp.at(:'d', '13:30'),
                  'grabbed at 04:30, before the 05:00 start -> still counts as the AM shift');
select pg_temp.co('Radio 06', 'E1003', pg_temp.at(:'d'::date - 1, '23:00')) as r \gset
select pg_temp.ok((:'r'::jsonb->>'due_at')::timestamptz = pg_temp.at(:'d', '05:30'),
                  'Sam (overnight) at 23:00 -> due 05:30 the next morning');
select pg_temp.co('Radio 07', 'E1001', pg_temp.at(:'d', '17:00')) as r \gset
select pg_temp.ok((:'r'::jsonb->>'due_at')::timestamptz = pg_temp.at(:'d', '17:00') + interval '10 hours'
                  and :'r'::jsonb->'flags' ? 'no_active_shift',
                  'Alex off shift at 17:00 -> falls back to 10h, flagged');
select pg_temp.co('Vacuum 03', 'E1002', pg_temp.at(:'d', '10:00')) as r \gset
select pg_temp.ok((:'r'::jsonb->>'due_at')::timestamptz = pg_temp.at(:'d', '13:30'),
                  'single item set to end of shift, even though Vacuums are 8h');
select pg_temp.co('Van Keys 03', 'E1001', pg_temp.at(:'d', '20:00')) as r \gset
select pg_temp.ok((:'r'::jsonb->>'due_at') is null and :'r'::jsonb->>'due_rule' = 'none',
                  'end of shift with no fallback hours + off shift -> no due time');
update organizations set enabled_modules = '{}' where slug = 'demo';
select pg_temp.co('Radio 08', 'E1001', pg_temp.at(:'d', '09:00')) as r \gset
select pg_temp.ok((:'r'::jsonb->>'due_at')::timestamptz = pg_temp.at(:'d', '09:00') + interval '10 hours',
                  'Shifts module off -> end-of-shift items use their fallback hours');
update organizations set enabled_modules = array['shifts'] where slug = 'demo';
select pg_temp.ok((select effective_time_limit from equipment_overview where name = 'Radio 04') = 'shift_end'
                  and (select effective_time_limit from equipment_overview where name = 'Vacuum 01') = 'hours',
                  'dashboard overview shows each item''s rule');

\echo '--- Out too long (extended checkout) alerts'
-- Company default 9h. Van Keys have no due time, so these test "extended" on its own.
insert into equipment (org_id, category_id, name)
select org_id, id, n from equipment_categories, unnest(array['Van Keys 04','Van Keys 05','Van Keys 06','Van Keys 07']) n
where name = 'Van Keys';
insert into equipment (org_id, category_id, name)
select org_id, id, 'Battery 03' from equipment_categories where name = 'Battery';
insert into equipment (org_id, category_id, name)
select org_id, id, 'Blower 03' from equipment_categories where name = 'Blower';
update equipment_categories set extended_alert_hours = 14 where name = 'Battery';   -- batteries: 14h
update equipment set extended_alert_hours = 2 where name = 'Van Keys 06';           -- this one item: 2h
select pg_temp.co('Van Keys 04', 'E1001', now() - interval '10 hours'),
       pg_temp.co('Van Keys 05', 'E1001', now() - interval '8 hours'),
       pg_temp.co('Van Keys 06', 'E1002', now() - interval '3 hours'),
       pg_temp.co('Battery 03',  'E1002', now() - interval '10 hours'),
       pg_temp.co('Blower 03',   'E1003', now() - interval '10 hours') \g /dev/null
select private.generate_equipment_alerts() \g /dev/null
create function pg_temp.has_alert(p_name text, p_kind text) returns boolean language sql as $$
  select exists (select 1 from equipment_alerts a join equipment e on e.id = a.equipment_id
                 where e.name = p_name and a.kind::text = p_kind and a.resolved_at is null) $$;
select pg_temp.ok(pg_temp.has_alert('Van Keys 04', 'extended_checkout'), 'out 10h (over the 9h default) -> extended alert');
select pg_temp.ok(not pg_temp.has_alert('Van Keys 05', 'extended_checkout'), 'out 8h -> no alert');
select pg_temp.ok(pg_temp.has_alert('Van Keys 06', 'extended_checkout'), 'item with its own 2h threshold, out 3h -> alert');
select pg_temp.ok(not pg_temp.has_alert('Battery 03', 'extended_checkout'), 'battery out 10h, category threshold 14h -> no alert');
select pg_temp.ok(pg_temp.has_alert('Blower 03', 'extended_checkout') and pg_temp.has_alert('Blower 03', 'overdue'),
                  'blower out 10h with an 8h due time -> extended AND overdue alerts');
select pg_temp.ok((select is_extended and hours_out between 9.9 and 10.1 from equipment_overview where name = 'Van Keys 04'),
                  'dashboard overview shows hours out + extended');
select pg_temp.ok(private.generate_equipment_alerts() = 0, 'running the check again creates no duplicates');

select private.record_event('00000000-0000-0000-0000-00000000d3e0', (select id from equipment where name = 'Van Keys 04'),
       (select id from employees where employee_number = 'E1001'), 'checkin', now(), 'dashboard') as r \gset
select pg_temp.ok(:'r'::jsonb->'flags' ? 'returned_after_extended', 'the return is marked "returned after extended"');
select pg_temp.ok(not pg_temp.has_alert('Van Keys 04', 'extended_checkout'), 'returning it closes the alert');

update organizations set extended_checkout_hours = null where slug = 'demo';
select pg_temp.co('Van Keys 07', 'E1001', now() - interval '20 hours') \g /dev/null
select private.generate_equipment_alerts() \g /dev/null
select pg_temp.ok(not pg_temp.has_alert('Van Keys 07', 'extended_checkout'), 'company turns extended alerts off -> none raised');
update organizations set extended_checkout_hours = 9 where slug = 'demo';

set role authenticated;
select set_config('request.jwt.claim.sub', 'cccccccc-0000-0000-0000-000000000003', false) \g /dev/null
select pg_temp.ok((select count(*) from equipment_alerts where resolved_at is null) > 0, 'viewer can see open alerts');
do $$ begin
  perform acknowledge_alert((select id from equipment_alerts limit 1));
  raise exception 'FAIL: viewer acknowledged';
exception when insufficient_privilege then null; end $$;
select pg_temp.ok(true, 'viewer cannot sign off an alert');
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false) \g /dev/null
select acknowledge_alert((select a.id from equipment_alerts a join equipment e on e.id = a.equipment_id
                          where e.name = 'Van Keys 06'), 'Jordan has it on the ramp') \g /dev/null
select pg_temp.ok((select acknowledged_at is not null from equipment_alerts a join equipment e on e.id = a.equipment_id
                   where e.name = 'Van Keys 06'), 'supervisor/owner can sign off an alert with a note');
reset role;
set role authenticated;
select set_config('request.jwt.claim.sub', 'bbbbbbbb-0000-0000-0000-000000000002', false) \g /dev/null
select pg_temp.ok((select count(*) from equipment_alerts) = 0, 'company B cannot see company A''s alerts');
reset role;

\echo '--- Activity log: who checked out what, and returns made for someone else'
set role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false) \g /dev/null
select pg_temp.ok(exists (select 1 from activity_log where equipment = 'Radio 01' and by_employee = 'Jordan Lee' and description = 'Checked out'),
                  'log: Jordan Lee checked out Radio 01');
select pg_temp.ok(exists (select 1 from activity_log where equipment = 'Radio 01' and by_employee = 'Sam Patel'
                          and previous_holder = 'Jordan Lee' and description = 'Returned for Jordan Lee'),
                  'log: Sam Patel returned Radio 01 for Jordan Lee');
select pg_temp.ok(exists (select 1 from activity_log where equipment = 'Radio 01' and by_employee = 'Alex Rivera'
                          and description = 'Checked out (was still with Sam Patel)'),
                  'log: offline checkout while Sam still had it is spelled out');
select pg_temp.ok(exists (select 1 from activity_log where equipment = 'Radio 09' and by_employee = 'Sam Patel' and description = 'Returned as found'),
                  'log: Radio 09 returned as found by Sam');
select pg_temp.ok(exists (select 1 from activity_log where equipment = 'Vacuum 01' and description = 'Returned' and place = 'Equipment Room 01'),
                  'log: own returns say Returned, with the station name');
select pg_temp.ok(exists (select 1 from activity_log where place = 'Dashboard' and recorded_by is not null),
                  'log: supervisor corrections show Dashboard + who made them');
select set_config('request.jwt.claim.sub', 'bbbbbbbb-0000-0000-0000-000000000002', false) \g /dev/null
select pg_temp.ok((select count(*) from activity_log) = 0, 'company B cannot see company A''s activity');
reset role;

\echo '--- Manager and admin fobs at the station'
set role anon;
-- DANA = manager 04BA0000000A PIN 2468, MORGAN = admin 04BA0000000B PIN 1357
select pg_temp.ok(station_staff_login(:'key', '04BA00000001')->>'error' = 'not_staff', 'regular badge can''t open the staff menu');
select pg_temp.ok(station_staff_login(:'key', '04BA0000000A')->>'error' = 'pin_required', 'manager fob asks for the PIN');
select pg_temp.ok(station_staff_login(:'key', '04BA0000000A', '0000')->>'error' = 'wrong_pin', 'wrong PIN refused');
select station_staff_login(:'key', '04BA0000000A', '2468') as r \gset
select pg_temp.ok((:'r'::jsonb->>'ok')::boolean and :'r'::jsonb->'staff'->>'role' = 'manager'
                  and jsonb_array_length(:'r'::jsonb->'categories') = 6, 'manager fob + PIN opens the menu (with categories to pick from)');
select pg_temp.ok(station_staff_login('bad-key', '04BA0000000A', '2468')->>'error' = 'station_not_authorized', 'needs a real station');
reset role;
insert into equipment (org_id, category_id, name) select org_id, id, 'Radio 99' from equipment_categories where name = 'Radio';
set role anon;
select (x->>'id') as r99 from jsonb_array_elements(station_staff_login(:'key', '04BA0000000A', '2468')->'untagged') x where x->>'name' = 'Radio 99' \gset
select pg_temp.ok(:'r99' is not null, 'admin menu lists equipment added on the dashboard without a tag');
select station_replace_uid(:'key', '04BA0000000A', '2468', 'equipment', :'r99', '04DE00009999') \g /dev/null
select pg_temp.ok(station_item_status(:'key', '04DE00009999')->'equipment'->>'name' = 'Radio 99', 'tagging it at the station makes it tappable');

select station_add_employee(:'key', '04BA0000000A', '2468', 'Chris', 'Diaz', 'E1004', '04:BA:00:00:00:C1') as r \gset
select pg_temp.ok((:'r'::jsonb->>'ok')::boolean, 'manager adds Chris Diaz with a new badge');
select pg_temp.ok(station_tap(:'key', gen_random_uuid(), '04BA000000C1', '04DE000509')->>'action' = 'checkout',
                  'Chris''s new badge works right away');
select pg_temp.ok(station_add_employee(:'key', '04BA0000000A', '2468', 'Pat', 'Kim', null, '04BA000000C1')->>'used_by' = 'Chris Diaz',
                  'badge already in use -> says whose it is');
select pg_temp.ok(station_add_employee(:'key', '04BA0000000A', '2468', 'Pat', 'Kim', 'E1004', '04BA000000C2')->>'error' = 'number_in_use',
                  'employee number already in use');
select pg_temp.ok(station_add_employee(:'key', '04BA0000000A', '2468', 'Pat', 'Kim', null, '04DE000101')->>'error' = 'tag_is_equipment',
                  'can''t use an equipment tag as a badge');
select pg_temp.ok(station_add_employee(:'key', '04BA0000000A', '2468', 'Pat', 'Kim', null, '04BA000000C2', 'manager', '1111')->>'error' = 'admin_only',
                  'managers can''t create managers');

select (station_staff_login(:'key', '04BA0000000A', '2468')->'categories'->4->>'id') as radio_cat \gset
select station_add_equipment(:'key', '04BA0000000A', '2468', 'Radio 10', :'radio_cat', '04:DE:00:05:10', 'RAD-010') as r \gset
select pg_temp.ok((:'r'::jsonb->>'ok')::boolean, 'manager adds Radio 10 and registers its tag');
select pg_temp.ok(station_tap(:'key', gen_random_uuid(), '04BA00000002', '04DE000510')->>'action' = 'checkout', 'Radio 10 can be checked out right away');
select pg_temp.ok(station_add_equipment(:'key', '04BA0000000A', '2468', 'Radio 11', :'radio_cat', '04DE000510')->>'used_by' = 'Radio 10',
                  'tag already on another item -> says which');
select pg_temp.ok(station_add_equipment(:'key', '04BA0000000A', '2468', 'Radio 11', :'radio_cat', '04BA00000001')->>'error' = 'tag_is_badge',
                  'can''t use someone''s badge as an equipment tag');

select pg_temp.ok(station_set_item_status(:'key', '04BA0000000A', '2468', '04DE000510', 'lost')->'equipment'->>'status' = 'lost',
                  'manager marks Radio 10 lost from the station');
select pg_temp.ok(station_set_item_status(:'key', '04BA0000000A', '2468', '04DE000510', 'retired')->>'error' = 'admin_only',
                  'only admins can retire equipment');

select station_replace_uid(:'key', '04BA0000000A', '2468', 'employee',
       (select (x->>'id')::uuid from jsonb_array_elements(station_staff_login(:'key', '04BA0000000A', '2468')->'employees') x where x->>'name' = 'Chris Diaz'),
       '04BA000000C9') \g /dev/null
select pg_temp.ok(station_tap(:'key', gen_random_uuid(), '04BA000000C1', '04DE000101')->>'error' = 'unknown_badge'
                  and station_tap(:'key', gen_random_uuid(), '04BA000000C9', '04DE000101')->>'ok' = 'true',
                  'manager replaces Chris''s lost badge: old one stops working, new one works');
select pg_temp.ok(station_replace_uid(:'key', '04BA0000000A', '2468', 'employee',
       (select (x->>'id')::uuid from jsonb_array_elements(station_staff_login(:'key', '04BA0000000A', '2468')->'employees') x where x->>'name' = 'Morgan Reyes'),
       '04BA000000D1')->>'error' = 'admin_only', 'managers can''t re-badge an admin');

select (x->>'id') as chris from jsonb_array_elements(station_staff_login(:'key', '04BA0000000B', '1357')->'employees') x where x->>'name' = 'Chris Diaz' \gset
select pg_temp.ok(station_update_employee(:'key', '04BA0000000B', '1357', :'chris', 'manager')->>'error' = 'pin_needed',
                  'promoting to manager needs a PIN');
select pg_temp.ok((station_update_employee(:'key', '04BA0000000B', '1357', :'chris', 'manager', null, '8642')->>'ok')::boolean
                  and station_staff_login(:'key', '04BA000000C9', '8642')->'staff'->>'role' = 'manager',
                  'admin makes Chris a manager with a PIN; his fob opens the menu');
select pg_temp.ok(station_update_employee(:'key', '04BA0000000A', '2468', :'chris', 'employee')->>'error' = 'admin_only',
                  'managers can''t change roles');
select (x->>'id') as morgan from jsonb_array_elements(station_staff_login(:'key', '04BA0000000B', '1357')->'employees') x where x->>'name' = 'Morgan Reyes' \gset
select pg_temp.ok(station_update_employee(:'key', '04BA0000000B', '1357', :'morgan', 'employee')->>'error' = 'cant_change_self',
                  'admin can''t demote themselves by accident');
select station_update_employee(:'key', '04BA0000000B', '1357', :'chris', null, false) \g /dev/null
select pg_temp.ok(station_tap(:'key', gen_random_uuid(), '04BA000000C9', '04DE000101')->>'error' = 'unknown_badge',
                  'admin deactivates Chris -> his badge stops working');

select station_staff_login(:'key', '04BA0000000A', '1') \g /dev/null
select station_staff_login(:'key', '04BA0000000A', '2') \g /dev/null
select station_staff_login(:'key', '04BA0000000A', '3') \g /dev/null
select station_staff_login(:'key', '04BA0000000A', '4') \g /dev/null
select pg_temp.ok(station_staff_login(:'key', '04BA0000000A', '5')->>'error' = 'pin_locked'
                  and station_staff_login(:'key', '04BA0000000A', '2468')->>'error' = 'pin_locked',
                  '5 wrong PINs lock the fob for 15 minutes, even with the right PIN');
reset role;
update private.staff_pins set failures = 0, locked_until = null;
select pg_temp.ok((select count(*) from audit_log a join employees e on e.id = a.actor_employee_id
                   where e.first_name = 'Dana' and a.table_name in ('employees', 'equipment')) >= 3,
                  'audit log shows Dana''s fob made the additions and changes');
select pg_temp.ok(not exists (select 1 from information_schema.role_table_grants
                              where table_schema = 'private' and table_name = 'staff_pins' and grantee in ('anon', 'authenticated')),
                  'PINs are out of reach of the public API');

\echo '--- First-time setup: the admin tag shipped in the box'
reset role;
set role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false) \g /dev/null
select create_station('00000000-0000-0000-0000-00000000d3e0', 'Equipment Room 02')->>'activation_code' as code3 \gset
reset role;
set role anon;
select activate_station(:'code3') as act3 \gset
select :'act3'::jsonb->>'device_key' as key3 \gset
select pg_temp.ok((:'act3'::jsonb->>'has_admin_fob')::boolean
                  and :'act3'::jsonb->'organization'->>'name' = 'Demo Air Services',
                  'activation loads the company branding and says an admin fob already exists (setup may skip the tag)');
select pg_temp.ok(station_claim_admin_tag(:'key3', '04BA00000001')->>'used_by' = 'Alex Rivera', 'someone''s regular badge can''t become the admin tag');
select pg_temp.ok(station_claim_admin_tag(:'key3', '04DE000101')->>'error' = 'tag_is_equipment', 'an equipment tag can''t become the admin tag');
select pg_temp.ok(station_claim_admin_tag(:'key3', '04BA0000AD01')->>'needs' = 'name_and_pin', 'blank tag -> asks for a name and PIN');
select pg_temp.ok(station_claim_admin_tag(:'key3', '04BA0000AD01', 'Jamie', 'Ortiz', '12')->>'error' = 'pin_needed', 'PIN must be 4-8 digits');
select pg_temp.ok((station_claim_admin_tag(:'key3', '04BA0000AD01', 'Jamie', 'Ortiz', '5555')->>'ok')::boolean, 'shipped tag registered as Jamie Ortiz, admin');
select pg_temp.ok(station_staff_login(:'key3', '04BA0000AD01', '5555')->'staff'->>'role' = 'admin', 'the shipped tag opens the admin menu with its PIN');
select pg_temp.ok(station_claim_admin_tag(:'key3', '04BA0000AD02', 'Someone', 'Else', '1234')->>'error' = 'setup_window_closed',
                  'only one admin tag per setup');
reset role;
set role authenticated;
select reset_station_activation((select id from stations where name = 'Equipment Room 02'))->>'activation_code' as code4 \gset
reset role;
set role anon;
select activate_station(:'code4')->>'device_key' as key4 \gset
reset role;
update stations set activated_at = now() - interval '2 hours' where name = 'Equipment Room 02';
set role anon;
select pg_temp.ok(station_claim_admin_tag(:'key4', '04BA0000AD03', 'Late', 'Person', '1234')->>'error' = 'setup_window_closed',
                  'more than an hour after activation -> can''t register an admin tag this way');
reset role;
select pg_temp.ok((select actor_employee_id = (select id from employees where badge_uid = '04BA0000AD01') from audit_log
                   where table_name = 'employees' and new_data->>'badge_uid' = '04BA0000AD01' and operation = 'INSERT'),
                  'audit log credits the new admin for their own setup');

\echo '--- Team access: invite people to the dashboard'
insert into auth.users (id, email) values
  ('dddddddd-0000-0000-0000-000000000004', 'sup@example.com'),
  ('eeeeeeee-0000-0000-0000-000000000005', 'someone-else@example.com');
set role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false) \g /dev/null
select invite_member('00000000-0000-0000-0000-00000000d3e0', '  Sup@Example.com ', 'supervisor') as inv \gset
select pg_temp.ok((:'inv'::jsonb->>'ok')::boolean, 'owner invites sup@example.com as supervisor (email cleaned up)');
select pg_temp.ok(invite_member('00000000-0000-0000-0000-00000000d3e0', 'viewer@example.com', 'viewer')->>'error' = 'already_member',
                  'inviting someone already on the team is caught');
select pg_temp.ok(invite_member('00000000-0000-0000-0000-00000000d3e0', 'not-an-email', 'viewer')->>'error' = 'bad_email', 'bad email caught');
select pg_temp.ok(jsonb_array_length(list_members('00000000-0000-0000-0000-00000000d3e0')->'invites') = 1
                  and jsonb_array_length(list_members('00000000-0000-0000-0000-00000000d3e0')->'members') = 2,
                  'team list: 2 members + 1 open invite, with emails');
select set_config('request.jwt.claim.sub', 'eeeeeeee-0000-0000-0000-000000000005', false) \g /dev/null
select pg_temp.ok(accept_invite(:'inv'::jsonb->>'token')->>'error' = 'wrong_account', 'the link only works for the invited email');
select set_config('request.jwt.claim.sub', 'dddddddd-0000-0000-0000-000000000004', false) \g /dev/null
select pg_temp.ok(accept_invite(:'inv'::jsonb->>'token')->>'role' = 'supervisor', 'invited person accepts and joins as supervisor');
select pg_temp.ok(accept_invite(:'inv'::jsonb->>'token')->>'error' = 'invalid_invite', 'an invite works once');
select pg_temp.ok((select count(*) from employees) > 0, 'new supervisor can see the company''s data');
do $$ begin
  perform list_members('00000000-0000-0000-0000-00000000d3e0');
  raise exception 'FAIL: supervisor listed members';
exception when insufficient_privilege then null; end $$;
select pg_temp.ok(true, 'only admins and owners see and manage the team list');

select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false) \g /dev/null
select set_member_role('00000000-0000-0000-0000-00000000d3e0', 'dddddddd-0000-0000-0000-000000000004', 'admin') \g /dev/null
select set_config('request.jwt.claim.sub', 'dddddddd-0000-0000-0000-000000000004', false) \g /dev/null
do $$ begin
  perform invite_member('00000000-0000-0000-0000-00000000d3e0', 'boss@example.com', 'owner');
  raise exception 'FAIL: admin invited an owner';
exception when insufficient_privilege then null; end $$;
select pg_temp.ok(true, 'admins can''t make owners');
do $$ begin
  perform remove_member('00000000-0000-0000-0000-00000000d3e0', 'aaaaaaaa-0000-0000-0000-000000000001');
  raise exception 'FAIL: admin removed the owner';
exception when insufficient_privilege then null; end $$;
select pg_temp.ok(true, 'admins can''t remove owners');
select pg_temp.ok((invite_member('00000000-0000-0000-0000-00000000d3e0', 'office@example.com', 'viewer')->>'ok')::boolean, 'admins can invite view-only staff');
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false) \g /dev/null
select pg_temp.ok(set_member_role('00000000-0000-0000-0000-00000000d3e0', 'aaaaaaaa-0000-0000-0000-000000000001', 'admin')->>'error' = 'last_owner',
                  'the last owner can''t be demoted (company always has an owner)');
select remove_member('00000000-0000-0000-0000-00000000d3e0', 'dddddddd-0000-0000-0000-000000000004') as rm \gset
select pg_temp.ok((:'rm'::jsonb->>'ok')::boolean and not exists (select 1 from org_members where user_id = 'dddddddd-0000-0000-0000-000000000004'),
                  'owner removes a member');
select set_config('request.jwt.claim.sub', 'dddddddd-0000-0000-0000-000000000004', false) \g /dev/null
select pg_temp.ok((select count(*) from employees) = 0, 'removed member can no longer see anything');
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false) \g /dev/null
insert into equipment_categories (org_id, name, time_limit_type) values ('00000000-0000-0000-0000-00000000d3e0', 'Headsets', 'none');
select pg_temp.ok((delete_category((select id from equipment_categories where name = 'Headsets'))->>'ok')::boolean, 'admin adds and deletes an empty category');
select pg_temp.ok(delete_category((select id from equipment_categories where name = 'Radio'))->>'error' = 'in_use', 'a category with equipment can''t be deleted');
reset role;

\echo '--- Station revoke + audit'
set role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false) \g /dev/null
select create_station('00000000-0000-0000-0000-00000000d3e0', 'Station 02') ->> 'activation_code' as code2 \gset
select pg_temp.ok(:'code2' ~ '^[A-Z2-9]{4}-[A-Z2-9]{4}$', 'new station gets a readable code like ' || :'code2');
select revoke_station('00000000-0000-0000-0000-0000000057a1') \g /dev/null
reset role;
set role anon;
select pg_temp.ok((station_tap(:'key', gen_random_uuid(), '04BA00000001', '04DE000101')->>'error') = 'station_not_authorized',
                  'revoked station is locked out immediately');
reset role;
select pg_temp.ok((select count(*) from audit_log where table_name = 'stations') >= 1, 'audit log records station changes');

\echo '--- Platform (vendor) console'
insert into auth.users (id, email) values ('99999999-0000-0000-0000-000000000009', 'dez@vendor.example'),
                                          ('88888888-0000-0000-0000-000000000008', 'newowner@desertground.example');
insert into private.platform_operators (user_id, name, role) values ('99999999-0000-0000-0000-000000000009', 'Dez', 'owner');
set role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false) \g /dev/null
select pg_temp.ok(not am_platform_operator(), 'a customer owner is not an operator');
do $$ begin perform platform_customers(); raise exception 'FAIL: customer could list all customers'; exception when insufficient_privilege then null; end $$;
select 'pass  customers can''t use the operator functions';
select set_config('request.jwt.claim.sub', '99999999-0000-0000-0000-000000000009', false) \g /dev/null
select pg_temp.ok(am_platform_operator(), 'operator recognized');
select pg_temp.ok((select count(*) from equipment) = 0, 'operator can''t read customers'' equipment directly');
select pg_temp.ok(jsonb_array_length(platform_customers()) = 2, 'operator sees every customer');
select pg_temp.ok((select (c->>'equipment')::int > 0 from jsonb_array_elements(platform_customers()) c where c->>'slug' = 'demo'), 'customer list includes usage counts');
select platform_create_customer('{"name":"Desert Ground Handling","slug":"desertground","owner_email":"NewOwner@DesertGround.example",
  "primary_color":"#7A2E0E","accent_color":"#F4B400","modules":["shifts"],"status":"trial","trial_days":30,"plan":"pilot",
  "station_limit":2,"terminology":{"equipment":"Gear"},"notes":"Met at the PHX ramp expo","stations":["Bag Room","Ramp Office"]}'::jsonb) as nc \gset
select pg_temp.ok((:'nc'::jsonb->>'ok')::boolean and jsonb_array_length(:'nc'::jsonb->'stations') = 2, 'create customer with 2 stations in one step');
select pg_temp.ok((:'nc'::jsonb->'stations'->0->>'activation_code') ~ '^[A-Z2-9]{4}-[A-Z2-9]{4}$', 'each station gets an activation code to ship');
select pg_temp.ok(:'nc'::jsonb->'owner_invite'->>'email' = 'newowner@desertground.example' and length(:'nc'::jsonb->'owner_invite'->>'token') = 48, 'owner invite made (email lower-cased)');
select :'nc'::jsonb->>'org_id' as dg \gset
select platform_customer(:'dg')->'organization' as dgo \gset
select pg_temp.ok(:'dgo'::jsonb->>'status' = 'trial' and (:'dgo'::jsonb->>'trial_ends_at')::timestamptz > now() + interval '29 days'
                  and :'dgo'::jsonb->'terminology'->>'equipment' = 'Gear' and :'dgo'::jsonb->'terminology'->>'checkin' = 'Return'
                  and :'dgo'::jsonb->'enabled_modules' ? 'shifts' and :'dgo'::jsonb->>'primary_color' = '#7A2E0E', 'trial, branding, terms and modules saved');
select pg_temp.ok(platform_create_customer('{"name":"Dup","slug":"desertground","owner_email":"a@b.co"}')->>'error' = 'slug_taken', 'duplicate web address refused');
select pg_temp.ok(platform_create_customer('{"name":"X","slug":"x-co","owner_email":"nope"}')->>'error' = 'bad_email', 'bad owner email refused');
select pg_temp.ok(platform_customer(:'dg')->'organization'->>'notes' = 'Met at the PHX ramp expo', 'your notes are kept privately');
reset role;
-- the owner accepts and sees their company, but not your notes
set role authenticated;
select set_config('request.jwt.claim.sub', '88888888-0000-0000-0000-000000000008', false) \g /dev/null
select pg_temp.ok((accept_invite(:'nc'::jsonb->'owner_invite'->>'token')->>'role') = 'owner', 'customer''s owner accepts the invite');
select pg_temp.ok((select count(*) from organizations) = 1 and (select name from organizations) = 'Desert Ground Handling', 'owner sees their company');
select pg_temp.ok((select count(*) from information_schema.columns where table_name = 'organizations' and column_name like '%notes%') = 0, 'notes aren''t a customer-visible column');
select pg_temp.ok(create_station(:'dg', 'Third')->>'error' = 'station_limit', 'customer can''t go past their station limit');
do $$ begin update organizations set status = 'active', station_limit = null; raise exception 'FAIL: customer changed own plan'; exception when insufficient_privilege then null; end $$;
select 'pass  customer can''t change their own status or limits';
reset role;
-- activate one of their stations, then pause the account
set role anon;
select activate_station(:'nc'::jsonb->'stations'->0->>'activation_code') ->> 'device_key' as dgkey \gset
select pg_temp.ok((station_config(:'dgkey')->>'ok')::boolean, 'their station activates');
reset role;
set role authenticated;
select set_config('request.jwt.claim.sub', '99999999-0000-0000-0000-000000000009', false) \g /dev/null
select pg_temp.ok((platform_update_customer(:'dg', '{"status":"paused"}')->>'ok')::boolean, 'operator pauses the customer');
reset role;
set role anon;
select pg_temp.ok(station_config(:'dgkey')->>'error' = 'account_paused', 'paused: station says the account is paused (doesn''t unpair)');
select pg_temp.ok(station_tap(:'dgkey', gen_random_uuid(), '04BA00000001', '04DE000101')->>'error' = 'account_paused', 'paused: taps aren''t recorded');
reset role;
set role authenticated;
select set_config('request.jwt.claim.sub', '99999999-0000-0000-0000-000000000009', false) \g /dev/null
select platform_update_customer(:'dg', '{"status":"active","station_limit":3,"name":"Desert Ground Handling LLC","notes":""}') \g /dev/null
reset role;
set role anon;
select pg_temp.ok((station_config(:'dgkey')->>'ok')::boolean, 'resumed: the same station works again');
reset role;
set role authenticated;
select set_config('request.jwt.claim.sub', '99999999-0000-0000-0000-000000000009', false) \g /dev/null
select pg_temp.ok(platform_customer(:'dg')->'organization'->>'notes' is null and platform_customer(:'dg')->'organization'->>'name' = 'Desert Ground Handling LLC', 'update: name changed, notes cleared');
select pg_temp.ok(jsonb_array_length(platform_fleet()) >= 3, 'fleet lists stations across customers');
select pg_temp.ok((select count(*) from jsonb_array_elements(platform_fleet()) f where f->>'customer' like 'Desert%' and f->>'activated_at' is null) = 1, 'fleet shows the station still waiting for setup');
select (select st->>'id' from jsonb_array_elements(platform_customer(:'dg')->'stations') st where st->>'activated_at' is not null) as dgst \gset
select platform_station_code(:'dgst') ->> 'activation_code' as newcode \gset
reset role;
set role anon;
select pg_temp.ok(station_config(:'dgkey')->>'error' = 'station_not_authorized', 'new code from the console disconnects the old Pi');
select pg_temp.ok((activate_station(:'newcode')->>'ok')::boolean, 'and the new code works');
reset role;
set role authenticated;
select set_config('request.jwt.claim.sub', '99999999-0000-0000-0000-000000000009', false) \g /dev/null
select pg_temp.ok(platform_invite_owner(:'dg', 'newowner@desertground.example')->>'error' = 'already_member', 'can''t re-invite someone already on the team');
select pg_temp.ok((platform_invite_owner(:'dg', 'second@desertground.example')->>'ok')::boolean, 'invite a second owner');
select pg_temp.ok(jsonb_array_length(platform_log()) >= 5 and platform_log()->0->>'by' = 'Dez', 'operator actions are logged with who did them');
reset role;

\echo '--- Live dashboard helpers'
set role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false) \g /dev/null
select pg_temp.ok(jsonb_array_length(my_companies()) = 1 and my_companies()->0->>'role' = 'owner', 'my_companies lists the company and role');
select pg_temp.ok(cardinality(dashboard_pin_holders('00000000-0000-0000-0000-00000000d3e0')) >= 1, 'dashboard can tell which fobs have a PIN');
select set_config('request.jwt.claim.sub', 'bbbbbbbb-0000-0000-0000-000000000002', false) \g /dev/null
do $$ begin perform dashboard_pin_holders('00000000-0000-0000-0000-00000000d3e0'); raise exception 'FAIL: other company saw PIN holders'; exception when insufficient_privilege then null; end $$;
select 'pass  another company can''t see who has PINs';
select set_config('request.jwt.claim.sub', '99999999-0000-0000-0000-000000000009', false) \g /dev/null
select pg_temp.ok((select bool_and(f ? 'created_at') from jsonb_array_elements(platform_fleet()) f), 'fleet says when each station was created');
reset role;

\echo '--- Operator team'
insert into auth.users (id, email, raw_user_meta_data) values ('77777777-0000-0000-0000-000000000007', 'casey@sonoranpoint.example', '{"full_name":"Casey"}');
set role authenticated;
select set_config('request.jwt.claim.sub', '99999999-0000-0000-0000-000000000009', false) \g /dev/null
select pg_temp.ok((select (l->'details') ?& array['status','station_limit','name','notes'] and not ((l->'details') ? 'slug')
   from jsonb_array_elements(platform_log()) l where l->>'action' = 'status: active' limit 1), 'customer edits log only the fields that changed');
select platform_update_customer(:'dg', '{"station_limit":3}') \g /dev/null
select pg_temp.ok((select count(*) from jsonb_array_elements(platform_log()) l where l->>'action' = 'updated customer' and l->'details' = '{}'::jsonb) = 0, 'saving with no changes logs nothing empty');
select pg_temp.ok(platform_me()->>'role' = 'owner' and platform_me()->>'name' = 'Dez', 'platform_me: name and role');
select pg_temp.ok((select bool_and(m ? 'name') from jsonb_array_elements(platform_customer('00000000-0000-0000-0000-00000000d3e0')->'members') m), 'customer page members carry their names');
select pg_temp.ok(platform_invite_operator('Casey@SonoranPoint.example', 'operator', 'Casey')->>'ok' = 'true', 'owner invites an operator');
select platform_invite_operator('casey@sonoranpoint.example', 'operator', 'Casey')->>'token' as optok \gset
select pg_temp.ok(jsonb_array_length(platform_team()->'invites') = 1, 're-inviting replaces the open invite');
select pg_temp.ok(platform_invite_operator('x@y.co', 'admin')->>'error' = 'bad_role', 'unknown role refused');
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false) \g /dev/null
select pg_temp.ok(platform_accept_invite(:'optok')->>'error' = 'wrong_account', 'someone else can''t use the invite');
select pg_temp.ok(not am_platform_operator(), 'still not an operator');
select set_config('request.jwt.claim.sub', '77777777-0000-0000-0000-000000000007', false) \g /dev/null
select pg_temp.ok(platform_accept_invite(:'optok')->>'ok' = 'true', 'invited person accepts');
select pg_temp.ok(am_platform_operator(), 'and is in');
select pg_temp.ok(platform_accept_invite(:'optok')->>'error' = 'invalid_invite', 'invite works once');
select pg_temp.ok(platform_me()->>'role' = 'operator' and platform_me()->>'name' = 'Casey', 'joins as operator with the name given');
do $$ begin perform platform_invite_operator('z@y.co', 'operator'); raise exception 'FAIL: operator invited people'; exception when insufficient_privilege then null; end $$;
select 'pass  operators can''t invite';
do $$ begin perform platform_remove_operator('99999999-0000-0000-0000-000000000009'); raise exception 'FAIL: operator removed owner'; exception when insufficient_privilege then null; end $$;
select 'pass  operators can''t remove anyone';
select pg_temp.ok(platform_set_my_name('  Casey   Nguyen ')->>'name' = 'Casey Nguyen', 'anyone can set their own name');
select pg_temp.ok(platform_set_my_name('')->>'error' = 'bad_name', 'blank name refused');
select pg_temp.ok(jsonb_array_length(platform_customers()) >= 2, 'operator can run customers');
select set_config('request.jwt.claim.sub', '99999999-0000-0000-0000-000000000009', false) \g /dev/null
select pg_temp.ok(jsonb_array_length(platform_team()->'operators') = 2 and jsonb_array_length(platform_team()->'invites') = 0, 'team lists both, no open invites');
select pg_temp.ok(exists (select 1 from jsonb_array_elements(platform_team()->'operators') o where o->>'name' = 'Casey Nguyen'), 'team shows the new name');
select pg_temp.ok(platform_set_operator_role('99999999-0000-0000-0000-000000000009', 'operator')->>'error' = 'last_owner', 'the last owner can''t step down');
select pg_temp.ok(platform_remove_operator('99999999-0000-0000-0000-000000000009')->>'error' = 'last_owner', 'the last owner can''t be removed');
select pg_temp.ok(platform_set_operator_role('77777777-0000-0000-0000-000000000007', 'owner')->>'ok' = 'true', 'promote to owner');
select pg_temp.ok(platform_set_operator_role('77777777-0000-0000-0000-000000000007', 'operator')->>'ok' = 'true', 'and back');
select pg_temp.ok(platform_remove_operator('77777777-0000-0000-0000-000000000007')->>'ok' = 'true', 'owner removes an operator');
select pg_temp.ok(jsonb_array_length(platform_team()->'operators') = 1, 'and they are gone');
select platform_invite_operator('pat@sonoranpoint.example', 'operator') ->> 'ok' \g /dev/null
select platform_cancel_operator_invite((platform_team()->'invites'->0->>'id')::uuid);
select pg_temp.ok(jsonb_array_length(platform_team()->'invites') = 0, 'owner cancels an invite');
select pg_temp.ok(platform_log()->0->>'by' = 'Dez', 'team changes are logged');
reset role;
select set_config('request.jwt.claim.sub', '77777777-0000-0000-0000-000000000007', false) \g /dev/null
set role authenticated;
select pg_temp.ok(not am_platform_operator(), 'removed operator is locked out');
reset role;

\echo '--- Hardware'
set role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false) \g /dev/null
do $$ begin perform platform_hardware(); raise exception 'FAIL: customer saw hardware'; exception when insufficient_privilege then null; end $$;
select 'pass  customers can''t see your hardware';
select set_config('request.jwt.claim.sub', '99999999-0000-0000-0000-000000000009', false) \g /dev/null
select platform_save_hardware('{"kind":"station","pi_serial":"10000000abcd1234","parts":"Pi 5 2GB, Touch Display 2, PN532"}') as h1 \gset
select pg_temp.ok((:'h1'::jsonb->>'serial') = 'SP-0001', 'new unit gets the next serial');
select pg_temp.ok((select u->>'status' = 'building' and u->>'built_by_name' = 'Dez' and (u->>'built_at')::date = current_date
   from jsonb_array_elements(platform_hardware()) u where u->>'serial' = 'SP-0001'), 'starts as building, built by you today');
select pg_temp.ok(platform_save_hardware('{"serial":"SP-0001"}')->>'error' = 'serial_taken', 'serials are unique');
select platform_save_hardware('{"serial":"SP-0002"}') \g /dev/null
select pg_temp.ok(platform_save_hardware('{}')->>'serial' = 'SP-0003', 'automatic number skips one typed by hand');
select pg_temp.ok(platform_save_hardware('{"status":"lost"}')->>'error' = 'bad_status', 'unknown status refused');
select platform_add_station(:'dg', 'Hangar 2')->>'activation_code' as hcode \gset
reset role;
select (select id from stations where name = 'Hangar 2') as hst \gset
select (select id from organizations where slug = 'demo') as demoorg \gset
set role authenticated;
select pg_temp.ok(platform_save_hardware(jsonb_build_object('id', :'h1'::jsonb->>'id', 'org_id', :'demoorg', 'station_id', :'hst'))->>'error' = 'station_mismatch',
  'a station from another customer is refused');
select pg_temp.ok((platform_save_hardware(jsonb_build_object('id', :'h1'::jsonb->>'id', 'status', 'shipped', 'station_id', :'hst', 'carrier', 'UPS', 'tracking', '1Z999AA10123456784'))->>'ok')::boolean,
  'ship it to a station');
select pg_temp.ok((select u->>'customer' like 'Desert Ground%' and u->'station'->>'name' = 'Hangar 2' and (u->>'shipped_at')::date = current_date
   from jsonb_array_elements(platform_hardware()) u where u->>'serial' = 'SP-0001'), 'picking the station sets the customer and ship date');
select pg_temp.ok((select e->>'action' = 'status: shipped' and e->'details'->>'tracking' = '1Z999AA10123456784' and e->>'by' = 'Dez'
   from jsonb_array_elements(platform_hardware_unit((:'h1'::jsonb->>'id')::uuid)->'events') e limit 1), 'history records the shipment');
select pg_temp.ok(exists (select 1 from jsonb_array_elements(platform_log()) l where l->>'action' = 'hardware shipped'), 'shipping shows in the activity log');
select platform_save_hardware(jsonb_build_object('id', :'h1'::jsonb->>'id', 'note', 'Customer asked for a wall mount')) \g /dev/null
select pg_temp.ok((platform_hardware_unit((:'h1'::jsonb->>'id')::uuid)->'events'->0->'details'->>'text') = 'Customer asked for a wall mount', 'add a note to its history');
reset role;
set role anon;
select pg_temp.ok((activate_station(:'hcode')->>'ok')::boolean, 'customer activates the station');
reset role;
set role authenticated;
select set_config('request.jwt.claim.sub', '99999999-0000-0000-0000-000000000009', false) \g /dev/null
select pg_temp.ok((select u->>'status' from jsonb_array_elements(platform_hardware()) u where u->>'serial' = 'SP-0001') = 'installed', 'activation marks the shipped unit installed');
select pg_temp.ok((platform_hardware_unit((:'h1'::jsonb->>'id')::uuid)->'events'->0->>'by') = 'Automatic', 'and says it happened automatically');
select platform_save_hardware(jsonb_build_object('id', :'h1'::jsonb->>'id', 'org_id', :'demoorg')) \g /dev/null
select pg_temp.ok((select u->'station' = 'null'::jsonb and u->>'customer' = 'Demo Air Services' from jsonb_array_elements(platform_hardware()) u where u->>'serial' = 'SP-0001'),
  'moving to another customer clears the station');
select pg_temp.ok(platform_delete_hardware((select (u->>'id')::uuid from jsonb_array_elements(platform_hardware()) u where u->>'serial' = 'SP-0003'))->>'ok' = 'true', 'owner deletes a mistake');
reset role;

\echo '--- Reporting a problem with equipment'
create function pg_temp.raises(q text) returns boolean language plpgsql as $f$
begin execute q; return false; exception when insufficient_privilege then return true; end $f$;
update equipment set current_employee_id = null, checked_out_at = null, due_at = null, status = 'available' where nfc_uid = '04DE000402';
update equipment_alerts set resolved_at = now() where equipment_id = (select id from equipment where nfc_uid = '04DE000402');
select pg_temp.ok((select string_agg(label || case when blocks_checkout then '*' else '' end, ',' order by sort_order) from problem_reasons
                   where org_id = '00000000-0000-0000-0000-00000000d3e0') = 'Damaged,Not charging,Missing part,Other', 'every company starts with four reasons; none stops checkout');
insert into problem_reasons (org_id, label, blocks_checkout, sort_order) values ('00000000-0000-0000-0000-00000000d3e0', 'Unsafe', true, 9);
select (select id from problem_reasons where label = 'Damaged' and org_id = '00000000-0000-0000-0000-00000000d3e0') as damaged,
       (select id from problem_reasons where label = 'Not charging' and org_id = '00000000-0000-0000-0000-00000000d3e0') as notcharging,
       (select id from problem_reasons where label = 'Unsafe' and org_id = '00000000-0000-0000-0000-00000000d3e0') as unsafe \gset
set role anon;
select pg_temp.ok(jsonb_array_length(station_config(:'key4')->'problem_reasons') = 5, 'the station gets the reasons');
select station_tap(:'key4', gen_random_uuid(), '04BA00000002', '04DE000402') as r \gset
select pg_temp.ok(:'r'::jsonb->>'action' = 'checkout', 'Jordan checks out PDA 02');
select station_report_problem(:'key4', '22222222-0000-0000-0000-000000000001', '04BA00000002', '04DE000402', :'damaged', null, 'Cracked screen') as r \gset
select pg_temp.ok((:'r'::jsonb->>'ok')::boolean and not (:'r'::jsonb->>'blocks_checkout')::boolean and (:'r'::jsonb->>'held_by_reporter')::boolean,
                  'Jordan reports it damaged at the station (and still has it)');
select pg_temp.ok((station_report_problem(:'key4', '22222222-0000-0000-0000-000000000001', '04BA00000002', '04DE000402', :'damaged')->>'duplicate')::boolean,
                  'sending the same report again (offline upload) is harmless');
select pg_temp.ok((station_report_problem(:'key4', gen_random_uuid(), '04BA00000001', '04DE000402', :'damaged', null, 'Also the strap')->>'already_reported')::boolean,
                  'a second person reporting the same thing adds to the first report');
select pg_temp.ok(station_report_problem(:'key4', gen_random_uuid(), '04BA0000FFFF', '04DE000402', :'damaged')->>'error' = 'unknown_badge', 'needs a real badge');
select pg_temp.ok(station_tap(:'key4', gen_random_uuid(), '04BA00000002', '04DE000402')->>'action' = 'checkin', 'a damaged item can be returned');
select station_tap(:'key4', gen_random_uuid(), '04BA00000001', '04DE000402') as r \gset
select pg_temp.ok(:'r'::jsonb->>'action' = 'checkout' and :'r'::jsonb->'flags' ? 'reported_problem' and :'r'::jsonb->'problem'->>'reason' = 'Damaged',
                  'a damaged item can still be checked out, flagged, and the station is told what''s wrong');
select pg_temp.ok(station_tap(:'key4', gen_random_uuid(), '04BA00000001', '04DE000402')->>'action' = 'checkin', 'Alex brings it back');
select station_report_problem(:'key4', gen_random_uuid(), '04BA00000002', '04DE000402', :'unsafe') \g /dev/null
select station_tap(:'key4', gen_random_uuid(), '04BA00000001', '04DE000402') as r \gset
select pg_temp.ok(:'r'::jsonb->>'error' = 'item_has_problem' and :'r'::jsonb->'problem'->>'reason' = 'Unsafe', 'a reason set to stop checkout does stop it, and the station is told why');
select pg_temp.ok((select x->'problem'->>'reason' from jsonb_array_elements(station_sync_cache(:'key4')->'equipment') x where x->>'nfc_uid' = '04DE000402') = 'Unsafe',
                  'the offline list carries the problem (a blocking one first), so the station handles it offline too');
select pg_temp.ok(station_item_status(:'key4', '04DE000402')->'problem'->>'reason' = 'Unsafe', 'tapping it without a badge shows the problem');
select station_tap(:'key4', gen_random_uuid(), '04BA00000001', '04DE000402', null, 'checkout', true) as r \gset
select pg_temp.ok(:'r'::jsonb->'flags' ? 'reported_problem', 'a tap saved offline is still recorded, flagged for the supervisor');
select station_tap(:'key4', gen_random_uuid(), '04BA00000001', '04DE000402') \g /dev/null
select pg_temp.ok(station_clear_problem(:'key4', '04BA00000001', null, '04DE000402')->>'error' = 'not_staff', 'a regular badge can''t clear it');
select pg_temp.ok((station_clear_problem(:'key4', '04BA0000000A', '2468', '04DE000402', 'Screen replaced')->>'cleared')::int = 2, 'a manager fob clears it at the station');
select pg_temp.ok(station_tap(:'key4', gen_random_uuid(), '04BA00000001', '04DE000402')->>'action' = 'checkout', 'cleared -> it can be checked out again');
select station_tap(:'key4', gen_random_uuid(), '04BA00000001', '04DE000402') \g /dev/null
select pg_temp.ok((station_report_problem(:'key4', gen_random_uuid(), '04BA00000001', '04DE000402', :'notcharging')->>'blocks_checkout')::boolean = false
                  and station_tap(:'key4', gen_random_uuid(), '04BA00000001', '04DE000402')->>'action' = 'checkout', '"Not charging" is reported but doesn''t block checkout');
select station_tap(:'key4', gen_random_uuid(), '04BA00000001', '04DE000402') \g /dev/null
reset role;

set role authenticated;
select set_config('request.jwt.claim.sub', 'cccccccc-0000-0000-0000-000000000003', false) \g /dev/null
select pg_temp.ok((select count(*) from equipment_problems) = 3, 'dashboard users see reported problems');
select pg_temp.ok(pg_temp.raises($$select report_problem((select id from equipment where nfc_uid = '04DE000402'), (select id from problem_reasons where label = 'Damaged' limit 1))$$),
                  'a viewer can''t report from the dashboard');
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false) \g /dev/null
select report_problem((select id from equipment where nfc_uid = '04DE000402'), :'damaged', 'Dropped off the belt loader') as r \gset
select pg_temp.ok((:'r'::jsonb->>'ok')::boolean, 'owner reports it damaged from the dashboard');
select pg_temp.ok((clear_problem((:'r'::jsonb->>'id')::uuid, 'Checked, it''s fine')->>'ok')::boolean, 'supervisor clears it');
select pg_temp.ok((select cleared_by_user = 'aaaaaaaa-0000-0000-0000-000000000001' and clear_notes = 'Checked, it''s fine' from equipment_problems where id = (:'r'::jsonb->>'id')::uuid),
                  'and clears it with a note');
select pg_temp.ok((save_problem_reason('00000000-0000-0000-0000-00000000d3e0', '{"label":"Battery swollen","blocks_checkout":true}')->>'ok')::boolean, 'admin adds a reason that blocks checkout');
select pg_temp.ok(save_problem_reason('00000000-0000-0000-0000-00000000d3e0', '{"label":"battery SWOLLEN"}')->>'error' = 'duplicate_label', 'no two reasons with the same name');
select pg_temp.ok((save_problem_reason('00000000-0000-0000-0000-00000000d3e0', jsonb_build_object('id', :'notcharging', 'label', 'Won''t charge'))->>'ok')::boolean, 'admin renames one');
select remove_problem_reason(:'notcharging') \g /dev/null
select pg_temp.ok((select archived_at is not null from problem_reasons where id = :'notcharging') and (select reason from equipment_problems where reason_id = :'notcharging') = 'Not charging',
                  'admin removes one; earlier reports keep the words they were made with');
reset role;
set role anon;
select pg_temp.ok((select string_agg(x->>'label', ',') from jsonb_array_elements(station_config(:'key4')->'problem_reasons') x) = 'Damaged,Missing part,Other,Unsafe,Battery swollen',
                  'the station list follows');
reset role;
set role authenticated;
select set_config('request.jwt.claim.sub', 'cccccccc-0000-0000-0000-000000000003', false) \g /dev/null
select pg_temp.ok(pg_temp.raises($$select save_problem_reason('00000000-0000-0000-0000-00000000d3e0', '{"label":"Nope"}')$$), 'a viewer can''t change the list');
reset role;

\echo '--- Email alerts'
select pg_temp.ok((select kinds from notification_prefs where user_id = 'aaaaaaaa-0000-0000-0000-000000000001') = array['problem']
                  and (select kinds from notification_prefs where user_id = 'cccccccc-0000-0000-0000-000000000003') = '{}', 'owners start with problem emails on; others start with none');
select pg_temp.ok((select count(*) from private.email_queue where to_email = 'owner-a@example.com' and kind = 'problem') = 4
                  and (select count(*) from private.email_queue where to_email = 'viewer@example.com') = 0, 'each new problem queued an email for the owner only');
select pg_temp.ok((select title from private.email_queue where kind = 'problem' order by id limit 1) = 'PDA 02: Damaged'
                  and (select detail from private.email_queue where kind = 'problem' order by id limit 1) like 'Reported by Jordan Lee at Equipment Room 02. Note: "Cracked screen"%',
                  'the email says what, who and where');
set role authenticated;
select set_config('request.jwt.claim.sub', 'cccccccc-0000-0000-0000-000000000003', false) \g /dev/null
select pg_temp.ok((set_email_alerts('00000000-0000-0000-0000-00000000d3e0', 'cccccccc-0000-0000-0000-000000000003', array['overdue', 'problem'])->>'ok')::boolean, 'anyone can choose their own emails');
select pg_temp.ok(pg_temp.raises($$select set_email_alerts('00000000-0000-0000-0000-00000000d3e0', 'aaaaaaaa-0000-0000-0000-000000000001', '{}')$$), 'but not someone else''s');
select pg_temp.ok((select count(*) from notification_prefs) = 1, 'and only sees their own settings');
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false) \g /dev/null
select pg_temp.ok((select count(*) from notification_prefs where org_id = '00000000-0000-0000-0000-00000000d3e0') = 2, 'an admin sees everyone''s');
select pg_temp.ok(set_email_alerts('00000000-0000-0000-0000-00000000d3e0', 'cccccccc-0000-0000-0000-000000000003', array['spam'])->>'error' = 'unknown_kind', 'only known alert types');
select pg_temp.ok((set_email_alerts('00000000-0000-0000-0000-00000000d3e0', 'aaaaaaaa-0000-0000-0000-000000000001', array['problem', 'shift_report'])->>'ok')::boolean, 'owner adds shift reports');
reset role;
insert into equipment_alerts (org_id, equipment_id, employee_id, kind, checked_out_at, threshold_at)
select org_id, id, (select id from employees where employee_number = 'E1001'), 'overdue', now() - interval '9 hours', now() - interval '1 hour'
from equipment where nfc_uid = '04DE000402';
select pg_temp.ok((select count(*) from private.email_queue where kind = 'overdue' and to_email = 'viewer@example.com' and title = 'PDA 02 is overdue' and detail like 'With Alex Rivera since%') = 1
                  and (select count(*) from private.email_queue where kind = 'overdue' and to_email = 'owner-a@example.com') = 0, 'overdue emails go only to people who asked for them');
select pg_temp.ok(private.send_emails() = 0, 'without a Resend key nothing is sent, and nothing breaks');
select pg_temp.ok((select count(*) from private.email_batches where to_email = 'owner-a@example.com') = 1
                  and (select subject from private.email_batches where to_email = 'owner-a@example.com') = '4 equipment alerts at Demo Air Services'
                  and (select subject from private.email_batches where to_email = 'viewer@example.com') = 'PDA 02 is overdue',
                  'waiting alerts are grouped into one email per person');
select pg_temp.ok((select html like '%Cracked screen%' and html like '%https://app.sonoranpoint.com/#equipment%' and body_text like '%Settings, Email alerts%'
                   from private.email_batches where to_email = 'owner-a@example.com'), 'the email has the details, a link and how to change settings');
select pg_temp.ok((select link from private.email_queue where kind = 'problem' order by id limit 1)
                   = '#equipment?open=equipment:' || (select id from equipment where nfc_uid = '04DE000402') || '&org=00000000-0000-0000-0000-00000000d3e0',
                  'the link opens that item, in the right company');
select pg_temp.ok((select html like '%/brand/logo.png%' and html like '%Open the item%' and html like '%Problem reported%' and html ~ '(Mon|Tue|Wed|Thu|Fri|Sat|Sun), [A-Z][a-z]{2} [0-9]{1,2} at [0-9]{1,2}:[0-9]{2} (AM|PM)'
                   from private.email_batches where to_email = 'viewer@example.com' and subject = 'PDA 02 is overdue') is not null,
                  'one alert: says what kind, when it happened, and has a button to the item');
select pg_temp.ok((select html like '%/brand/logo.png%' and html like '%Equipment overdue%' and html like '%Open the item%'
                   from private.email_batches where to_email = 'viewer@example.com' and subject = 'PDA 02 is overdue'),
                  'Sonoran Point''s logo on white');
select pg_temp.ok((select html like '%See all alerts%' and html like '%#alerts?org=%' and html like '%4 things need a look%' and html like '%on the dashboard%'
                   from private.email_batches where to_email = 'owner-a@example.com'), 'several alerts: one email, a button to all alerts, and where each came from');
update organizations set logo_url = 'https://example.test/l.png' where id = '00000000-0000-0000-0000-00000000d3e0';
select private.enqueue_email('00000000-0000-0000-0000-00000000d3e0', 'problem', 'Test item: Damaged', 'Reported.', '#equipment', now(), null) \g /dev/null
select private.build_email_batches() \g /dev/null
select pg_temp.ok((select html like '%/brand/logo.png%' and html not like '%example.test/l.png%' and html not like '%#1F4E79%' from private.email_batches order by id desc limit 1),
                  'even when the company has a logo: Sonoran Point''s logo on white, no company colors');
update organizations set logo_url = null where id = '00000000-0000-0000-0000-00000000d3e0';
select pg_temp.ok((select count(*) from private.email_queue where batch_id is null) = 0 and private.build_email_batches() = 0, 'nothing is sent twice');
delete from org_members where user_id = 'cccccccc-0000-0000-0000-000000000003';
select pg_temp.ok(not exists (select 1 from notification_prefs where user_id = 'cccccccc-0000-0000-0000-000000000003'), 'removing someone removes their email settings');
insert into org_members (org_id, user_id, role) values ('00000000-0000-0000-0000-00000000d3e0', 'cccccccc-0000-0000-0000-000000000003', 'viewer');

\echo '--- Contracts'
update equipment set current_employee_id = null, checked_out_at = null, due_at = null, status = 'available' where nfc_uid in ('04DE000201', '04DE000202', '04DE000601');
set role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false) \g /dev/null
select save_contract('00000000-0000-0000-0000-00000000d3e0', '{"name":"BW"}')->>'id' as bw \gset
select save_contract('00000000-0000-0000-0000-00000000d3e0', '{"name":"AW","share_children":true,"move_on_return":true}')->>'id' as aw \gset
select save_contract('00000000-0000-0000-0000-00000000d3e0', jsonb_build_object('name', 'Delta BW', 'parent_id', :'bw'))->>'id' as dbw \gset
select save_contract('00000000-0000-0000-0000-00000000d3e0', jsonb_build_object('name', 'United BW', 'parent_id', :'bw'))->>'id' as ubw \gset
select save_contract('00000000-0000-0000-0000-00000000d3e0', jsonb_build_object('name', 'Delta AW', 'parent_id', :'aw'))->>'id' as daw \gset
select save_contract('00000000-0000-0000-0000-00000000d3e0', jsonb_build_object('name', 'United AW', 'parent_id', :'aw'))->>'id' as uaw \gset
select pg_temp.ok((select count(*) from contracts) = 6, 'admin builds the contract tree');
select pg_temp.ok(save_contract('00000000-0000-0000-0000-00000000d3e0', jsonb_build_object('name', 'delta bw', 'parent_id', :'bw'))->>'error' = 'duplicate_name', 'no two contracts with the same name in one group');
select pg_temp.ok(save_contract('00000000-0000-0000-0000-00000000d3e0', jsonb_build_object('id', :'bw', 'name', 'BW', 'parent_id', :'dbw'))->>'error' = 'parent_inside_itself', 'a contract can''t go inside its own branch');
-- assign (dashboard edits: plain updates, allowed for admins)
update stations set contract_id = :'dbw' where name = 'Equipment Room 02';
update employees set contract_id = :'dbw' where employee_number = 'E1001';   -- Alex
update employees set contract_id = :'ubw' where employee_number = 'E1002';   -- Jordan
update employees set contract_id = :'daw' where employee_number = 'E1003';   -- Sam
update equipment set contract_id = :'ubw' where nfc_uid = '04DE000201';
update equipment set contract_id = :'dbw' where nfc_uid = '04DE000202';
update equipment set contract_id = :'daw' where nfc_uid = '04DE000601';
select pg_temp.ok((select contract_id from employees where employee_number = 'E1001') = :'dbw'::uuid, 'people, items and stations are assigned to contracts');
select create_station('00000000-0000-0000-0000-00000000d3e0', 'United AW room')->>'activation_code' as awcode \gset
update stations set contract_id = :'uaw' where name = 'United AW room';
reset role;
set role anon;
select activate_station(:'awcode')->>'device_key' as keyaw \gset
select pg_temp.ok(station_config(:'key4')->'station'->'contract'->>'name' = 'Delta BW', 'the station knows its contract');
select pg_temp.ok(station_tap(:'key4', gen_random_uuid(), '04BA00000001', '04DE000202')->>'action' = 'checkout', 'Delta BW: Alex checks out a Delta BW item at a Delta BW station');
select station_tap(:'key4', gen_random_uuid(), '04BA00000002', '04DE000202') as r \gset
select pg_temp.ok(:'r'::jsonb->>'error' = 'other_contract' and :'r'::jsonb->>'station_contract' = 'Delta BW' and :'r'::jsonb->>'employee_contract' = 'United BW',
                  'below wing never crosses: a United BW badge is refused at a Delta BW station');
select station_tap(:'key4', gen_random_uuid(), '04BA00000001', '04DE000201') as r \gset
select pg_temp.ok(:'r'::jsonb->>'error' = 'other_contract_item' and :'r'::jsonb->>'item_contract' = 'United BW', '...and a United BW item can''t be checked out there');
select pg_temp.ok(station_tap(:'key4', gen_random_uuid(), '04BA00000002', '04DE000201', null, 'checkout', true)->>'action' = 'checkout', 'a tap saved offline is still recorded');
select pg_temp.ok(station_tap(:'key4', gen_random_uuid(), '04BA0000000A', '04DE000201')->>'action' = 'checkin', 'someone with no contract (the admin office) works everywhere');
select pg_temp.ok((select x->>'reach' from (select station_sync_cache(:'key4') x) y)::jsonb @> jsonb_build_array(:'dbw', :'bw')
                  and not ((select x->'reach' from (select station_sync_cache(:'key4') x) y) @> jsonb_build_array(:'ubw')),
                  'the offline list says which contracts this station serves');
select station_tap(:'keyaw', gen_random_uuid(), '04BA00000003', '04DE000601') as r \gset
select pg_temp.ok(:'r'::jsonb->>'action' = 'checkout', 'above wing shares: Sam (Delta AW) checks out a Delta AW item at the United AW station');
select station_tap(:'keyaw', gen_random_uuid(), '04BA00000003', '04DE000601') as r \gset
select pg_temp.ok(:'r'::jsonb->>'action' = 'checkin' and :'r'::jsonb->'flags' ? 'returned_other_contract' and :'r'::jsonb->>'moved_to' = 'United AW',
                  'returned at the United AW station: flagged, and it moves there because AW says so');
reset role;
select pg_temp.ok((select contract_id from equipment where nfc_uid = '04DE000601') = :'uaw'::uuid, 'the item now belongs to United AW');
select id as radiocat from equipment_categories where name = 'Radio' and org_id = '00000000-0000-0000-0000-00000000d3e0' \gset
set role anon;
select pg_temp.ok((station_add_equipment(:'key4', '04BA0000000A', '2468', 'Radio 77', :'radiocat', '04DE00007777')->>'ok')::boolean, 'a manager adds an item at the Delta BW station ');
reset role;
select pg_temp.ok((select contract_id from equipment where nfc_uid = '04DE00007777') = :'dbw'::uuid, 'items added at a station join its contract');
set role authenticated;
select pg_temp.ok(delete_contract(:'dbw')->>'error' = 'in_use', 'a contract that''s in use can''t be deleted');
select save_contract('00000000-0000-0000-0000-00000000d3e0', jsonb_build_object('name', 'Spare', 'parent_id', :'aw'))->>'id' as spare \gset
select pg_temp.ok((delete_contract(:'spare')->>'ok')::boolean, 'an empty one can');
select set_config('request.jwt.claim.sub', 'cccccccc-0000-0000-0000-000000000003', false) \g /dev/null
select pg_temp.ok(pg_temp.raises($$select save_contract('00000000-0000-0000-0000-00000000d3e0', '{"name":"Nope"}')$$), 'a viewer can''t change contracts');
select pg_temp.ok((select count(*) from contracts) = 6, 'but can see them');
reset role;
\echo '--- Lending equipment between contracts'
select id as blower1 from equipment where nfc_uid = '04DE000201' \gset
update stations set contract_id = :'ubw' where name = 'United AW room';
set role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false) \g /dev/null
select pg_temp.ok(lend_equipment(:'blower1', :'ubw')->>'error' = 'already_shared', 'lending to its own contract makes no sense');
select pg_temp.ok(lend_equipment((select id from equipment where nfc_uid = '04DE000101'), :'dbw')->>'error' = 'no_contract', 'an item with no contract already works everywhere');
select lend_equipment(:'blower1', :'dbw', 'For the 7am push') as r \gset
select pg_temp.ok((:'r'::jsonb->>'ok')::boolean and :'r'::jsonb->>'to' = 'Delta BW' and :'r'::jsonb->>'from' = 'United BW', 'United BW lends Blower 01 to Delta BW');
reset role;
set role anon;
select pg_temp.ok(station_item_status(:'key4', '04DE000201')->'contract'->>'name' = 'United BW' and station_item_status(:'key4', '04DE000201')->'loan'->>'to' = 'Delta BW',
                  'tapping it on its own says whose it is, and who has it on loan');
select pg_temp.ok((select x->>'loan_to' from jsonb_array_elements(station_sync_cache(:'key4')->'equipment') x where x->>'nfc_uid' = '04DE000201') = :'dbw'
                  and station_sync_cache(:'key4')->'contract_names'->>:'ubw' = 'United BW', 'the offline list knows about the loan and the contract names');
select station_tap(:'key4', gen_random_uuid(), '04BA00000001', '04DE000201') as r \gset
select pg_temp.ok(:'r'::jsonb->>'action' = 'checkout' and :'r'::jsonb->'flags' ? 'on_loan' and :'r'::jsonb->>'loan_from' = 'United BW', 'Delta BW checks it out, marked as on loan');
select pg_temp.ok(station_tap(:'key4', gen_random_uuid(), '04BA00000001', '04DE000201')->>'action' = 'checkin', 'returned at Delta: still on loan');
select station_tap(:'keyaw', gen_random_uuid(), '04BA00000002', '04DE000201') as r \gset
select pg_temp.ok(:'r'::jsonb->>'action' = 'loan_returned' and :'r'::jsonb->>'borrower' = 'Delta BW', 'tapped at a United BW station: back with United, loan over');
reset role;
select pg_temp.ok((select ended_how from equipment_loans where equipment_id = :'blower1' order by lent_at desc limit 1) = 'returned'
                  and (select current_employee_id is null from equipment where id = :'blower1'), 'the loan is closed and the item is in the room');
set role anon;
select pg_temp.ok(station_tap(:'key4', gen_random_uuid(), '04BA00000001', '04DE000201')->>'error' = 'other_contract_item', 'Delta can''t take it any more');
select pg_temp.ok(station_lend_equipment(:'key4', '04BA0000000A', '2468', '04DE000201', :'dbw')->>'error' = 'not_yours_to_lend', 'lending at a station: only at the owner''s station');
select pg_temp.ok((station_lend_equipment(:'keyaw', '04BA0000000A', '2468', '04DE000201', :'dbw')->>'ok')::boolean, 'a manager lends it at a United BW station');
select pg_temp.ok(station_tap(:'key4', gen_random_uuid(), '04BA00000001', '04DE000201')->>'action' = 'checkout', 'Delta takes it again');
select pg_temp.ok(station_tap(:'keyaw', gen_random_uuid(), '04BA00000002', '04DE000201')->>'action' = 'checkin', 'brought straight back to United while checked out: returned');
reset role;
select pg_temp.ok((select count(*) from equipment_loans where equipment_id = :'blower1' and ended_at is null) = 0, '...and the loan is over');
set role anon;
select station_lend_equipment(:'keyaw', '04BA0000000A', '2468', '04DE000201', :'dbw') \g /dev/null
select pg_temp.ok((station_end_loan(:'keyaw', '04BA0000000A', '2468', '04DE000201')->>'ended')::boolean, 'a manager can end a loan at the station');
reset role;
set role authenticated;
select lend_equipment(:'blower1', :'dbw') \g /dev/null
select pg_temp.ok((end_equipment_loan(:'blower1')->>'ended')::boolean, 'or a supervisor from the dashboard');
select pg_temp.ok((select count(*) from equipment_loans where equipment_id = :'blower1') = 4, 'every loan is kept in the item''s history');
select set_config('request.jwt.claim.sub', 'cccccccc-0000-0000-0000-000000000003', false) \g /dev/null
select pg_temp.ok(pg_temp.raises($$select lend_equipment((select id from equipment where nfc_uid = '04DE000201'), (select id from contracts where name = 'Delta BW'))$$), 'a viewer can''t lend');
reset role;

\echo '--- Managers see only their contracts'
update org_members set role = 'supervisor' where user_id = 'cccccccc-0000-0000-0000-000000000003';
select id as erm02 from stations where name = 'Equipment Room 02' \gset
select id as uawroom from stations where name = 'United AW room' \gset
set role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false) \g /dev/null
select pg_temp.ok(set_member_contracts('00000000-0000-0000-0000-00000000d3e0', 'aaaaaaaa-0000-0000-0000-000000000001', array[:'dbw'::uuid])->>'error' = 'owner_sees_all', 'owners always see everything');
select pg_temp.ok((set_member_contracts('00000000-0000-0000-0000-00000000d3e0', 'cccccccc-0000-0000-0000-000000000003', array[:'dbw'::uuid])->>'ok')::boolean, 'admin makes Kelly a Delta BW supervisor');
select set_config('request.jwt.claim.sub', 'cccccccc-0000-0000-0000-000000000003', false) \g /dev/null
select pg_temp.ok((select count(*) from equipment where contract_id = :'ubw') = 0 and (select count(*) from equipment where contract_id = :'dbw') > 0
                  and (select count(*) from equipment where contract_id is null) > 0, 'she sees Delta BW gear and company-wide gear, not United''s');
select pg_temp.ok(not exists (select 1 from employees where employee_number = 'E1002') and exists (select 1 from employees where employee_number = 'E1001'), 'Delta BW crew only (no Jordan from United BW)');
select pg_temp.ok(exists (select 1 from stations where id = :'erm02') and not exists (select 1 from stations where id = :'uawroom'), 'Delta BW stations only');
select pg_temp.ok((select string_agg(name, ',' order by name) from contracts) = 'BW,Delta BW', 'her contract and the group above it');
select pg_temp.ok((select count(*) from transactions where station_id = :'uawroom') = 0
                  and (select count(*) from transactions where station_id = :'erm02') > 0, 'history at United stations is hidden');
select pg_temp.ok((select count(*) from equipment_problems p where not exists (select 1 from equipment e where e.id = p.equipment_id)) = 0, 'problems on United gear are hidden');
select pg_temp.ok(pg_temp.raises($$select set_equipment_status((select id from equipment where nfc_uid = '04DE000201'), 'maintenance')$$), 'can''t change United gear, even by its id');
select pg_temp.ok(pg_temp.raises($$select report_problem((select id from equipment where nfc_uid = '04DE000201'), (select id from problem_reasons where label = 'Damaged' limit 1))$$),
                  'or report a problem on it');
update employees set last_name = 'X' where employee_number = 'E1002';
reset role;
select pg_temp.ok((select last_name from employees where employee_number = 'E1002') <> 'X', 'or edit United crew');
set role authenticated;
select pg_temp.ok(pg_temp.raises($$select set_member_contracts('00000000-0000-0000-0000-00000000d3e0', 'cccccccc-0000-0000-0000-000000000003', '{}')$$), 'and can''t change who sees what');
reset role;
update notification_prefs set kinds = array['problem'] where user_id = 'cccccccc-0000-0000-0000-000000000003';
set role anon;
select station_report_problem(:'keyaw', gen_random_uuid(), '04BA00000002', '04DE000201', :'damaged') \g /dev/null
select station_report_problem(:'key4', gen_random_uuid(), '04BA00000001', '04DE000202', :'damaged') \g /dev/null
reset role;
select pg_temp.ok((select count(*) from private.email_queue where to_email = 'viewer@example.com' and title like 'Blower 01%') = 0
                  and (select count(*) from private.email_queue where to_email = 'viewer@example.com' and title like 'Blower 02%') = 1, 'alert emails only for her contracts');
set role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false) \g /dev/null
select set_member_contracts('00000000-0000-0000-0000-00000000d3e0', 'cccccccc-0000-0000-0000-000000000003', '{}') \g /dev/null
select set_config('request.jwt.claim.sub', 'cccccccc-0000-0000-0000-000000000003', false) \g /dev/null
select pg_temp.ok((select count(*) from equipment where contract_id = :'ubw') > 0, 'with no contracts picked she sees everything again');
reset role;
update org_members set role = 'viewer' where user_id = 'cccccccc-0000-0000-0000-000000000003';

update stations set contract_id = null where name = 'Equipment Room 02';
update employees set contract_id = null;

\echo '--- Trial ending reminder'
reset role;
update organizations set status = 'trial', trial_ends_at = now() + interval '2 days', contact_email = 'Ops@DemoAir.example' where slug = 'demo';
update organizations set status = 'trial', trial_ends_at = now() + interval '5 days' where slug <> 'demo';
delete from private.email_batches;
select pg_temp.ok(private.send_trial_reminders() = 1, 'one customer''s trial ends within 3 days');
select pg_temp.ok((select array_agg(to_email order by to_email) from private.email_batches where subject like 'Your Sonoran Point trial ends %')
                  = (select array_agg(distinct lower(x) order by lower(x)) from (select u.email x from org_members m join auth.users u on u.id = m.user_id
                       where m.org_id = '00000000-0000-0000-0000-00000000d3e0' and m.role in ('owner', 'admin') union select 'ops@demoair.example') t),
                  'owners, admins and the contact email are reminded (once each)');
select pg_temp.ok(not exists (select 1 from private.email_batches where to_email = 'viewer@example.com'), 'viewers aren''t');
select pg_temp.ok((select bool_and(reply_to like '%dez@vendor.example%' and html like '%reply to this email%' and html like '%/brand/logo.png%'
                     and html like '%#overview?org=00000000-0000-0000-0000-00000000d3e0%')
                   from private.email_batches where subject like 'Your Sonoran Point trial ends %'), 'replies come to us; the email has our logo and a dashboard link');
select pg_temp.ok((select count(*) from private.email_batches where to_email = 'dez@vendor.example' and subject like 'Trial ending: Demo Air Services on %'
                     and html like '%ops@demoair.example%' and html like '%/#customer/00000000-0000-0000-0000-00000000d3e0%') = 1, 'we get a copy saying who was emailed');
select pg_temp.ok((select action from private.platform_log where org_id = '00000000-0000-0000-0000-00000000d3e0' order by id desc limit 1) = 'emailed a trial ending reminder',
                  'the customer''s console page notes it');
select pg_temp.ok(private.send_trial_reminders() = 0, 'only once per trial end date');
update organizations set trial_ends_at = now() + interval '3 days' - interval '1 minute' where slug = 'demo';
select pg_temp.ok(private.send_trial_reminders() = 1, 'a new end date gets its own reminder');
update organizations set trial_ends_at = now() - interval '1 hour' where slug = 'demo';
select pg_temp.ok(private.send_trial_reminders() = 0, 'nothing for a trial that''s already over');
select pg_temp.ok(private.send_emails() = 0, 'send_emails runs the reminders without a Resend key');
update organizations set status = 'active', trial_ends_at = null, contact_email = null where slug = 'demo';

\echo '--- Removing and replacing stations'
reset role;
insert into stations (org_id, name, activated_at, last_seen_at) values ('00000000-0000-0000-0000-00000000d3e0', 'Old Room', now(), now()) returning id as oldst \gset
insert into private.hardware_units (serial, kind, status, org_id, station_id) values ('SP-T1', 'station', 'installed', '00000000-0000-0000-0000-00000000d3e0', :'oldst');
insert into private.hardware_units (serial, kind, status) values ('SP-T2', 'station', 'ready'), ('SP-T3', 'station', 'building');
select id as t1 from private.hardware_units where serial = 'SP-T1' \gset
select id as t2 from private.hardware_units where serial = 'SP-T2' \gset
select id as t3 from private.hardware_units where serial = 'SP-T3' \gset
set role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false) \g /dev/null
select pg_temp.ok(pg_temp.raises($$select platform_replace_station('$$ || :'oldst' || $$')$$), 'customers can''t swap hardware');
select set_config('request.jwt.claim.sub', '99999999-0000-0000-0000-000000000009', false) \g /dev/null
select pg_temp.ok(platform_replace_station(:'oldst', :'t3')->>'error' = 'unit_not_in_stock', 'only a unit that''s ready (or returned) can go out');
select platform_replace_station(:'oldst', :'t2') as rep \gset
select pg_temp.ok((:'rep'::jsonb->>'ok')::boolean and length(:'rep'::jsonb->>'activation_code') = 9 and :'rep'::jsonb->>'unit' = 'SP-T2', 'replace: new code for the new box');
reset role;
select pg_temp.ok((select status = 'repair' and station_id is null from private.hardware_units where serial = 'SP-T1')
                  and (select status = 'ready' and station_id = :'oldst' from private.hardware_units where serial = 'SP-T2'), 'old box goes to repair, new one is assigned');
select pg_temp.ok((select name = 'Old Room' and replaced_at is not null and activated_at is null and revoked_at is null from stations where id = :'oldst'),
                  'same station, waiting for the new box');
select pg_temp.ok(exists (select 1 from private.hardware_events where unit_id = :'t1' and action = 'status: repair' and details->>'station' = 'Old Room'), 'the old box''s history says where it came from');
set role authenticated;
select pg_temp.ok(platform_replace_station(:'oldst', :'t1')->>'error' = 'unit_not_in_stock', 'a box in repair can''t be sent out');
select set_config('request.jwt.claim.sub', 'cccccccc-0000-0000-0000-000000000003', false) \g /dev/null
select pg_temp.ok(pg_temp.raises($$select remove_station('$$ || :'oldst' || $$')$$), 'viewers can''t remove a station');
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false) \g /dev/null
select pg_temp.ok((remove_station(:'oldst')->>'ok')::boolean, 'an admin removes it');
select pg_temp.ok(pg_temp.raises($$select reset_station_activation('$$ || :'oldst' || $$')$$), 'a removed station can''t get a new code');
reset role;
select pg_temp.ok((select removed_at is not null and revoked_at is not null from stations where id = :'oldst'), 'removed (and disconnected), but kept for history');
select pg_temp.ok((select status = 'returned' and station_id is null and org_id is null from private.hardware_units where serial = 'SP-T2'), 'its box shows as returned');
set role authenticated;
select set_config('request.jwt.claim.sub', '99999999-0000-0000-0000-000000000009', false) \g /dev/null
select pg_temp.ok(not exists (select 1 from jsonb_array_elements(platform_fleet()) f where f->>'id' = :'oldst')
                  and not exists (select 1 from jsonb_array_elements(platform_customer('00000000-0000-0000-0000-00000000d3e0')->'stations') f where f->>'id' = :'oldst'),
                  'gone from the console lists');
select pg_temp.ok(platform_station_code(:'oldst')->>'error' = 'removed' and platform_replace_station(:'oldst', :'t2')->>'error' = 'removed', 'and from the console it stays removed');
select pg_temp.ok((platform_customer('00000000-0000-0000-0000-00000000d3e0')->'log'->0->>'action') = 'removed station', 'the customer''s console log notes it');
reset role;

\echo '--- Station history and moving stations'
select pg_temp.ok((select string_agg(kind, ',' order by id) from station_events where station_id = :'oldst') = 'added,replaced,removed'
                  and (select details->>'unit' = 'SP-T2' and by_name = 'Sonoran Point' from station_events where station_id = :'oldst' and kind = 'replaced')
                  and (select by_name from station_events where station_id = :'oldst' and kind = 'removed') = 'owner-a@example.com',
                  'a station''s history: added, replaced (with the new box), removed, and who did it');
insert into stations (org_id, name, contract_id) values ('00000000-0000-0000-0000-00000000d3e0', 'Gate Room', :'ubw') returning id as gate \gset
insert into transactions (org_id, equipment_id, employee_id, station_id, action, source, occurred_at)
select org_id, (select id from equipment where org_id = s.org_id limit 1), (select id from employees where org_id = s.org_id limit 1), s.id, 'checkout', 'dashboard', now()
from stations s where s.id = :'gate' returning id as gatetap \gset
select pg_temp.ok((select station_contract_id from transactions where id = :'gatetap') = :'ubw', 'a tap remembers the station''s contract');
set role authenticated;
select set_config('request.jwt.claim.sub', '99999999-0000-0000-0000-000000000009', false) \g /dev/null
select pg_temp.ok(platform_update_station(:'gate', '{"name":"equipment room 02"}')->>'error' = 'duplicate_name', 'two working stations can''t share a name');
select pg_temp.ok(platform_update_station(:'gate', '{"contract_id":"00000000-0000-0000-0000-000000000000"}')->>'error' = 'unknown_contract', 'only their own contracts');
select pg_temp.ok((platform_update_station(:'gate', jsonb_build_object('name', '  Gate   Room B ', 'location', 'Terminal 4 North', 'contract_id', :'dbw'))->>'ok')::boolean, 'rename and move from the console');
reset role;
select pg_temp.ok((select name = 'Gate Room B' and contract_id = :'dbw' from stations where id = :'gate')
                  and (select l.name from stations s join locations l on l.id = s.location_id where s.id = :'gate') = 'Terminal 4 North', 'saved, with a new location made for it');
select pg_temp.ok((select string_agg(kind || ':' || coalesce(details->>'from', '-') || '>' || coalesce(details->>'to', '-'), ',' order by id) from station_events where station_id = :'gate' and kind like 'moved%' or (station_id = :'gate' and kind = 'renamed'))
                  = 'renamed:Gate Room>Gate Room B,moved_location:->Terminal 4 North,moved_contract:United BW>Delta BW', 'the moves are in its history: ' || (select string_agg(kind, ',') from station_events where station_id = :'gate'));
select pg_temp.ok((select station_contract_id from transactions where id = :'gatetap') = :'ubw', 'past taps stay with the contract it had');
set role authenticated;
select set_config('request.jwt.claim.sub', '99999999-0000-0000-0000-000000000009', false) \g /dev/null
select platform_station_code(:'gate') \g /dev/null
reset role;
select pg_temp.ok((select kind = 'new_code' and by_name = 'Sonoran Point' from station_events where station_id = :'gate' order by id desc limit 1), 'new codes are in the history');
set role authenticated;
select pg_temp.ok(platform_customer('00000000-0000-0000-0000-00000000d3e0')->'locations' ? 'Terminal 4 North'
                  and exists (select 1 from jsonb_array_elements(platform_customer('00000000-0000-0000-0000-00000000d3e0')->'station_events') e where e->>'station_id' = :'gate'),
                  'the console gets their locations and station history');
set role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false) \g /dev/null
select pg_temp.ok((select count(*) from station_events where station_id = :'gate') >= 5 and (select count(*) from station_overview where id = :'gate' and contract_id = :'dbw') = 1,
                  'the customer sees the history, and the station list now has its contract');
select pg_temp.ok(pg_temp.raises($$insert into station_events (org_id, station_id, kind) values ('00000000-0000-0000-0000-00000000d3e0', '$$ || :'gate' || $$', 'removed')$$), 'customers can''t write history');
update stations set name = 'Gate Room C' where id = :'gate';
reset role;
select pg_temp.ok((select by_name from station_events where station_id = :'gate' order by id desc limit 1) = 'owner-a@example.com', 'a dashboard rename is logged with who did it');
\echo '--- Light logo for dark backgrounds'
set role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false) \g /dev/null
update organizations set logo_dark_url = 'https://example.test/light.png' where id = '00000000-0000-0000-0000-00000000d3e0';
select set_config('request.jwt.claim.sub', '99999999-0000-0000-0000-000000000009', false) \g /dev/null
select pg_temp.ok((platform_customer('00000000-0000-0000-0000-00000000d3e0')->'organization'->>'logo_dark_url') = 'https://example.test/light.png', 'an owner sets their light logo; the console sees it');
select platform_update_customer('00000000-0000-0000-0000-00000000d3e0', '{"logo_dark_url": ""}') \g /dev/null
select pg_temp.ok((platform_customer('00000000-0000-0000-0000-00000000d3e0')->'organization'->>'logo_dark_url') is null, 'and you can clear it from the console');
reset role;

\echo '--- Barcodes'
insert into equipment (org_id, category_id, name, barcode) select org_id, category_id, 'Scanned Radio', ' ab-123 ' from equipment where org_id = '00000000-0000-0000-0000-00000000d3e0' limit 1;
select pg_temp.ok((select barcode = 'AB-123' and nfc_uid = private.barcode_uid('AB-123') and nfc_uid = 'B0C0DE41422D313233' from equipment where name = 'Scanned Radio'),
                  'an item with only a barcode gets a tag ID made from it');
insert into employees (org_id, employee_number, first_name, last_name, barcode) values ('00000000-0000-0000-0000-00000000d3e0', 'E9001', 'Bar', 'Code', '000123');
select pg_temp.ok((select badge_uid from employees where employee_number = 'E9001') = private.barcode_uid('000123'), 'so does a badge with only a barcode');
select private.barcode_uid('000123') as bcb, private.barcode_uid('ab-123') as bci \gset
set role anon;
select pg_temp.ok(station_tap(:'key4', gen_random_uuid(), :'bcb', :'bci')->>'action' = 'checkout', 'scanning both checks the item out (the station sends the ID made from the barcode)');
reset role;
update equipment set barcode = 'AB-124' where name = 'Scanned Radio';
select pg_temp.ok((select nfc_uid from equipment where name = 'Scanned Radio') = private.barcode_uid('AB-124'), 'changing the barcode moves the made-up tag ID with it');
update equipment set nfc_uid = '04DE0000BEEF' where name = 'Scanned Radio';
update equipment set barcode = 'AB-125' where name = 'Scanned Radio';
select pg_temp.ok((select nfc_uid = '04DE0000BEEF' and barcode = 'AB-125' from equipment where name = 'Scanned Radio'), 'an item with a real NFC tag keeps it when its barcode changes');
do $$ begin insert into equipment (org_id, category_id, name, barcode) select org_id, category_id, 'Dup', 'ab-125' from equipment where org_id = '00000000-0000-0000-0000-00000000d3e0' limit 1;
  raise exception 'FAIL: two items shared a barcode'; exception when unique_violation then null; end $$;
select 'pass  two items can''t share a barcode';
insert into equipment (org_id, category_id, name, nfc_uid) select org_id, category_id, 'Registered by scan', private.barcode_uid('ZZ-9') from equipment where org_id = '00000000-0000-0000-0000-00000000d3e0' limit 1;
select pg_temp.ok((select barcode from equipment where name = 'Registered by scan') = 'ZZ-9', 'an item registered at a station by scanning shows its barcode');
select pg_temp.ok((select e->>'barcode' from jsonb_array_elements(station_sync_cache(:'key4')->'equipment') e where e->>'name' = 'Scanned Radio') = 'AB-125'
                  and exists (select 1 from jsonb_array_elements(station_sync_cache(:'key4')->'employees') e where e->>'barcode' = '000123'), 'stations get the barcodes to match scans offline');
set role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false) \g /dev/null
update equipment set barcode = 'AB-200' where name = 'Scanned Radio';
reset role;
select pg_temp.ok((select barcode from equipment where name = 'Scanned Radio') = 'AB-200', 'admins set barcodes from the dashboard');

\echo '--- Closing out a customer'
select id as dg from organizations where slug = 'desertground' \gset
insert into private.hardware_units (serial, kind, status, org_id, station_id) select 'SP-CLOSE', 'station', 'installed', :'dg', id from stations where org_id = :'dg' limit 1;
insert into private.hardware_units (serial, kind, status, org_id) values ('SP-SPARE', 'reader', 'shipped', :'dg');
set role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false) \g /dev/null
select pg_temp.ok(pg_temp.raises($$select platform_close_customer('$$ || :'dg' || $$')$$), 'customers can''t close accounts');
select set_config('request.jwt.claim.sub', '99999999-0000-0000-0000-000000000009', false) \g /dev/null
select platform_close_customer(:'dg') as closed \gset
reset role;
select pg_temp.ok((:'closed'::jsonb->>'ok')::boolean and (select status from organizations where id = :'dg') = 'cancelled', 'closing out cancels the account');
select pg_temp.ok(not exists (select 1 from stations where org_id = :'dg' and revoked_at is null) and (:'closed'::jsonb->>'stations')::int > 0
                  and not exists (select 1 from private.station_keys k join stations s on s.id = k.station_id where s.org_id = :'dg' and (k.device_key_hash is not null or k.activation_code_hash is not null)),
                  'every station is disconnected (codes and keys stop working)');
select pg_temp.ok((select count(*) from private.hardware_units where org_id = :'dg' and status = 'returning') = 2
                  and exists (select 1 from private.hardware_events e join private.hardware_units u on u.id = e.unit_id where u.serial = 'SP-CLOSE' and e.details->>'reason' = 'customer closed out'),
                  'their units are marked as coming back');
select pg_temp.ok(not exists (select 1 from org_invites where org_id = :'dg' and accepted_at is null), 'open invites are cancelled');
select pg_temp.ok(exists (select 1 from station_events e join stations s on s.id = e.station_id where s.org_id = :'dg' and e.kind = 'disconnected' and e.by_name = 'Sonoran Point')
                  and (select action from private.platform_log where org_id = :'dg' order by id desc limit 1) = 'closed out customer', 'it shows in their station history and your log');
select pg_temp.ok(exists (select 1 from org_members where org_id = :'dg'), 'their team stays (they can still sign in to see their history)');

\echo '--- Station uptime history'
select id as ups from stations where name = 'Equipment Room 02' and org_id = '00000000-0000-0000-0000-00000000d3e0' \gset
update stations set last_seen_at = now() - interval '2 hours' where id = :'ups';
set role anon;
select station_heartbeat(:'key4') \g /dev/null
reset role;
select pg_temp.ok((select count(*) from station_outages where station_id = :'ups' and started_at < now() - interval '119 minutes' and ended_at > now() - interval '1 minute') = 1,
                  'a station back after 2 hours of silence records an outage for the gap');
set role anon;
select station_heartbeat(:'key4') \g /dev/null
reset role;
update stations set last_seen_at = last_seen_at - interval '2 minutes' where id = :'ups';
set role anon;
select station_heartbeat(:'key4') \g /dev/null
reset role;
select pg_temp.ok((select count(*) from station_outages where station_id = :'ups') = 1, 'short gaps (under 5 minutes) aren''t outages');
set role authenticated;
select set_config('request.jwt.claim.sub', '99999999-0000-0000-0000-000000000009', false) \g /dev/null
select pg_temp.ok(exists (select 1 from jsonb_array_elements(platform_outages()) o where o->>'station_id' = :'ups'), 'the console reads outages');
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false) \g /dev/null
select pg_temp.ok((select count(*) from station_outages where station_id = :'ups') = 1, 'the customer sees their station''s outages');
reset role;

\echo '--- Deleting a company removes all its data'
delete from organizations where slug = 'demo';
select pg_temp.ok((select count(*) from equipment) = 0 and (select count(*) from transactions) = 0, 'company delete cascades cleanly');
\echo 'ALL TESTS PASSED'
