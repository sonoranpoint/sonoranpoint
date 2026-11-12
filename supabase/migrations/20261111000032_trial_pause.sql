-- Migration 32: stations pause on their own when a trial ends.
--
-- One day after trial_ends_at, a customer still on 'trial' is set to 'paused' (paused_reason = 'trial_ended').
-- Their stations stop recording right away (the same check as a manual pause). Their admins/managers and
-- contact email get an email, and so does every operator. Turn it off per customer with pause_at_trial_end
-- (console: Account). Checked every minute from private.send_emails(), through send_trial_reminders().
-- Setting the status to anything but paused clears paused_reason.

alter table public.organizations
  add column if not exists pause_at_trial_end boolean not null default true,
  add column if not exists paused_reason text;

-- Leaving 'paused' forgets why it was paused; a pause made by hand has no reason.
create or replace function private.org_pause_reason()
returns trigger language plpgsql as $$
begin
  if new.status <> 'paused' then new.paused_reason := null;
  elsif tg_op = 'UPDATE' and old.status <> 'paused' and new.paused_reason is not distinct from old.paused_reason then new.paused_reason := null;
  end if;
  return new;
end $$;
drop trigger if exists org_pause_reason on public.organizations;
create trigger org_pause_reason before insert or update of status, paused_reason on public.organizations
  for each row execute function private.org_pause_reason();

-- Who hears about a customer's trial: their admins and managers, plus the contact email.
create or replace function private.trial_recipients(p_org uuid)
returns text[] language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(distinct lower(x)), '{}') from (
    select u.email x from public.org_members m join auth.users u on u.id = m.user_id
     where m.org_id = p_org and m.role in ('owner', 'admin')
    union select o.contact_email from public.organizations o where o.id = p_org) t
  where coalesce(x, '') like '%@%'
$$;

create or replace function private.end_trials()
returns int language plpgsql security definer set search_path = public as $$
declare o record; v_to text[]; v_reply text; v_ops text[]; v_app text; v_console text; v_day text; e text; n int := 0;
begin
  select value into v_app from private.app_settings where key = 'app_url';
  select value into v_console from private.app_settings where key = 'console_url';
  select string_agg(u.email, ', ' order by po.created_at) into v_reply
  from private.platform_operators po join auth.users u on u.id = po.user_id
  where coalesce(u.email, '') like '%@%' and po.role = 'owner';
  select array_agg(u.email order by po.created_at) into v_ops
  from private.platform_operators po join auth.users u on u.id = po.user_id where coalesce(u.email, '') like '%@%';

  for o in
    update public.organizations g set status = 'paused', paused_reason = 'trial_ended'
    where g.status = 'trial' and g.pause_at_trial_end and g.trial_ends_at is not null
      and g.trial_ends_at + interval '1 day' <= now()
    returning g.*
  loop
    v_to  := private.trial_recipients(o.id);
    v_day := to_char(o.trial_ends_at at time zone o.timezone, 'FMDay, FMMonth FMDD');

    foreach e in array v_to loop
      insert into private.email_batches (org_id, to_email, reply_to, subject, html, body_text)
      values (o.id, e, v_reply, 'Your Sonoran Point trial has ended',
        private.email_html(o.name, 'Your trial has ended',
          format('<p style="margin:0 0 12px">The Sonoran Point trial for %s ended on <b>%s</b>, so your stations are paused and aren''t recording taps.</p>'
              || '<p style="margin:0 0 12px">Everything recorded so far is still in your dashboard.</p>'
              || '<p style="margin:0">To keep going, just reply to this email and we''ll turn your stations back on.</p>',
              private.html_esc(o.name), private.html_esc(v_day)),
          v_app || '/' || private.dash_link(o.id, 'overview'), 'Open the dashboard',
          'You get this email because you''re an admin or manager of ' || o.name || ' on Sonoran Point.'),
        o.name || E'\nYour trial has ended\n\nThe Sonoran Point trial for ' || o.name || ' ended on ' || v_day
          || E', so your stations are paused and aren''t recording taps.\nEverything recorded so far is still in your dashboard.\n'
          || E'To keep going, just reply to this email and we''ll turn your stations back on.\n\n'
          || v_app || '/' || private.dash_link(o.id, 'overview'));
    end loop;

    foreach e in array coalesce(v_ops, '{}') loop
      insert into private.email_batches (org_id, to_email, subject, html, body_text)
      values (o.id, e, 'Trial ended: ' || o.name || ' is paused',
        private.email_html(o.name, 'Trial ended, stations paused',
          format('<p style="margin:0 0 12px">%s''s trial ended on <b>%s</b>, so their account is paused and their stations stopped recording.</p><p style="margin:0">%s</p>',
              private.html_esc(o.name), private.html_esc(v_day),
              case when cardinality(v_to) = 0 then 'Nobody there has an email address, so they weren''t told. Reach out yourself.'
                   else 'We emailed ' || private.html_esc(array_to_string(v_to, ', ')) || '. Their replies come to you.' end),
          v_console || '/#customer/' || o.id, 'Open the customer',
          'Set them to active, or extend the trial, from the customer''s page to turn their stations back on.'),
        o.name || '''s trial ended on ' || v_day || E', so their account is paused.\n'
          || case when cardinality(v_to) = 0 then 'Nobody there has an email address, so they weren''t told.'
                  else 'We emailed ' || array_to_string(v_to, ', ') || '.' end
          || E'\n\n' || v_console || '/#customer/' || o.id);
    end loop;

    insert into private.platform_log (operator, org_id, action, details)
    values (null, o.id, 'trial ended: paused',
            jsonb_build_object('text', case when cardinality(v_to) = 0 then 'No one to email' else 'Emailed ' || array_to_string(v_to, ', ') end));
    n := n + 1;
  end loop;
  return n;
end $$;

-- Same as migration 27, plus: ends trials first, and the reminder says when stations will pause.
create or replace function private.send_trial_reminders()
returns int language plpgsql security definer set search_path = public as $$
declare o record; v_to text[]; v_reply text; v_ops text[]; v_app text; v_console text; v_day text; v_pause text; v_left int;
        v_when text; e text; n int := 0;
begin
  perform private.end_trials();
  select value into v_app from private.app_settings where key = 'app_url';
  select value into v_console from private.app_settings where key = 'console_url';
  select string_agg(u.email, ', ' order by po.created_at) into v_reply
  from private.platform_operators po join auth.users u on u.id = po.user_id
  where coalesce(u.email, '') like '%@%' and po.role = 'owner';
  -- Copies go to every operator; replies to the owners.
  select array_agg(u.email order by po.created_at) into v_ops
  from private.platform_operators po join auth.users u on u.id = po.user_id where coalesce(u.email, '') like '%@%';

  for o in
    select g.* from public.organizations g
    where g.status = 'trial' and g.trial_ends_at > now() and g.trial_ends_at <= now() + interval '3 days'
      and not exists (select 1 from private.trial_reminders r where r.org_id = g.id and r.trial_ends_at = g.trial_ends_at)
  loop
    v_to := private.trial_recipients(o.id);

    v_day   := to_char(o.trial_ends_at at time zone o.timezone, 'FMDay, FMMonth FMDD');
    v_pause := to_char((o.trial_ends_at + interval '1 day') at time zone o.timezone, 'FMDay, FMMonth FMDD');
    v_left  := (o.trial_ends_at at time zone o.timezone)::date - (now() at time zone o.timezone)::date;
    v_when  := case when v_left <= 0 then 'today' when v_left = 1 then 'tomorrow' else 'in ' || v_left || ' days' end;

    foreach e in array v_to loop
      insert into private.email_batches (org_id, to_email, reply_to, subject, html, body_text)
      values (o.id, e, v_reply, 'Your Sonoran Point trial ends ' || v_when,
        private.email_html(o.name, 'Your trial ends ' || v_when,
          format('<p style="margin:0 0 12px">The Sonoran Point trial for %s ends on <b>%s</b>.</p>%s'
              || '<p style="margin:0">To keep using it after that, just reply to this email and we''ll get you set up.</p>',
              private.html_esc(o.name), private.html_esc(v_day),
              case when o.pause_at_trial_end then format('<p style="margin:0 0 12px">If it isn''t extended, your stations pause on %s and stop recording taps. Everything recorded stays in your dashboard.</p>', private.html_esc(v_pause)) else '' end),
          v_app || '/' || private.dash_link(o.id, 'overview'), 'Open the dashboard',
          'You get this email because you''re an admin or manager of ' || o.name || ' on Sonoran Point.'),
        o.name || E'\nYour trial ends ' || v_when || E'\n\nThe Sonoran Point trial for ' || o.name || ' ends on ' || v_day || E'.\n'
          || case when o.pause_at_trial_end then 'If it isn''t extended, your stations pause on ' || v_pause || E' and stop recording taps. Everything recorded stays in your dashboard.\n' else '' end
          || E'To keep using it after that, just reply to this email and we''ll get you set up.\n\n'
          || v_app || '/' || private.dash_link(o.id, 'overview'));
    end loop;

    foreach e in array coalesce(v_ops, '{}') loop
      insert into private.email_batches (org_id, to_email, subject, html, body_text)
      values (o.id, e, 'Trial ending: ' || o.name || ' on ' || v_day,
        private.email_html(o.name, 'Trial ends ' || v_when,
          format('<p style="margin:0 0 12px">%s''s trial ends on <b>%s</b>.</p><p style="margin:0">%s</p>',
              private.html_esc(o.name), private.html_esc(v_day),
              case when cardinality(v_to) = 0 then 'Nobody there has an email address, so they weren''t reminded. Reach out yourself.'
                   else 'We emailed ' || private.html_esc(array_to_string(v_to, ', ')) || '. Their replies come to you.' end),
          v_console || '/#customer/' || o.id, 'Open the customer',
          case when o.pause_at_trial_end then 'Their stations pause on ' || v_pause || ' unless you extend the trial or set them to active.'
               else 'Extend the trial or set them to active from the customer''s page. Pausing at the end of the trial is off for them, so nothing changes on its own.' end),
        o.name || '''s trial ends on ' || v_day || E'.\n'
          || case when cardinality(v_to) = 0 then 'Nobody there has an email address, so they weren''t reminded.'
                  else 'We emailed ' || array_to_string(v_to, ', ') || '.' end
          || case when o.pause_at_trial_end then E'\nTheir stations pause on ' || v_pause || '.' else '' end
          || E'\n\n' || v_console || '/#customer/' || o.id);
    end loop;

    insert into private.trial_reminders (org_id, trial_ends_at, sent_to) values (o.id, o.trial_ends_at, v_to);
    insert into private.platform_log (operator, org_id, action, details)
    values (null, o.id, 'emailed a trial ending reminder',
            jsonb_build_object('text', case when cardinality(v_to) = 0 then 'No one to email' else 'To ' || array_to_string(v_to, ', ') end));
    n := n + 1;
  end loop;
  return n;
end $$;

-- Console list: adds the two new fields.
create or replace function public.platform_customers()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform private.require_operator();
  return coalesce((select jsonb_agg(row_to_json(c)::jsonb order by c.name) from (
    select o.id, o.name, o.slug, o.status, o.plan, o.trial_ends_at, o.station_limit, o.enabled_modules,
           o.primary_color, o.accent_color, o.logo_url, o.contact_name, o.contact_email, o.created_at,
           o.pause_at_trial_end, o.paused_reason,
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

-- Same as migration 22, plus pause_at_trial_end.
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
    pause_at_trial_end = case when p ? 'pause_at_trial_end' then coalesce((p->>'pause_at_trial_end')::boolean, true) else pause_at_trial_end end,
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
                         where k not in ('id', 'created_at', 'paused_reason') and (v_new -> k) is distinct from (to_jsonb(o) -> k)), '{}'::jsonb);
  if p ? 'notes' and nullif(trim(p->>'notes'), '') is distinct from v_old_notes then v_changed := v_changed || '{"notes": "changed"}'; end if;
  if v_changed <> '{}'::jsonb then
    perform private.plog(p_org,
      case when v_changed ? 'status' then 'status: ' || (v_changed->>'status') else 'updated customer' end, v_changed);
  end if;
  return jsonb_build_object('ok', true);
end $$;

revoke execute on function private.org_pause_reason(), private.trial_recipients(uuid), private.end_trials() from public, anon, authenticated;
