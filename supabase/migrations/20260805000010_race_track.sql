-- ═══════════════════════════════════════════════════
-- 1. profiles: race_car_id (1-8), dauerhaft & einmalig zufällig zugewiesen
--    beim Login, idempotent — siehe ensureRaceCarAssigned() im Frontend.
-- ═══════════════════════════════════════════════════
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS race_car_id smallint;
ALTER TABLE public.profiles DROP CONSTRAINT IF EXISTS profiles_race_car_id_check;
ALTER TABLE public.profiles ADD CONSTRAINT profiles_race_car_id_check
  CHECK (race_car_id IS NULL OR race_car_id BETWEEN 1 AND 8);

-- ═══════════════════════════════════════════════════
-- 2. leaderboard_today(): race_car_id ergänzen
-- ═══════════════════════════════════════════════════
-- CREATE OR REPLACE erlaubt keine Änderung der Spaltenliste von RETURNS TABLE
-- ("cannot change return type of existing function") — DROP ist Pflicht,
-- GRANT muss danach neu gesetzt werden (gleiches Muster wie draw_card() in
-- 20260805000000_mystic_egg.sql). Bleibt bei einer parameterlosen Signatur,
-- also kein PGRST203-Risiko.
DROP FUNCTION IF EXISTS public.leaderboard_today();

CREATE OR REPLACE FUNCTION public.leaderboard_today()
RETURNS TABLE (
  name            text,
  minutes         int,
  alltime_minutes bigint,
  diamonds        int,
  avatar_url      text,
  timer_active    bool,
  race_car_id     smallint
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  WITH today AS (
    SELECT ((now() AT TIME ZONE 'Europe/Berlin') - interval '4 hours')::date AS d
  )
  SELECT
    p.username,
    sd_today.minutes                                       AS minutes,
    COALESCE((
      SELECT SUM(sd.minutes) FROM study_days sd WHERE sd.user_id = p.id
    ), 0)::bigint                                          AS alltime_minutes,
    COALESCE(p.diamonds, 0),
    p.avatar_url,
    COALESCE((
      SELECT ts.mode = 'work' AND (
        (ts.end_at IS NOT NULL AND ts.end_at > now())
        OR (ts.limitless AND ts.started_at IS NOT NULL)
      )
      FROM timer_state ts WHERE ts.user_id = p.id LIMIT 1
    ), false)                                              AS timer_active,
    p.race_car_id
  FROM profiles p
  CROSS JOIN today
  JOIN study_days sd_today
    ON sd_today.user_id = p.id AND sd_today.date = today.d AND sd_today.minutes > 0
  WHERE p.public = true
    AND p.clan_id = my_clan_id()
  ORDER BY minutes DESC, alltime_minutes DESC;
$$;

GRANT EXECUTE ON FUNCTION public.leaderboard_today() TO anon, authenticated, service_role;
