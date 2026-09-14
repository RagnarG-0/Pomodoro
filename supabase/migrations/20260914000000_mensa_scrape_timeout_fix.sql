-- Fix: der automatische scrape-mensa-menu-Lauf schlug am 2026-09-14 03:10 UTC
-- fehl mit "Timeout of 5000 ms reached" (net._http_response.error_msg) —
-- net.http_post()'s Default-timeout_milliseconds ist 5000, die Edge Function
-- macht intern aber 2 sequenzielle externe HTTP-Roundtrips zu
-- meine-mensa.de (GET Session/CSRF, dann POST fürs Speiseplan-HTML) plus
-- ggf. einen Deno-Cold-Start (erster Aufruf nach Tagen Inaktivität, z.B.
-- übers Wochenende) — das reißt zusammen leicht die 5s. Da die Function bei
-- jedem Fehler VOR replace_mensa_menu() abbricht (siehe scrape-mensa-menu/
-- index.ts), blieb mensa_menu_items einfach auf dem letzten erfolgreichen
-- Stand stehen (hier: Freitag), und der Client zeigte via date-Filter
-- korrekt "kein Plan verfügbar" für alle 4 Mensen (kein Client-/RLS-Bug).
--
-- cron.schedule() auf einen bereits existierenden Jobnamen legt keinen
-- zweiten Job an, sondern aktualisiert command/schedule des bestehenden
-- Jobs in-place — kein vorheriges cron.unschedule() nötig.
select cron.schedule(
  'scrape-mensa-menu',
  '10 3 * * *',
  $$
  select net.http_post(
    url := 'https://cmbyzzfjzrhdxylopqkt.supabase.co/functions/v1/scrape-mensa-menu',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (
        select decrypted_secret from vault.decrypted_secrets
        where name = 'mensa_scrape_trigger_key'
      )
    ),
    body := jsonb_build_object('trigger', 'cron'),
    timeout_milliseconds := 20000
  ) as request_id;
  $$
);
