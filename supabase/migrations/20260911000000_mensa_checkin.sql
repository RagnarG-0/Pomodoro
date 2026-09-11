-- profiles: Mensa-Check-in (+ Datum), analog Bibliotheks-Check-in
-- (20260901000000_library_checkin.sql). Kein Reset-Cron nötig —
-- get_mensa_checkins() filtert unten auf mensa_checkin_date = heute
-- (Berlin, 4-Uhr-Grenze). 'zuhause' ist gleich Teil des initialen CHECK
-- (anders als 'auswaerts' beim Bibliotheks-Check-in, das nachträglich per
-- separater Migration ergänzt wurde) — kein Grund, das hier zu wiederholen.
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS mensa_checkin text;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS mensa_checkin_date date;

ALTER TABLE public.profiles DROP CONSTRAINT IF EXISTS profiles_mensa_checkin_check;
ALTER TABLE public.profiles ADD CONSTRAINT profiles_mensa_checkin_check
  CHECK (mensa_checkin IS NULL OR mensa_checkin IN
    ('harzmensa', 'franckesche', 'neuwerk', 'tulpe', 'zuhause'));

-- get_mensa_checkins(): alle heute eingecheckten, öffentlich sichtbaren
-- Clan-Mitglieder — exakt gleiches Scoping wie get_library_checkins()
-- (public=true, my_clan_id(), heutiges Datum, Berlin-4-Uhr-Grenze).
-- Hinweis: 'neuwerk' als Wert kollidiert namentlich mit dem
-- library_checkin-Wert gleichen Namens, ist aber ein komplett getrenntes
-- Feld (Mensa Neuwerk ≠ Bibliothek Neuwerk) — nur ein Namens-Zufall.
CREATE OR REPLACE FUNCTION public.get_mensa_checkins()
RETURNS TABLE (name text, avatar_url text, mensa text)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT p.username, p.avatar_url, p.mensa_checkin
  FROM profiles p
  WHERE p.public = true
    AND p.clan_id = my_clan_id()
    AND p.mensa_checkin IS NOT NULL
    AND p.mensa_checkin_date = ((now() AT TIME ZONE 'Europe/Berlin') - interval '4 hours')::date;
$$;

GRANT EXECUTE ON FUNCTION public.get_mensa_checkins() TO anon, authenticated, service_role;
