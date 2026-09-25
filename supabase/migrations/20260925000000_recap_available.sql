-- M2-Recap: serverseitiges Datums-Gate.
-- Der Client zeigt den Recap nur, wenn todayKey() >= '2026-10-04' UND diese
-- Funktion true liefert — schützt gegen falsch gestellte Geräteuhren.
-- Gleiche Tagesgrenze wie todayKey(): 04:00 Uhr Europe/Berlin.
create or replace function public.recap_available()
returns boolean
language sql
stable
as $$
  select ((now() at time zone 'Europe/Berlin') - interval '4 hours')::date >= date '2026-10-04';
$$;

revoke all on function public.recap_available() from public;
grant execute on function public.recap_available() to authenticated;
