-- Triggert täglich die scrape-mensa-menu Edge Function (Deno, deno-dom-
-- basiertes HTML-Parsing des meine-mensa.de-Speiseplan-iframes) per
-- net.http_post. Der Auth-Header liest den Service-Role-Key aus Supabase
-- Vault (Secret 'mensa_scrape_trigger_key') statt ihn hier im Klartext zu
-- committen — das Secret selbst wird VOR dieser Migration einmalig manuell
-- angelegt (SQL-Editor / `supabase db query --linked`, NICHT als
-- Migrationsdatei):
--   select vault.create_secret('<SERVICE_ROLE_KEY>', 'mensa_scrape_trigger_key');
--
-- Zeitpunkt 3:10 UTC: die 4-Uhr-Berlin-Tagesgrenze liegt winters bei
-- 3:00 UTC, sommers bei 2:00 UTC — 3:10 UTC liegt in BEIDEN Fällen sicher
-- danach (gleiches DST-Argument wie bei prune-cron-job-run-details /
-- daily-winners).
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
    body := jsonb_build_object('trigger', 'cron')
  ) as request_id;
  $$
);
