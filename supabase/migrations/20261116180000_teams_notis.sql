-- Teams-notis till Claes när regnummer behöver bytas i garagets system.
--  * Kl 18 svensk tid: sammanfattning för imorgon (en gång per dag, bara om något ska bytas).
--  * Bokningar som görs efter 18 för imorgon, eller för idag, postas direkt.
-- Webhook-länken (Teams Workflows "Post to a chat when a webhook request is received")
-- sparas i Supabase Vault under namnet 'teams_webhook_url', aldrig i git:
--   select vault.create_secret('<länk>', 'teams_webhook_url', 'Teams-notis ParkeringsApp');

create extension if not exists pg_net;
create extension if not exists pg_cron;

-- "ABC123" -> "ABC 123"
create or replace function park_fmt_plate(p text) returns text
language sql immutable as $$
  select case when p ~ '^[A-ZÅÄÖ]{3}[0-9]{2}[A-Z0-9]$' then substr(p,1,3) || ' ' || substr(p,4) else coalesce(p, '(tomt)') end
$$;

-- "tisdag 17/11"
create or replace function park_fmt_day(d date) returns text
language sql immutable as $$
  select (array['söndag','måndag','tisdag','onsdag','torsdag','fredag','lördag'])[extract(dow from d)::int + 1]
         || ' ' || extract(day from d)::int || '/' || extract(month from d)::int
$$;

-- Adaptive Card i det format Teams Workflows förväntar sig
create or replace function park_teams_card(p_title text, p_lines text[]) returns jsonb
language sql immutable as $$
  select jsonb_build_object(
    'type', 'message',
    'attachments', jsonb_build_array(jsonb_build_object(
      'contentType', 'application/vnd.microsoft.card.adaptive',
      'contentUrl', null,
      'content', jsonb_build_object(
        '$schema', 'http://adaptivecards.io/schemas/adaptive-card.json',
        'type', 'AdaptiveCard',
        'version', '1.4',
        'body', jsonb_build_array(jsonb_build_object('type', 'TextBlock', 'text', p_title, 'weight', 'Bolder', 'size', 'Medium', 'wrap', true))
                || coalesce((select jsonb_agg(jsonb_build_object('type', 'TextBlock', 'text', l, 'wrap', true, 'spacing', 'Small'))
                               from unnest(p_lines) l), '[]'::jsonb)
      )
    ))
  )
$$;

create or replace function park_post_teams(p_title text, p_lines text[]) returns bigint
language plpgsql security definer set search_path = public, extensions as $$
declare url text; rid bigint;
begin
  select decrypted_secret into url from vault.decrypted_secrets where name = 'teams_webhook_url';
  if url is null then
    raise notice 'Ingen teams_webhook_url i Vault, ingen notis skickad';
    return null;
  end if;
  select net.http_post(
    url     := url,
    body    := park_teams_card(p_title, p_lines),
    headers := '{"Content-Type": "application/json"}'::jsonb
  ) into rid;
  insert into notifications_log(day, body) values (park_today(), p_title || E'\n' || array_to_string(p_lines, E'\n'));
  return rid;
end $$;

-- Sammanfattning för imorgon. Körs av cron varje timme 16 och 17 UTC; gör bara något kl 18 svensk tid.
create or replace function park_notify_changes(p_force boolean default false) returns int
language plpgsql security definer set search_path = public, extensions as $$
declare d date := park_today() + 1; lines text[]; n int;
begin
  if not p_force then
    if extract(hour from now() at time zone 'Europe/Stockholm') <> 18 then return 0; end if;
    if exists (select 1 from notifications_log where day = park_today() and body like 'Parkering imorgon%') then return 0; end if;
  end if;
  select coalesce(array_agg(format('**%s:** byt %s → %s (%s)', permit, park_fmt_plate(from_plate), park_fmt_plate(to_plate), member)), '{}'), count(*)
    into lines, n
    from park_pending_changes(d);
  if n = 0 then return 0; end if;
  perform park_post_teams(
    format('Parkering imorgon %s: %s regnummer att byta', park_fmt_day(d), n),
    lines || array['Tryck **Klart** i appen när det är ändrat i parkeringssystemet.']);
  return n;
end $$;

-- Bokning efter kl 18 för imorgon, eller för idag: posta direkt om regnumret behöver bytas
create or replace function park_booking_notify() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
declare r record; late boolean;
begin
  late := new.day = park_today()
       or (new.day = park_today() + 1 and extract(hour from now() at time zone 'Europe/Stockholm') >= 18);
  if not late then return new; end if;
  select p.name as permit, p.current_plate, v.plate, m.name as member into r
    from permits p, vehicles v, members m
   where p.id = new.permit_id and v.id = new.vehicle_id and m.id = new.member_id;
  if r.plate is distinct from r.current_plate then
    perform park_post_teams(
      format('Sen bokning %s %s', case when new.day = park_today() then 'idag' else 'imorgon' end, park_fmt_day(new.day)),
      array[format('**%s:** byt %s → %s (%s)', r.permit, park_fmt_plate(r.current_plate), park_fmt_plate(r.plate), r.member),
            'Tryck **Klart** i appen när det är ändrat i parkeringssystemet.']);
  end if;
  return new;
end $$;

drop trigger if exists park_booking_notify on bookings;
create trigger park_booking_notify after insert on bookings
  for each row execute function park_booking_notify();

-- Inga av dessa ska kunna anropas från webbläsaren
revoke all on function park_post_teams(text, text[])  from public, anon, authenticated;
revoke all on function park_notify_changes(boolean)   from public, anon, authenticated;
revoke all on function park_booking_notify()           from public, anon, authenticated;
revoke all on function park_teams_card(text, text[])   from public, anon, authenticated;

-- 16:00 och 17:00 UTC = 18:00 svensk sommar- resp. vintertid; funktionen väljer rätt timme
select cron.schedule('park-notify-teams', '0 16,17 * * *', $$select public.park_notify_changes()$$);
