-- =====================================================================
-- Demo data — a fictional company for development and sales demos.
-- (Keep real customer data, names and branding out of this file.)
--
-- To manage it from the dashboard, add yourself as owner after signing up:
--   insert into org_members (org_id, user_id, role)
--   values ('00000000-0000-0000-0000-00000000d3e0', '<your auth user id>', 'owner');
-- =====================================================================

insert into organizations (id, name, slug, primary_color, accent_color, timezone)
values ('00000000-0000-0000-0000-00000000d3e0', 'Demo Air Services', 'demo',
        '#1F4E79', '#F2A900', 'America/Phoenix');

-- Locations: airport → terminal → room
insert into locations (id, org_id, parent_id, name, kind) values
  ('00000000-0000-0000-0000-0000000010c1', '00000000-0000-0000-0000-00000000d3e0', null, 'Demo International Airport', 'airport'),
  ('00000000-0000-0000-0000-0000000010c2', '00000000-0000-0000-0000-00000000d3e0', '00000000-0000-0000-0000-0000000010c1', 'Terminal 3', 'terminal'),
  ('00000000-0000-0000-0000-0000000010c3', '00000000-0000-0000-0000-00000000d3e0', '00000000-0000-0000-0000-0000000010c2', 'Equipment Room 01', 'room');

-- Categories (time limits are placeholders — set per customer).
-- Shows all three options: hours, end of shift (Radios, 10h fallback), and none (Van Keys).
insert into equipment_categories (org_id, name, icon, time_limit_type, default_checkout_hours, sort_order) values
  ('00000000-0000-0000-0000-00000000d3e0', 'Vacuum',   'vacuum',  'hours',     8,    1),
  ('00000000-0000-0000-0000-00000000d3e0', 'Blower',   'blower',  'hours',     8,    2),
  ('00000000-0000-0000-0000-00000000d3e0', 'Battery',  'battery', 'hours',     12,   3),
  ('00000000-0000-0000-0000-00000000d3e0', 'PDA',      'pda',     'hours',     10,   4),
  ('00000000-0000-0000-0000-00000000d3e0', 'Radio',    'radio',   'shift_end', 10,   5),
  ('00000000-0000-0000-0000-00000000d3e0', 'Van Keys', 'key',     'none',      null, 6);

-- Two of each item. Fake NFC tag IDs: 04DE00<cat><n>
insert into equipment (org_id, category_id, home_location_id, name, asset_tag, nfc_uid)
select c.org_id, c.id, '00000000-0000-0000-0000-0000000010c3',
       c.name || ' ' || lpad(n::text, 2, '0'),
       upper(left(replace(c.name, ' ', ''), 3)) || '-' || lpad(n::text, 3, '0'),
       '04DE00' || lpad(c.sort_order::text, 2, '0') || lpad(n::text, 2, '0')
from equipment_categories c, generate_series(1, 2) n
where c.org_id = '00000000-0000-0000-0000-00000000d3e0';

-- Employees. Fake badge IDs: 04BA0000000<n>
insert into employees (org_id, employee_number, first_name, last_name, badge_uid, location_id) values
  ('00000000-0000-0000-0000-00000000d3e0', 'E1001', 'Alex',   'Rivera', '04:BA:00:00:00:01', '00000000-0000-0000-0000-0000000010c2'),
  ('00000000-0000-0000-0000-00000000d3e0', 'E1002', 'Jordan', 'Lee',    '04:BA:00:00:00:02', '00000000-0000-0000-0000-0000000010c2'),
  ('00000000-0000-0000-0000-00000000d3e0', 'E1003', 'Sam',    'Patel',  '04:BA:00:00:00:03', '00000000-0000-0000-0000-0000000010c2');

-- Staff fobs: a manager (PIN 2468) and an admin (PIN 1357) for the staff menu at the station.
insert into employees (org_id, employee_number, first_name, last_name, badge_uid, station_role) values
  ('00000000-0000-0000-0000-00000000d3e0', 'M2001', 'Dana',   'Brooks', '04:BA:00:00:00:0A', 'manager'),
  ('00000000-0000-0000-0000-00000000d3e0', 'A3001', 'Morgan', 'Reyes',  '04:BA:00:00:00:0B', 'admin');
do $$ begin
  perform private.set_pin(id, case employee_number when 'M2001' then '2468' else '1357' end)
  from employees where employee_number in ('M2001', 'A3001');
end $$;

-- A station waiting to be set up. Activation code: DEMO-0001 (valid 1 year for demos)
insert into stations (id, org_id, location_id, name) values
  ('00000000-0000-0000-0000-0000000057a1', '00000000-0000-0000-0000-00000000d3e0',
   '00000000-0000-0000-0000-0000000010c3', 'Equipment Room 01');
insert into private.station_keys (station_id, activation_code_hash, activation_expires_at) values
  ('00000000-0000-0000-0000-0000000057a1', private.sha256_hex(private.normalize_code('DEMO-0001')),
   now() + interval '1 year');

-- Shifts module (optional — switched on for the demo company)
update organizations set enabled_modules = array['shifts'] where id = '00000000-0000-0000-0000-00000000d3e0';
insert into shifts (org_id, name, start_time, end_time, location_id) values
  ('00000000-0000-0000-0000-00000000d3e0', 'AM',        '05:00', '13:30', '00000000-0000-0000-0000-0000000010c2'),
  ('00000000-0000-0000-0000-00000000d3e0', 'PM',        '13:00', '21:30', '00000000-0000-0000-0000-0000000010c2'),
  ('00000000-0000-0000-0000-00000000d3e0', 'Overnight', '21:00', '05:30', '00000000-0000-0000-0000-0000000010c2');
insert into shift_assignments (org_id, shift_id, employee_id)
select e.org_id, s.id, e.id from employees e
join shifts s on s.org_id = e.org_id
 and s.name = case e.employee_number when 'E1001' then 'AM' when 'E1002' then 'AM' else 'Overnight' end
where e.org_id = '00000000-0000-0000-0000-00000000d3e0';
