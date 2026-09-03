-- Vierter Bibliotheks-Check-in-Punkt "auswaerts" (Auswärts / zu Hause,
-- eigene Fläche im Streckenbild, siehe LIBRARY_BUILDINGS in index.html).
-- Additive CHECK-Erweiterung, kein Backfill nötig. get_library_checkins()
-- (Migration 20260901000000_library_checkin.sql) bleibt unverändert, da
-- gebäude-agnostisch.
ALTER TABLE public.profiles DROP CONSTRAINT IF EXISTS profiles_library_checkin_check;
ALTER TABLE public.profiles ADD CONSTRAINT profiles_library_checkin_check
  CHECK (library_checkin IS NULL OR library_checkin IN ('steintor', 'neuwerk', 'juri', 'auswaerts'));
