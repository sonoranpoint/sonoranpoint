-- 28: Requests (leads and support tickets) in the console.
--   * Every contact form message is a request. "Help with my account" is support; anything else is a lead.
--     A request from someone already on a customer's team (or their contact email) is linked to that customer.
--   * Status: new, open, waiting (on them), won / lost (leads), closed (support), spam. Each can be assigned to
--     someone on your team. Notes, replies and changes are kept as its history (private.contact_events).
--   * Replies are emailed from no-reply@ with reply-to set to the operator who wrote them.
--   * Requests can also be added by hand (a phone call, someone met at a trade show): email is optional then.

alter table private.contact_requests
  alter column email drop not null,
  alter column message drop not null,
  add column if not exists kind        text not null default 'lead' check (kind in ('lead', 'support')),
  add column if not exists status      text not null default 'new' check (status in ('new', 'open', 'waiting', 'won', 'lost', 'closed', 'spam')),
  add column if not exists assigned_to uuid references auth.users(id) on delete set null,
  add column if not exists org_id      uuid references public.organizations(id) on delete set null,
  add column if not exists source      text not null default 'website' check (source in ('website', 'console')),
  add column if not exists updated_at  timestamptz not null default now(),
  add column if not exists closed_at   timestamptz;
create index if not exists contact_requests_open on private.contact_requests (status, created_at desc);

create table if not exists private.contact_events (
  id          bigint generated always as identity primary key,
  request_id  bigint not null references private.contact_requests(id) on delete cascade,
  at          timestamptz not null default now(),
  operator    uuid references auth.users(id) on delete set null,
  kind        text not null,   -- created, note, reply, status, kind, assigned, customer, details
  text        text,
  details     jsonb not null default '{}'
);
create index if not exists contact_events_req on private.contact_events (request_id, at desc);

-- Website messages: support or lead from the topic, linked to a customer when we know the sender.
create or replace function private.contact_request_defaults()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.source = 'website' then
    new.kind := case when new.topic = 'Help with my account' then 'support' else 'lead' end;
  end if;
  if new.org_id is null and new.email is not null then
    select o.id into new.org_id from public.organizations o
     where lower(o.contact_email) = new.email
        or exists (select 1 from public.org_members m join auth.users u on u.id = m.user_id where m.org_id = o.id and lower(u.email) = new.email)
     order by o.created_at limit 1;
  end if;
  return new;
end $$;
drop trigger if exists contact_request_defaults on private.contact_requests;
create trigger contact_request_defaults before insert on private.contact_requests for each row execute function private.contact_request_defaults();

create or replace function private.contact_request_created()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into private.contact_events (request_id, at, operator, kind, details)
  values (new.id, new.created_at, case when new.source = 'console' then auth.uid() end, 'created', jsonb_build_object('source', new.source));
  return new;
end $$;
drop trigger if exists contact_request_created on private.contact_requests;
create trigger contact_request_created after insert on private.contact_requests for each row execute function private.contact_request_created();

-- Messages sent before this update get their history started.
insert into private.contact_events (request_id, at, kind, details)
select r.id, r.created_at, 'created', '{"source":"website"}' from private.contact_requests r
where not exists (select 1 from private.contact_events e where e.request_id = r.id);
update private.contact_requests set kind = 'support' where topic = 'Help with my account' and kind = 'lead';

create or replace function private.operator_name(p_user uuid) returns text language sql stable security definer set search_path = public as $$
  select coalesce(nullif(po.name, ''), split_part(u.email, '@', 1)) from auth.users u left join private.platform_operators po on po.user_id = u.id where u.id = p_user
$$;

create or replace function private.request_json(r private.contact_requests) returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', r.id, 'created_at', r.created_at, 'updated_at', r.updated_at, 'closed_at', r.closed_at,
    'name', r.name, 'email', r.email, 'company', r.company, 'phone', r.phone, 'topic', r.topic, 'message', r.message,
    'kind', r.kind, 'status', r.status, 'source', r.source,
    'assigned_to', r.assigned_to, 'assigned_name', private.operator_name(r.assigned_to),
    'org_id', r.org_id, 'customer', (select name from public.organizations where id = r.org_id),
    'last_at', coalesce((select max(at) from private.contact_events e where e.request_id = r.id), r.created_at),
    'notes', (select count(*) from private.contact_events e where e.request_id = r.id and e.kind in ('note', 'reply')))
$$;

create or replace function public.platform_requests()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform private.require_operator();
  return coalesce((select jsonb_agg(private.request_json(r) order by r.created_at desc) from private.contact_requests r), '[]'::jsonb);
end $$;

create or replace function public.platform_request(p_id bigint)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare r private.contact_requests;
begin
  perform private.require_operator();
  select * into r from private.contact_requests where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  return jsonb_build_object('ok', true, 'request', private.request_json(r),
    'events', coalesce((select jsonb_agg(jsonb_build_object('at', e.at, 'kind', e.kind, 'text', e.text, 'details', e.details,
        'by', case when e.operator is null then null else private.operator_name(e.operator) end) order by e.at desc, e.id desc)
      from private.contact_events e where e.request_id = p_id), '[]'::jsonb));
end $$;

-- Change status, type, who has it, the customer it's about, or the contact details. Only the keys sent change.
create or replace function public.platform_update_request(p_id bigint, p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r private.contact_requests; v_user uuid; v_org uuid; v_email text;
begin
  perform private.require_operator();
  select * into r from private.contact_requests where id = p_id for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if p ? 'status' and p->>'status' is distinct from r.status then
    if p->>'status' not in ('new', 'open', 'waiting', 'won', 'lost', 'closed', 'spam') then return jsonb_build_object('ok', false, 'error', 'bad_status'); end if;
    insert into private.contact_events (request_id, operator, kind, details) values (p_id, auth.uid(), 'status', jsonb_build_object('from', r.status, 'to', p->>'status'));
    r.status := p->>'status';
    r.closed_at := case when r.status in ('won', 'lost', 'closed', 'spam') then now() end;
  end if;
  if p ? 'kind' and p->>'kind' is distinct from r.kind then
    if p->>'kind' not in ('lead', 'support') then return jsonb_build_object('ok', false, 'error', 'bad_kind'); end if;
    insert into private.contact_events (request_id, operator, kind, details) values (p_id, auth.uid(), 'kind', jsonb_build_object('to', p->>'kind'));
    r.kind := p->>'kind';
    if r.kind = 'support' and r.status in ('won', 'lost') then r.status := 'closed'; end if;
    if r.kind = 'lead' and r.status = 'closed' then r.status := 'lost'; end if;
  end if;
  if p ? 'assigned_to' then
    v_user := nullif(p->>'assigned_to', '')::uuid;
    if v_user is not null and not exists (select 1 from private.platform_operators where user_id = v_user) then return jsonb_build_object('ok', false, 'error', 'not_operator'); end if;
    if v_user is distinct from r.assigned_to then
      insert into private.contact_events (request_id, operator, kind, details) values (p_id, auth.uid(), 'assigned', jsonb_build_object('to', private.operator_name(v_user)));
      r.assigned_to := v_user;
    end if;
  end if;
  if p ? 'org_id' then
    v_org := nullif(p->>'org_id', '')::uuid;
    if v_org is not null and not exists (select 1 from public.organizations where id = v_org) then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
    if v_org is distinct from r.org_id then
      insert into private.contact_events (request_id, operator, kind, details) values (p_id, auth.uid(), 'customer', jsonb_build_object('to', (select name from public.organizations where id = v_org)));
      r.org_id := v_org;
    end if;
  end if;
  if p ?| array['name', 'email', 'company', 'phone'] then
    v_email := case when p ? 'email' then nullif(lower(btrim(p->>'email')), '') else r.email end;
    if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then return jsonb_build_object('ok', false, 'error', 'bad_email'); end if;
    if p ? 'name' and btrim(coalesce(p->>'name', '')) = '' then return jsonb_build_object('ok', false, 'error', 'bad_name'); end if;
    if (p ? 'name' and btrim(p->>'name') is distinct from r.name) or v_email is distinct from r.email
       or (p ? 'company' and nullif(btrim(p->>'company'), '') is distinct from r.company) or (p ? 'phone' and nullif(btrim(p->>'phone'), '') is distinct from r.phone) then
      insert into private.contact_events (request_id, operator, kind) values (p_id, auth.uid(), 'details');
    end if;
    r.name := case when p ? 'name' then left(btrim(p->>'name'), 100) else r.name end;
    r.email := v_email;
    r.company := case when p ? 'company' then nullif(left(btrim(p->>'company'), 150), '') else r.company end;
    r.phone := case when p ? 'phone' then nullif(left(btrim(p->>'phone'), 40), '') else r.phone end;
  end if;
  update private.contact_requests set status = r.status, closed_at = r.closed_at, kind = r.kind, assigned_to = r.assigned_to, org_id = r.org_id,
    name = r.name, email = r.email, company = r.company, phone = r.phone, updated_at = now() where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.platform_request_note(p_id bigint, p_text text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform private.require_operator();
  if btrim(coalesce(p_text, '')) = '' or length(p_text) > 4000 then return jsonb_build_object('ok', false, 'error', 'bad_note'); end if;
  if not exists (select 1 from private.contact_requests where id = p_id) then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  insert into private.contact_events (request_id, operator, kind, text) values (p_id, auth.uid(), 'note', btrim(p_text));
  update private.contact_requests set updated_at = now(), status = case when status = 'new' then 'open' else status end where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

-- Emails them from no-reply@, with replies going to whoever wrote it. A new or open request becomes "waiting on them".
create or replace function public.platform_request_reply(p_id bigint, p_text text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r private.contact_requests; v_me text; v_name text; v_site text := 'https://sonoranpoint.com';
begin
  perform private.require_operator();
  select * into r from private.contact_requests where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if r.email is null then return jsonb_build_object('ok', false, 'error', 'no_email'); end if;
  if btrim(coalesce(p_text, '')) = '' or length(p_text) > 8000 then return jsonb_build_object('ok', false, 'error', 'bad_note'); end if;
  select u.email into v_me from auth.users u where u.id = auth.uid();
  v_name := private.operator_name(auth.uid());
  insert into private.email_batches (org_id, to_email, reply_to, subject, html, body_text)
  values (r.org_id, r.email, v_me,
    case when r.topic is null then 'Your message to Sonoran Point' else 'Re: ' || r.topic end,
    private.email_html('Sonoran Point', 'Hi ' || split_part(r.name, ' ', 1) || ',',
      '<p style="margin:0 0 12px;white-space:pre-wrap">' || private.html_esc(btrim(p_text)) || '</p><p style="margin:0">' || private.html_esc(v_name) || '<br>Sonoran Point Technologies</p>',
      v_site, 'Visit sonoranpoint.com', 'Reply to this email to answer ' || v_name || ' directly.'),
    'Hi ' || split_part(r.name, ' ', 1) || E',\n\n' || btrim(p_text) || E'\n\n' || v_name || E'\nSonoran Point Technologies');
  insert into private.contact_events (request_id, operator, kind, text, details) values (p_id, auth.uid(), 'reply', btrim(p_text), jsonb_build_object('to', r.email));
  update private.contact_requests set updated_at = now(), status = case when status in ('new', 'open') then 'waiting' else status end,
    assigned_to = coalesce(assigned_to, auth.uid()) where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

-- A request you add yourself: a phone call, someone you met.
create or replace function public.platform_add_request(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_name text := btrim(coalesce(p->>'name', '')); v_email text := nullif(lower(btrim(coalesce(p->>'email', ''))), ''); v_id bigint;
begin
  perform private.require_operator();
  if v_name = '' or length(v_name) > 100 then return jsonb_build_object('ok', false, 'error', 'bad_name'); end if;
  if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then return jsonb_build_object('ok', false, 'error', 'bad_email'); end if;
  if coalesce(p->>'kind', 'lead') not in ('lead', 'support') then return jsonb_build_object('ok', false, 'error', 'bad_kind'); end if;
  insert into private.contact_requests (name, email, company, phone, topic, message, kind, status, source, assigned_to)
  values (left(v_name, 100), v_email, nullif(left(btrim(coalesce(p->>'company', '')), 150), ''), nullif(left(btrim(coalesce(p->>'phone', '')), 40), ''),
    nullif(left(btrim(coalesce(p->>'topic', '')), 60), ''), nullif(left(btrim(coalesce(p->>'message', '')), 4000), ''),
    coalesce(p->>'kind', 'lead'), 'open', 'console', auth.uid())
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

-- Requests can be deleted by owners only (spam that got through, a test).
create or replace function public.platform_delete_request(p_id bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform private.require_operator();
  if not exists (select 1 from private.platform_operators where user_id = auth.uid() and role = 'owner') then return jsonb_build_object('ok', false, 'error', 'owner_only'); end if;
  delete from private.contact_requests where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.submit_contact(p_name text, p_email text, p_message text, p_company text default null,
  p_phone text default null, p_topic text default null, p_website text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_name text := btrim(coalesce(p_name, '')); v_email text := lower(btrim(coalesce(p_email, '')));
        v_msg text := btrim(coalesce(p_message, '')); v_company text := nullif(btrim(coalesce(p_company, '')), '');
        v_phone text := nullif(btrim(coalesce(p_phone, '')), ''); v_topic text := nullif(btrim(coalesce(p_topic, '')), '');
        v_ops text[]; v_console text; v_html text; v_text text; e text; v_id bigint;
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

  insert into private.contact_requests (name, email, company, phone, topic, message) values (v_name, v_email, v_company, v_phone, v_topic, v_msg) returning id into v_id;

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
      private.email_html('sonoranpoint.com', coalesce(v_topic, 'New message'), v_html, v_console || '/#request/' || v_id, 'Open it in the console',
        'Sent from the contact form on sonoranpoint.com.'),
      v_text);
  end loop;
  return jsonb_build_object('ok', true);
end $$;

revoke execute on all functions in schema private from public, anon, authenticated;
grant  execute on function private.has_org_role(uuid, public.member_role) to authenticated;
grant  execute on function private.normalize_uid(text) to anon, authenticated;
grant  execute on function private.resolve_time_limit(public.time_limit_mode, numeric, public.time_limit_type, numeric) to authenticated;
grant  execute on function private.can_manage_logo(text) to authenticated;
grant  execute on function private.can_see(uuid, uuid), private.can_see_equipment(uuid), private.can_see_txn(uuid, uuid, uuid, uuid),
  private.can_see_tap(uuid, uuid, uuid, uuid), private.sees(uuid, uuid, uuid), private.scope_of(uuid, uuid) to authenticated;
revoke execute on function public.platform_requests(), public.platform_request(bigint), public.platform_update_request(bigint, jsonb),
  public.platform_request_note(bigint, text), public.platform_request_reply(bigint, text), public.platform_add_request(jsonb), public.platform_delete_request(bigint) from public, anon;
grant  execute on function public.platform_requests(), public.platform_request(bigint), public.platform_update_request(bigint, jsonb),
  public.platform_request_note(bigint, text), public.platform_request_reply(bigint, text), public.platform_add_request(jsonb), public.platform_delete_request(bigint) to authenticated;
revoke execute on function public.submit_contact(text, text, text, text, text, text, text) from public;
grant  execute on function public.submit_contact(text, text, text, text, text, text, text) to anon, authenticated;
