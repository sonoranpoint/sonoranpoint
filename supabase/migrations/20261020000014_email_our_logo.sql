-- =====================================================================
-- 14: Alert emails always carry Sonoran Point's logo on white (no customer colors or logos).
-- =====================================================================
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

    -- Always Sonoran Point's logo on white; the company's name sits under it.
    v_header := format('<td style="background:#ffffff;padding:20px 24px 14px;border-radius:12px 12px 0 0;border-bottom:1px solid #e3e8ef">'
      || '<img src="%s/brand/logo.png" alt="Sonoran Point Technologies" width="170" style="width:170px;height:auto;display:block;border:0"></td>', v_url);

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
