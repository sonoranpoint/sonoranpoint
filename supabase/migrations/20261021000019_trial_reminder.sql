-- =====================================================================
-- 19: Trial ending reminder
--   * Three days before a customer's trial ends, their owners, admins and contact email get one
--     email saying when it ends. Replies go to you (the console's owners).
--   * You get a copy, and the customer's page in the console notes it was sent.
--   * Nothing else happens when the trial ends: stations keep working until you change the
--     customer's status. Changing the end date sends a fresh reminder for the new date.
-- =====================================================================
alter table private.email_batches add column if not exists reply_to text;

insert into private.app_settings values ('console_url', 'https://console.sonoranpoint.com') on conflict do nothing;

create table private.trial_reminders (
  org_id         uuid not null references public.organizations(id) on delete cascade,
  trial_ends_at  timestamptz not null,
  sent_at        timestamptz not null default now(),
  sent_to        text[] not null default '{}',
  primary key (org_id, trial_ends_at)
);
alter table private.trial_reminders enable row level security;
revoke all on private.trial_reminders from public, anon, authenticated;

-- One plain email in the same look as the alert emails.
create function private.email_html(p_company text, p_heading text, p_body text, p_button_url text, p_button text, p_footer text)
returns text language plpgsql stable security definer set search_path = public as $$
declare v_url text;
begin
  select value into v_url from private.app_settings where key = 'app_url';
  return format('<div style="background:#f1f4f8;padding:24px 12px;font-family:Arial,Helvetica,sans-serif;color:#121a24">'
    || '<table role="presentation" cellpadding="0" cellspacing="0" style="width:100%%;max-width:560px;margin:0 auto;background:#ffffff;border-radius:12px;border:1px solid #e3e8ef;border-collapse:separate">'
    || '<tr><td style="background:#ffffff;padding:20px 24px 14px;border-radius:12px 12px 0 0;border-bottom:1px solid #e3e8ef">'
    || '<img src="%s/brand/logo.png" alt="Sonoran Point Technologies" width="170" style="width:170px;height:auto;display:block;border:0"></td></tr>'
    || '<tr><td style="padding:22px 24px 8px">'
    || '<p style="font-size:13px;color:#5b6878;margin:0 0 4px">%s</p><h1 style="font-size:21px;margin:0 0 10px">%s</h1>'
    || '<div style="color:#33404f;font-size:15px;line-height:1.5">%s</div>'
    || '<p style="margin:18px 0 22px"><a href="%s" style="background:#1d5fd1;color:#ffffff;padding:11px 18px;border-radius:8px;text-decoration:none;font-weight:700;display:inline-block">%s</a></p>'
    || '</td></tr></table>'
    || '<p style="font-size:12px;color:#8592a3;max-width:560px;margin:14px auto 0;text-align:center">%s</p></div>',
    v_url, private.html_esc(p_company), private.html_esc(p_heading), p_body, p_button_url, private.html_esc(p_button), private.html_esc(p_footer));
end $$;

create function private.send_trial_reminders()
returns int language plpgsql security definer set search_path = public as $$
declare o record; v_to text[]; v_reply text; v_ops text[]; v_app text; v_console text; v_day text; v_left int;
        v_when text; e text; n int := 0;
begin
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
    select array_agg(distinct lower(x)) into v_to from (
      select u.email x from public.org_members m join auth.users u on u.id = m.user_id
       where m.org_id = o.id and m.role in ('owner', 'admin')
      union select o.contact_email) t
    where coalesce(x, '') like '%@%';
    v_to := coalesce(v_to, '{}');

    v_day  := to_char(o.trial_ends_at at time zone o.timezone, 'FMDay, FMMonth FMDD');
    v_left := (o.trial_ends_at at time zone o.timezone)::date - (now() at time zone o.timezone)::date;
    v_when := case when v_left <= 0 then 'today' when v_left = 1 then 'tomorrow' else 'in ' || v_left || ' days' end;

    foreach e in array v_to loop
      insert into private.email_batches (org_id, to_email, reply_to, subject, html, body_text)
      values (o.id, e, v_reply, 'Your Sonoran Point trial ends ' || v_when,
        private.email_html(o.name, 'Your trial ends ' || v_when,
          format('<p style="margin:0 0 12px">The Sonoran Point trial for %s ends on <b>%s</b>.</p>'
              || '<p style="margin:0">To keep using it after that, just reply to this email and we''ll get you set up.</p>',
              private.html_esc(o.name), private.html_esc(v_day)),
          v_app || '/' || private.dash_link(o.id, 'overview'), 'Open the dashboard',
          'You get this email because you''re an owner or admin of ' || o.name || ' on Sonoran Point.'),
        o.name || E'\nYour trial ends ' || v_when || E'\n\nThe Sonoran Point trial for ' || o.name || ' ends on ' || v_day || E'.\n'
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
          'Extend the trial or set them to active from the customer''s page. Nothing changes on its own when it ends.'),
        o.name || '''s trial ends on ' || v_day || E'.\n'
          || case when cardinality(v_to) = 0 then 'Nobody there has an email address, so they weren''t reminded.'
                  else 'We emailed ' || array_to_string(v_to, ', ') || '.' end
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

-- Checked every minute with the other emails; replies go where reply_to says.
create or replace function private.send_emails()
returns int language plpgsql security definer set search_path = public as $$
declare v_key text; v_from text; b record; v_req bigint; n int := 0;
begin
  perform private.send_trial_reminders();
  perform private.build_email_batches();
  if not exists (select 1 from pg_extension where extname = 'pg_net')
     or not exists (select 1 from pg_namespace where nspname = 'vault') then
    return 0;
  end if;
  execute $q$select decrypted_secret from vault.decrypted_secrets where name = 'resend_api_key' limit 1$q$ into v_key;
  if v_key is null then return 0; end if;
  select value into v_from from private.app_settings where key = 'email_from';

  -- Results of earlier sends
  execute $q$
    update private.email_batches b set
      status = case when r.status_code between 200 and 299 then 'sent' else 'failed' end,
      error  = case when r.status_code between 200 and 299 then null else coalesce(r.error_msg, left(r.content::text, 500)) end
    from net._http_response r
    where r.id = b.request_id and b.status = 'posted' and (r.status_code is not null or r.error_msg is not null)$q$;

  -- Don't send a backlog of stale alerts (say, everything queued before email was set up).
  update private.email_batches set status = 'failed', error = 'not sent: more than a day old'
   where status = 'queued' and created_at < now() - interval '1 day';

  for b in select * from private.email_batches where status = 'queued' order by id limit 50 loop
    execute $q$select net.http_post(
        url := 'https://api.resend.com/emails',
        headers := jsonb_build_object('Authorization', 'Bearer ' || $1, 'Content-Type', 'application/json'),
        body := jsonb_strip_nulls(jsonb_build_object('from', $2, 'to', jsonb_build_array($3), 'subject', $4, 'html', $5, 'text', $6,
                  'reply_to', case when $7 is null then null else to_jsonb(string_to_array($7, ', ')) end)))$q$
      into v_req using v_key, v_from, b.to_email, b.subject, b.html, b.body_text, b.reply_to;
    update private.email_batches set request_id = v_req, posted_at = now(), status = 'posted' where id = b.id;
    n := n + 1;
  end loop;
  return n;
end $$;

revoke execute on all functions in schema private from public, anon, authenticated;
grant  execute on function private.has_org_role(uuid, public.member_role) to authenticated;
grant  execute on function private.normalize_uid(text) to anon, authenticated;
grant  execute on function private.resolve_time_limit(public.time_limit_mode, numeric, public.time_limit_type, numeric) to authenticated;
grant  execute on function private.can_manage_logo(text) to authenticated;
grant  execute on function private.can_see(uuid, uuid), private.can_see_equipment(uuid), private.can_see_txn(uuid, uuid, uuid, uuid), private.sees(uuid, uuid, uuid), private.scope_of(uuid, uuid) to authenticated;
