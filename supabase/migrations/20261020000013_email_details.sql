-- =====================================================================
-- 13: Clearer alert emails
--   * Header with the customer's logo on their main color (Sonoran Point's logo on white
--     when they have none), the company name, and a heading that says what kind of alert.
--   * Each alert says when it happened (company time zone) and where ("at Equipment Room 01"
--     or "on the dashboard").
--   * Links open the exact item or shift report in the dashboard, in the right company.
-- =====================================================================
alter table private.email_queue add column if not exists at timestamptz;

-- Dashboard link that opens one thing: '#equipment?open=equipment:<id>&org=<org>'
create or replace function private.dash_link(p_org uuid, p_route text, p_open text default null)
returns text language sql immutable as $$
  select '#' || p_route || '?' || case when p_open is not null then 'open=' || p_open || '&' else '' end || 'org=' || p_org
$$;

create or replace function private.enqueue_email(p_org uuid, p_kind text, p_title text, p_detail text, p_link text, p_at timestamptz)
returns void language sql security definer set search_path = public as $$
  insert into private.email_queue (org_id, user_id, to_email, kind, title, detail, link, at)
  select p_org, u.id, u.email, p_kind, p_title, p_detail, p_link, coalesce(p_at, now())
  from public.notification_prefs n
  join public.org_members m on m.org_id = n.org_id and m.user_id = n.user_id
  join auth.users u on u.id = n.user_id
  where n.org_id = p_org and p_kind = any (n.kinds) and coalesce(u.email, '') like '%@%';
$$;

create or replace function private.email_on_problem()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_item text; v_station text; v_by text;
begin
  select name into v_item from public.equipment where id = new.equipment_id;
  select name into v_station from public.stations where id = new.station_id;
  v_by := coalesce(private.emp_name(new.reported_by_employee),
                   (select coalesce(nullif(raw_user_meta_data->>'full_name', ''), email) from auth.users where id = new.reported_by_user));
  perform private.enqueue_email(new.org_id, 'problem', v_item || ': ' || new.reason,
    'Reported' || coalesce(' by ' || v_by, '') || case when new.station_id is not null then coalesce(' at ' || v_station, ' at a station') else ' on the dashboard' end || '.'
      || case when new.blocks_checkout then ' It can''t be checked out until a supervisor clears it.' else '' end
      || coalesce(' Note: "' || new.notes || '"', ''),
    private.dash_link(new.org_id, 'equipment', 'equipment:' || new.equipment_id), new.reported_at);
  return null;
end $$;

create or replace function private.email_on_alert()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_item text; v_who text; v_tz text;
begin
  select e.name, o.timezone into v_item, v_tz from public.equipment e join public.organizations o on o.id = e.org_id where e.id = new.equipment_id;
  v_who := private.emp_name(new.employee_id);
  perform private.enqueue_email(new.org_id, case new.kind when 'overdue' then 'overdue' else 'extended' end,
    v_item || case new.kind when 'overdue' then ' is overdue' else ' has been out too long' end,
    coalesce('With ' || v_who || ' since ', 'Out since ')
      || to_char(new.checked_out_at at time zone v_tz, 'Dy Mon FMDD, FMHH12:MI AM') || '.'
      || case new.kind when 'overdue' then ' It was due ' || to_char(new.threshold_at at time zone v_tz, 'FMHH12:MI AM') || '.' else '' end,
    private.dash_link(new.org_id, 'equipment', 'equipment:' || new.equipment_id), new.threshold_at);
  return null;
end $$;

create or replace function private.email_on_shift_report()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_shift text;
begin
  if new.outstanding_count = 0 then return null; end if;
  select name into v_shift from public.shifts where id = new.shift_id;
  perform private.enqueue_email(new.org_id, 'shift_report',
    v_shift || ' shift, ' || to_char(new.shift_date, 'Dy Mon FMDD') || ': ' || new.outstanding_count
      || case when new.outstanding_count = 1 then ' item' else ' items' end || ' not back on time',
    case when new.still_out_count > 0 then new.still_out_count || ' still out.' else 'All back now.' end
      || ' ' || coalesce((select string_agg(i->>'name', ', ') from jsonb_array_elements(new.items) i), ''),
    private.dash_link(new.org_id, 'shifts', 'report:' || new.id), new.cutoff);
  return null;
end $$;

drop function if exists private.enqueue_email(uuid, text, text, text, text);

-- One email per person per company: branded header, one block per alert, a button to the right place.
create or replace function private.build_email_batches()
returns int language plpgsql security definer set search_path = public as $$
declare g record; o record; v_id bigint; n int := 0; v_url text; rows_html text; rows_text text;
        v_subject text; v_heading text; v_button text; v_header text; v_kind text;
begin
  select value into v_url from private.app_settings where key = 'app_url';
  for g in
    select org_id, to_email, array_agg(id order by created_at) ids, count(*) cnt
    from private.email_queue where batch_id is null group by org_id, to_email
  loop
    select name, logo_url, primary_color, timezone into o from public.organizations where id = g.org_id;
    select string_agg(format(
             '<tr><td style="padding:14px 0;border-top:1px solid #e3e8ef">'
             || '<a href="%s/%s" style="color:#121a24;font-weight:700;font-size:16px;text-decoration:none">%s</a>'
             || '<div style="color:#5b6878;font-size:13px;margin-top:3px">%s</div>'
             || '<div style="color:#33404f;font-size:14px;margin-top:6px;line-height:1.45">%s</div></td></tr>',
             v_url, coalesce(q.link, ''), private.html_esc(q.title),
             private.html_esc(to_char(coalesce(q.at, q.created_at) at time zone o.timezone, 'Dy, Mon FMDD "at" FMHH12:MI AM')),
             private.html_esc(q.detail)), '' order by q.created_at),
           string_agg(q.title || E'\n' || to_char(coalesce(q.at, q.created_at) at time zone o.timezone, 'Dy, Mon FMDD "at" FMHH12:MI AM')
                      || E'\n' || coalesce(q.detail, '') || E'\n' || v_url || '/' || coalesce(q.link, ''), E'\n\n' order by q.created_at),
           min(q.title), min(q.kind), min(q.link)
      into rows_html, rows_text, v_subject, v_kind, v_button
    from private.email_queue q where q.id = any (g.ids);

    if g.cnt > 1 then
      v_subject := g.cnt || ' equipment alerts at ' || o.name;
      v_heading := g.cnt || ' things need a look';
      v_button  := private.dash_link(g.org_id, 'alerts');
    else
      v_heading := case v_kind when 'problem' then 'Problem reported' when 'overdue' then 'Equipment overdue'
                               when 'extended' then 'Out too long' when 'shift_report' then 'Shift report' else 'Something needs a look' end;
    end if;

    -- Their logo sits on their main color (like the station); ours is full color, on white.
    v_header := case when o.logo_url is not null then
        format('<td style="background:%s;padding:18px 24px;border-radius:12px 12px 0 0"><img src="%s" alt="%s" height="44" style="height:44px;width:auto;max-width:240px;display:block;border:0"></td>',
               o.primary_color, private.html_esc(o.logo_url), private.html_esc(o.name))
      else
        format('<td style="background:#ffffff;padding:18px 24px;border-radius:12px 12px 0 0;border-bottom:1px solid #e3e8ef"><img src="%s/brand/logo.png" alt="Sonoran Point" height="44" style="height:44px;width:auto;display:block;border:0"></td>', v_url)
      end;

    insert into private.email_batches (org_id, to_email, subject, html, body_text)
    values (g.org_id, g.to_email, v_subject,
      format('<div style="background:#f1f4f8;padding:24px 12px;font-family:Arial,Helvetica,sans-serif;color:#121a24">'
        || '<table role="presentation" cellpadding="0" cellspacing="0" style="width:100%%;max-width:560px;margin:0 auto;background:#ffffff;border-radius:12px;border:1px solid #e3e8ef;border-collapse:separate">'
        || '<tr>%s</tr><tr><td style="padding:22px 24px 8px">'
        || '<p style="font-size:13px;color:#5b6878;margin:0 0 4px">%s</p><h1 style="font-size:21px;margin:0 0 6px">%s</h1>'
        || '<table role="presentation" style="width:100%%;border-collapse:collapse">%s</table>'
        || '<p style="margin:18px 0 22px"><a href="%s/%s" style="background:#1d5fd1;color:#ffffff;padding:11px 18px;border-radius:8px;text-decoration:none;font-weight:700;display:inline-block">%s</a></p>'
        || '</td></tr></table>'
        || '<p style="font-size:12px;color:#8592a3;max-width:560px;margin:14px auto 0;text-align:center">You get these emails because of your alert settings. Change them in the dashboard under Settings, Email alerts.</p></div>',
        v_header, private.html_esc(o.name), v_heading, rows_html, v_url, v_button,
        case when g.cnt > 1 then 'See all alerts' when v_kind = 'shift_report' then 'Open the report' else 'Open the item' end),
      o.name || E'\n' || v_heading || E'\n\n' || rows_text
        || E'\n\nYou get these emails because of your alert settings. Change them in the dashboard under Settings, Email alerts.')
    returning id into v_id;
    update private.email_queue set batch_id = v_id where id = any (g.ids);
    n := n + 1;
  end loop;
  return n;
end $$;

revoke execute on all functions in schema private from public, anon, authenticated;
grant  execute on function private.has_org_role(uuid, public.member_role) to authenticated;
grant  execute on function private.normalize_uid(text) to anon, authenticated;
grant  execute on function private.resolve_time_limit(public.time_limit_mode, numeric, public.time_limit_type, numeric) to authenticated;
grant  execute on function private.can_manage_logo(text) to authenticated;
