# ParkeringsApp – Sundstorgsgaraget plan 2

Mobilwebbapp där kollegorna bokar de två p-platserna dagen innan (först till kvarn),
registrerar sina regnummer (flera per person går bra) och där Claes ser vilka regnummer
som behöver bytas i garagets parkeringssystem.

## Filer
| Fil | Vad |
|---|---|
| `src/app.html` | Själva appen (HTML/CSS/JS, inga beroenden) |
| `build.sh` | Bygger `public/index.html` (kör `sh build.sh`) |
| `public/index.html` | Byggs av `build.sh` (ignoreras av git) |
| `supabase/migrations/` | Databasen som Supabase CLI-migrationer (`supabase db push`) |
| `supabase/schema.sql` | Samma databas som ett skript för SQL Editor, inkl. gruppkod |
| `vercel.json` | Vercel bygger med `sh build.sh` och publicerar `public/` |

## Regler som är inbyggda
- Bokning går för **idag och imorgon**. Först till kvarn, en plats per person och dag.
- Två platser ("tillstånd") som standard. Fler läggs till med en rad i tabellen `permits`.
- Om en ledig plats redan har ens regnummer registrerat väljs den först, så att Claes slipper byta.
- Varje plats har ett "regnummer i systemet". Står det något annat på morgondagens bokning
  hamnar det i Claes lista **Att ändra**. När han bytt i garagets system trycker han **Klart**.
- Ingen bokning en dag = inget byte behövs, regnumret ligger kvar.
- Inloggning: en gemensam gruppkod + välj sitt namn. Claes är markerad som administratör.
  (Enkelt med flit för 4–6 kollegor. Byt till e-postinloggning om fler ska in.)

## Driftsättning (ca 15 min)
1. **Supabase:** `supabase link --project-ref sntuuntgoyagccpvtpvf` och `supabase db push`.
   Sätt sedan gruppkoden i SQL Editor (skriv den med gemener, appen gör om det användaren skriver till gemener):
   `insert into app_config(key,value) values ('group_code_hash', extensions.crypt('ER-KOD', extensions.gen_salt('bf'))) on conflict (key) do update set value = excluded.value;`
2. Project URL och publishable key står redan i `CONFIG` i `src/app.html`.
3. **Vercel:** importera GitHub-repot på vercel.com/new. Varje push till `main` publiceras automatiskt.
4. Skicka länken + gruppkoden i Teams-chatten "Parkering Helsingborg".
   Tips: "Lägg till på hemskärmen" i mobilen så blir det som en app.

## Notis till Claes (nästa steg)
Förslag: varje kväll kl 18:00 körs ett jobb (Supabase `pg_cron` + Edge Function) som anropar
`park_pending_changes()` och skickar listan till Claes om den inte är tom.
Kanal att välja: e-post (t.ex. Resend, kräver API-nyckel), SMS, eller Teams via webhook till kanalen.

## Automatisk ändring i parkeringssystemet
Möjligt med webbläsarautomation (Claude i webbläsaren eller ett Playwright-skript) men kräver
Claes inloggning, systemets adress och att leverantörens villkor tillåter automatiserad inloggning.
Ej uppsatt ännu.
