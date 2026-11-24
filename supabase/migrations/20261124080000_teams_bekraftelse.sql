-- Bekräftelse i Teams när Claes tryckt "Klart, jag har ändrat" i appen.
-- Postas via samma webhook som övriga notiser (park_post_teams, Vault 'teams_webhook_url').
-- Skickas bara när regnumret faktiskt ändras, så ett dubbeltryck ger inte två meddelanden.

create or replace function park_mark_done(p_code text, p_member uuid, p_permit int, p_plate text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  new_plate text := park_norm_plate(p_plate);
  old_plate text;
  admin_name text;
  who text;
  d date;
begin
  perform park_check_code(p_code);
  select name into admin_name from members where id = p_member and is_admin;
  if admin_name is null then
    raise exception 'Bara administratören kan bekräfta ändringar';
  end if;

  select current_plate into old_plate from permits where id = p_permit;
  update permits set current_plate = new_plate, updated_at = now(), updated_by = p_member
   where id = p_permit;

  if old_plate is distinct from new_plate then
    -- Vem som står där: närmaste bokning idag eller framåt med det regnumret
    select m.name, b.day into who, d
      from bookings b
      join vehicles v on v.id = b.vehicle_id
      join members  m on m.id = b.member_id
     where b.permit_id = p_permit and v.plate = new_plate and b.day >= park_today()
     order by b.day
     limit 1;

    begin
      perform park_post_teams(
        format('Klart: Plats %s ändrad i parkeringssystemet', p_permit),
        array[
          format('**Plats %s:** %s → %s%s', p_permit, park_fmt_plate(old_plate), park_fmt_plate(new_plate),
                 case when who is not null
                      then format(' (%s, %s)', who,
                                  case when d = park_today() then 'idag'
                                       when d = park_today() + 1 then 'imorgon'
                                       else park_fmt_day(d) end)
                      else '' end),
          format('Bekräftat av %s kl %s.', admin_name, to_char(now() at time zone 'Europe/Stockholm', 'HH24:MI'))
        ]);
    exception when others then
      -- Teams-fel får aldrig stoppa själva markeringen i appen
      raise warning 'Teams-bekräftelse misslyckades: %', sqlerrm;
    end;
  end if;
end $$;

grant execute on function park_mark_done(text, uuid, int, text) to anon;
