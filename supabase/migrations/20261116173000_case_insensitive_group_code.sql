-- Gruppkoden är inte skiftlägeskänslig: koden jämförs i gemener och utan mellanslag runt.
-- Hashen i app_config ska därför skapas från koden i gemener.
create or replace function park_check_code(p_code text) returns void
language plpgsql stable security definer set search_path = public, extensions as $$
declare h text;
begin
  select value into h from app_config where key = 'group_code_hash';
  if h is null or crypt(lower(btrim(coalesce(p_code,''))), h) <> h then
    raise exception 'Fel gruppkod' using errcode = '28000';
  end if;
end $$;

revoke all on function park_check_code(text) from public, anon, authenticated;
