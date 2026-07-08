-- Bugfix: der grüne "Fokus läuft"-Punkt im Leaderboard blieb im Limitless-
-- (Stoppuhr-)Modus immer aus. timer_active prüfte bisher nur
-- `end_at IS NOT NULL AND end_at > now()` — eine laufende Limitless-Session
-- setzt aber nie end_at (Countdown-Feld), sondern started_at (siehe
-- 20260707000000_limitless_timer.sql). Diese beiden Leaderboard-RPCs
-- existierten schon vor dem Limitless-Feature und wurden nie nachgezogen.
-- Fix: zusätzlich als aktiv werten, wenn limitless=true und started_at
-- gesetzt ist (started_at ist null während einer Pause, genau wie end_at
-- beim Countdown-Timer — das Pausiert-Verhalten bleibt also unverändert).

CREATE OR REPLACE FUNCTION public.leaderboard_today()
RETURNS TABLE (
  name            text,
  minutes         int,
  alltime_minutes bigint,
  diamonds        int,
  avatar_url      text,
  timer_active    bool
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
    ), false)                                              AS timer_active
  FROM profiles p
  CROSS JOIN today
  JOIN study_days sd_today
    ON sd_today.user_id = p.id AND sd_today.date = today.d AND sd_today.minutes > 0
  WHERE p.public = true
    AND p.clan_id = my_clan_id()
  ORDER BY minutes DESC, alltime_minutes DESC;
$$;

GRANT EXECUTE ON FUNCTION public.leaderboard_today() TO anon, authenticated, service_role;


CREATE OR REPLACE FUNCTION public.leaderboard_aggregated(date_from date)
RETURNS TABLE (
  name            text,
  minutes         bigint,
  alltime_minutes bigint,
  diamonds        int,
  avatar_url      text,
  timer_active    bool
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT
    p.username,
    COALESCE((
      SELECT SUM(sd.minutes) FROM study_days sd
      WHERE sd.user_id = p.id AND sd.date >= date_from
    ), 0)::bigint                                          AS minutes,
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
    ), false)                                              AS timer_active
  FROM profiles p
  WHERE p.public = true
    AND p.clan_id = my_clan_id()
  ORDER BY minutes DESC, alltime_minutes DESC;
$$;

GRANT EXECUTE ON FUNCTION public.leaderboard_aggregated(date) TO anon, authenticated, service_role;
