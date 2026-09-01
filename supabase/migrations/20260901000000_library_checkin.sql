-- profiles: Bibliotheks-Check-in (+ Datum). Kein Reset-Cron nötig —
-- get_library_checkins() filtert unten ohnehin auf library_checkin_date =
-- heute (Berlin, 4-Uhr-Grenze), exakt das gleiche Prinzip wie bei
-- study_days/race_checkpoint_claims (Werte werden nie aktiv gelöscht, nur
-- nach Datum gefiltert).
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS library_checkin text;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS library_checkin_date date;

ALTER TABLE public.profiles DROP CONSTRAINT IF EXISTS profiles_library_checkin_check;
ALTER TABLE public.profiles ADD CONSTRAINT profiles_library_checkin_check
  CHECK (library_checkin IS NULL OR library_checkin IN ('steintor', 'neuwerk', 'juri'));

-- get_library_checkins(): alle heute eingecheckten, öffentlich sichtbaren
-- Clan-Mitglieder — gleiches Scoping wie leaderboard_today() (public=true,
-- my_clan_id()), aber ohne Join auf study_days (Check-in ist unabhängig von
-- heutiger Fokuszeit).
CREATE OR REPLACE FUNCTION public.get_library_checkins()
RETURNS TABLE (name text, avatar_url text, library text)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT p.username, p.avatar_url, p.library_checkin
  FROM profiles p
  WHERE p.public = true
    AND p.clan_id = my_clan_id()
    AND p.library_checkin IS NOT NULL
    AND p.library_checkin_date = ((now() AT TIME ZONE 'Europe/Berlin') - interval '4 hours')::date;
$$;

GRANT EXECUTE ON FUNCTION public.get_library_checkins() TO anon, authenticated, service_role;
