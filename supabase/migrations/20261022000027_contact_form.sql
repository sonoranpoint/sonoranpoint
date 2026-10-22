-- 27: Contact form on sonoranpoint.com, and the dashboard's role names in the trial email.
--   * public.submit_contact(...) can be called by anyone (the site has no sign-in). It saves the message in
--     private.contact_requests and emails every operator, with replies going to the sender.
--     A hidden "website" field catches bots (they get ok, nothing is saved); at most 3 messages an hour from
--     one address and 30 an hour in total.
--   * The trial-ending email now says "admin or manager" (the dashboard shows owner as Admin, admin as Manager).

create table if not exists private.contact_requests (
  id          bigint generated always as identity primary key,
  created_at  timestamptz not null default now(),
  name        text not null,
  email       text not null,
  company     text,
  phone       text,
  topic       text,
  message     text not null
);

create or replace function public.submit_contact(p_name text, p_email text, p_message text, p_company text default null,
  p_phone text default null, p_topic text default null, p_website text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_name text := btrim(coalesce(p_name, '')); v_email text := lower(btrim(coalesce(p_email, '')));
        v_msg text := btrim(coalesce(p_message, '')); v_company text := nullif(btrim(coalesce(p_company, '')), '');
        v_phone text := nullif(btrim(coalesce(p_phone, '')), ''); v_topic text := nullif(btrim(coalesce(p_topic, '')), '');
        v_ops text[]; v_console text; v_html text; v_text text; e text;
begin
  if coalesce(btrim(p_website), '') <> '' then return jsonb_build_object('ok', true); end if;   -- a bot filled the hidden field
  if v_name = '' or length(v_name) > 100 then return jsonb_build_object('ok', false, 'error', 'bad_name'); end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or length(v_email) > 200 then return jsonb_build_object('ok', false, 'error', 'bad_email'); end if;
  if v_msg = '' or length(v_msg) > 4000 then return jsonb_build_object('ok', false, 'error', 'bad_message'); end if;
  if length(coalesce(v_company, '')) > 150 or length(coalesce(v_phone, '')) > 40 or length(coalesce(v_topic, '')) > 60 then
    return jsonb_build_object('ok', false, 'error', 'too_long'); end if;
  if (select count(*) from private.contact_requests where email = v_email and created_at > now() - interval '1 hour') >= 3
     or (select count(*) from private.contact_requests where created_at > now() - interval '1 hour') >= 30 then
    return jsonb_build_object('ok', false, 'error', 'too_many'); end if;

  insert into private.contact_requests (name, email, company, phone, topic, message) values (v_name, v_email, v_company, v_phone, v_topic, v_msg);

  select value into v_console from private.app_settings where key = 'console_url';
  select array_agg(u.email order by po.created_at) into v_ops
  from private.platform_operators po join auth.users u on u.id = po.user_id where coalesce(u.email, '') like '%@%';
  v_html := format('<p style="margin:0 0 12px"><b>%s</b> &lt;%s&gt;%s%s</p><p style="margin:0 0 12px;white-space:pre-wrap">%s</p><p style="margin:0;color:#5b6878">Reply to this email to answer them.</p>',
    private.html_esc(v_name), private.html_esc(v_email),
    case when v_company is null then '' else '<br>' || private.html_esc(v_company) end,
    case when v_phone is null then '' else '<br>' || private.html_esc(v_phone) end,
    private.html_esc(v_msg));
  v_text := v_name || ' <' || v_email || '>' || coalesce(E'\n' || v_company, '') || coalesce(E'\n' || v_phone, '') || E'\n\n' || v_msg;
  foreach e in array coalesce(v_ops, '{}') loop
    insert into private.email_batches (org_id, to_email, reply_to, subject, html, body_text)
    values (null, e, v_email, 'Website: ' || coalesce(v_topic, 'Message') || ' from ' || v_name || coalesce(', ' || v_company, ''),
      private.email_html('sonoranpoint.com', coalesce(v_topic, 'New message'), v_html, v_console, 'Open the console',
        'Sent from the contact form on sonoranpoint.com.'),
      v_text);
  end loop;
  return jsonb_build_object('ok', true);
end $$;

create or replace function private.send_trial_reminders()
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
          'You get this email because you''re an admin or manager of ' || o.name || ' on Sonoran Point.'),
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

revoke execute on all functions in schema private from public, anon, authenticated;
grant  execute on function private.has_org_role(uuid, public.member_role) to authenticated;
grant  execute on function private.normalize_uid(text) to anon, authenticated;
grant  execute on function private.resolve_time_limit(public.time_limit_mode, numeric, public.time_limit_type, numeric) to authenticated;
grant  execute on function private.can_manage_logo(text) to authenticated;
grant  execute on function private.can_see(uuid, uuid), private.can_see_equipment(uuid), private.can_see_txn(uuid, uuid, uuid, uuid),
  private.can_see_tap(uuid, uuid, uuid, uuid), private.sees(uuid, uuid, uuid), private.scope_of(uuid, uuid) to authenticated;
revoke execute on function public.submit_contact(text, text, text, text, text, text, text) from public;
grant  execute on function public.submit_contact(text, text, text, text, text, text, text) to anon, authenticated;
