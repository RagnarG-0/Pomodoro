-- cron.job_run_details wächst unbegrenzt (pg_cron räumt es nie automatisch
-- auf) und war mit 32 MB / 34.861 Zeilen bereits der mit Abstand größte
-- Treiber des Datenbank-Wachstums (~65% der Gesamtgröße von ~49 MB),
-- komplett unabhängig von der eigentlichen App-Nutzung (reines
-- Ausführungs-Log der reset-stale-work-sessions-/daily-winners-Jobs, ohne
-- jede Verknüpfung zu App-Tabellen wie pomodoro_sessions/study_days).
--
-- Neuer täglicher Cron-Job löscht Log-Einträge älter als 7 Tage — reicht
-- zum Nachvollziehen eines aktuellen Cron-Problems, hält die Tabelle aber
-- dauerhaft klein statt unbegrenzt zu wachsen. Zeitpunkt (03:30 UTC)
-- bewusst außerhalb der bestehenden */5-Minuten-Jobs gewählt.
select cron.schedule(
  'prune-cron-job-run-details',
  '30 3 * * *',
  $$ delete from cron.job_run_details where start_time < now() - interval '7 days'; $$
);
