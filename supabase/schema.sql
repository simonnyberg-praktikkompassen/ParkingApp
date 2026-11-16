-- ParkeringsApp – databas för Supabase (Postgres)
-- Kör hela filen i Supabase SQL Editor i ett NYTT projekt.
-- Ingen tabell kan läsas direkt från webbläsaren (RLS utan policies).
-- All åtkomst går via funktionerna nedan, som kräver gruppkoden.

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------
-- Tabeller
-- ---------------------------------------------------------------
create table if not exists app_config (
  key   text primary key,
  value text not null
);

create table if not exists members (
  id         uuid primary key default gen_random_uuid(),
  name       text not null unique,
  is_admin   boolean not null default false,
  active     boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists vehicles (
  id         uuid primary key default gen_random_uuid(),
  member_id  uuid not null references members(id) on delete cascade,
  plate      text not null unique,
  created_at timestamptz not null default now()
);

-- Ett tillstånd = en plats i garaget som är kopplad till ett regnummer
create table if not exists permits (
  id            int primary key,
  name          text not null,
  current_plate text,                 -- det regnummer som just nu ligger i parkeringssystemet
  updated_at    timestamptz,
  updated_by    uuid references members(id)
);

create table if not exists bookings (
  id         uuid primary key default gen_random_uuid(),
  day        date not null,
  permit_id  int  not null references permits(id),
  member_id  uuid not null references members(id) on delete cascade,
  vehicle_id uuid not null references vehicles(id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (day, permit_id),            -- en bil per plats och dag
  unique (day, member_id)             -- en plats per person och dag
);

create table if not exists notifications_log (
  id      bigserial primary key,
  day     date not null,
  sent_at timestamptz not null default now(),
  body    text not null
);

alter table app_config        enable row level security;
alter table members           enable row level security;
alter table vehicles          enable row level security;
alter table permits           enable row level security;
alter table bookings          enable row level security;
alter table notifications_log enable row level security;

-- ---------------------------------------------------------------
-- Hjälpfunktioner
-- ---------------------------------------------------------------
create or replace function park_today() returns date
language sql stable as $$ select (now() at time zone 'Europe/Stockholm')::date $$;

create or replace function park_check_code(p_code text) returns void
language plpgsql stable security definer set search_path = public, extensions as $$
declare h text;
begin
  select value into h from app_config where key = 'group_code_hash';
  if h is null or crypt(coalesce(p_code,''), h) <> h then
    raise exception 'Fel gruppkod' using errcode = '28000';
  end if;
end $$;

create or replace function park_norm_plate(p text) returns text
language sql immutable as $$ select upper(regexp_replace(coalesce(p,''), '[^A-Za-z0-9ÅÄÖåäö]', '', 'g')) $$;

-- ---------------------------------------------------------------
-- API (anropas från appen via /rest/v1/rpc/<namn>)
-- ---------------------------------------------------------------
create or replace function park_state(p_code text) returns json
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform park_check_code(p_code);
  return json_build_object(
    'today',    park_today(),
    'members',  coalesce((select json_agg(m order by m.name) from (select id, name, is_admin from members where active) m), '[]'),
    'vehicles', coalesce((select json_agg(v order by v.plate) from (select id, member_id, plate from vehicles) v), '[]'),
    'permits',  coalesce((select json_agg(p order by p.id) from (select id, name, current_plate, updated_at from permits) p), '[]'),
    'bookings', coalesce((select json_agg(b order by b.day, b.permit_id) from (
                  select id, day, permit_id, member_id, vehicle_id, created_at
                  from bookings where day between park_today() - 1 and park_today() + 7) b), '[]')
  );
end $$;

create or replace function park_add_member(p_code text, p_name text) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare new_id uuid; n text := btrim(p_name);
begin
  perform park_check_code(p_code);
  if length(n) < 2 then raise exception 'Skriv ditt namn'; end if;
  if (select count(*) from members where active) >= 12 then raise exception 'Max antal användare nått'; end if;
  insert into members(name) values (n)
    on conflict (name) do update set active = true
    returning id into new_id;
  return new_id;
end $$;

create or replace function park_add_vehicle(p_code text, p_member uuid, p_plate text) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare new_id uuid; pl text := park_norm_plate(p_plate);
begin
  perform park_check_code(p_code);
  if length(pl) < 2 or length(pl) > 8 then raise exception 'Ogiltigt registreringsnummer'; end if;
  if exists (select 1 from vehicles where plate = pl) then raise exception 'Regnumret % finns redan', pl; end if;
  insert into vehicles(member_id, plate) values (p_member, pl) returning id into new_id;
  return new_id;
end $$;

create or replace function park_remove_vehicle(p_code text, p_member uuid, p_vehicle uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform park_check_code(p_code);
  if exists (select 1 from bookings where vehicle_id = p_vehicle and day >= park_today()) then
    raise exception 'Bilen har en kommande bokning. Avboka först.';
  end if;
  delete from vehicles where id = p_vehicle and member_id = p_member;
end $$;

-- Först till kvarn: tar lägsta lediga plats. Bokning går för idag och imorgon.
create or replace function park_book(p_code text, p_member uuid, p_vehicle uuid, p_day date) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare free_permit int; new_id uuid;
begin
  perform park_check_code(p_code);
  if p_day < park_today() or p_day > park_today() + 1 then
    raise exception 'Du kan bara boka för idag eller imorgon';
  end if;
  if not exists (select 1 from vehicles where id = p_vehicle and member_id = p_member) then
    raise exception 'Bilen tillhör inte dig';
  end if;
  if exists (select 1 from bookings where day = p_day and member_id = p_member) then
    raise exception 'Du har redan en plats den dagen';
  end if;
  -- Lås för att två personer inte ska få samma plats samtidigt
  perform pg_advisory_xact_lock(hashtext('park_book_' || p_day::text));
  -- Föredra en plats där bilen redan ligger registrerad (då behövs ingen ändring)
  select p.id into free_permit
    from permits p
   where not exists (select 1 from bookings b where b.day = p_day and b.permit_id = p.id)
   order by (p.current_plate = (select plate from vehicles where id = p_vehicle)) desc nulls last, p.id
   limit 1;
  if free_permit is null then raise exception 'Alla platser är redan bokade'; end if;
  insert into bookings(day, permit_id, member_id, vehicle_id)
    values (p_day, free_permit, p_member, p_vehicle) returning id into new_id;
  return json_build_object('id', new_id, 'permit_id', free_permit);
end $$;

create or replace function park_cancel(p_code text, p_member uuid, p_booking uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform park_check_code(p_code);
  delete from bookings
   where id = p_booking
     and day >= park_today()
     and (member_id = p_member or exists (select 1 from members where id = p_member and is_admin));
end $$;

-- Claes bekräftar att han har bytt regnummer i parkeringssystemet
create or replace function park_mark_done(p_code text, p_member uuid, p_permit int, p_plate text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform park_check_code(p_code);
  if not exists (select 1 from members where id = p_member and is_admin) then
    raise exception 'Bara administratören kan bekräfta ändringar';
  end if;
  update permits set current_plate = park_norm_plate(p_plate), updated_at = now(), updated_by = p_member
   where id = p_permit;
end $$;

-- Lista över ändringar som behöver göras för en dag (används av notisen)
create or replace function park_pending_changes(p_day date default null) returns table(permit text, from_plate text, to_plate text, member text)
language sql stable security definer set search_path = public as $$
  select p.name, p.current_plate, v.plate, m.name
    from bookings b
    join permits  p on p.id = b.permit_id
    join vehicles v on v.id = b.vehicle_id
    join members  m on m.id = b.member_id
   where b.day = coalesce(p_day, park_today() + 1)
     and v.plate is distinct from p.current_plate
   order by p.id
$$;

revoke all on function park_pending_changes(date) from public, anon, authenticated;
revoke all on function park_check_code(text) from public, anon, authenticated;

grant execute on function park_state(text)                          to anon;
grant execute on function park_add_member(text, text)               to anon;
grant execute on function park_add_vehicle(text, uuid, text)        to anon;
grant execute on function park_remove_vehicle(text, uuid, uuid)     to anon;
grant execute on function park_book(text, uuid, uuid, date)         to anon;
grant execute on function park_cancel(text, uuid, uuid)             to anon;
grant execute on function park_mark_done(text, uuid, int, text)     to anon;

-- ---------------------------------------------------------------
-- Startdata – ÄNDRA gruppkoden innan du kör!
-- ---------------------------------------------------------------
insert into app_config(key, value)
values ('group_code_hash', crypt('BYT-MIG', gen_salt('bf')))
on conflict (key) do nothing;

insert into permits(id, name, current_plate) values
  (1, 'Tillstånd 1', null),
  (2, 'Tillstånd 2', null)
on conflict (id) do nothing;

insert into members(name, is_admin) values
  ('Claes', true), ('Martin', false), ('Simon', false), ('Anders', false), ('Robert', false)
on conflict (name) do nothing;
