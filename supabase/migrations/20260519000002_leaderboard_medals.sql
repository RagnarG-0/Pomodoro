-- Medaillenspiegel: Gold/Silber/Bronze-Zählung pro Nutzer seit 04.05.2026
-- Rang je Tag per DENSE_RANK → Gleichstand = gleiche Medaillenfarbe für alle.
-- Ersetzt leaderboard_wins() (anderes Return-Schema).

DROP FUNCTION IF EXISTS public.leaderboard_wins();

CREATE OR REPLACE FUNCTION public.leaderboard_wins()
RETURNS TABLE (
  name            text,
  gold            int,
  silver          int,
  bronze          int,
  total           int,
  alltime_minutes bigint,
  avatar_url      text
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  WITH ref AS (
    SELECT
      '2026-05-04'::date AS start_date,
      ((now() AT TIME ZONE 'Europe/Berlin') - interval '4 hours')::date AS today
  ),
  daily_ranks AS (
    SELECT
      sd.user_id,
      DENSE_RANK() OVER (PARTITION BY sd.date ORDER BY sd.minutes DESC) AS day_rank
    FROM study_days sd
    JOIN profiles p ON p.id = sd.user_id
    CROSS JOIN ref
    WHERE sd.date   >= ref.start_date
      AND sd.date    < ref.today
      AND sd.minutes > 0
      AND p.public   = true
      AND p.clan_id  = my_clan_id()
  ),
  medals AS (
    SELECT
      user_id,
      COUNT(*) FILTER (WHERE day_rank = 1)::int AS gold,
      COUNT(*) FILTER (WHERE day_rank = 2)::int AS silver,
      COUNT(*) FILTER (WHERE day_rank = 3)::int AS bronze
    FROM daily_ranks
    GROUP BY user_id
  )
  SELECT
    p.username                                                              AS name,
    m.gold,
    m.silver,
    m.bronze,
    (m.gold + m.silver + m.bronze)::int                                    AS total,
    COALESCE((
      SELECT SUM(sd2.minutes) FROM study_days sd2 WHERE sd2.user_id = p.id
    ), 0)::bigint                                                           AS alltime_minutes,
    p.avatar_url
  FROM medals m
  JOIN profiles p ON p.id = m.user_id
  WHERE m.gold + m.silver + m.bronze > 0
  ORDER BY m.gold DESC, m.silver DESC, m.bronze DESC, alltime_minutes DESC;
$$;

GRANT EXECUTE ON FUNCTION public.leaderboard_wins() TO anon, authenticated, service_role;
