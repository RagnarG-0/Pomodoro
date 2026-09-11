-- ACHTUNG — REVIEW EMPFOHLEN, nicht blind pushen (siehe CLAUDE.md
-- "Migrationen anwenden"): pg_net ist eine neue Capability-Klasse
-- (Postgres kann damit beliebige ausgehende HTTP-Requests machen), kein
-- reines additives Datenschema wie sonstige Migrationen in diesem Projekt.
-- Wird ausschließlich für den täglichen Mensa-Scrape-Trigger gebraucht
-- (siehe 20260911000030_mensa_scrape_cron.sql, ruft die scrape-mensa-menu
-- Edge Function auf).
CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;
