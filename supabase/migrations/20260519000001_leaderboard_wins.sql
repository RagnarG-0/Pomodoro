-- Rangliste: Tagessiege seit 04.05.2026
-- Ein "Sieg" = meiste Minuten im Clan an einem abgeschlossenen Tag.
-- Bei Gleichstand werden alle Erstplatzierten des Tages gezählt.

CREATE OR REPLACE FUNCTION public.leaderboard_wins()
RETURNS TABLE (
  name            text,
  wins            int,
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
  daily_max AS (
    SELECT sd.date, MAX(sd.minutes) AS max_min
    FROM study_days sd
    JOIN profiles p ON p.id = sd.user_id
    CROSS JOIN ref
    WHERE sd.date  >= ref.start_date
      AND sd.date   < ref.today
      AND sd.minutes > 0
      AND p.public   = true
      AND p.clan_id  = my_clan_id()
    GROUP BY sd.date
  ),
  wins_per_user AS (
    SELECT sd.user_id, COUNT(*)::int AS wins
    FROM study_days sd
    JOIN profiles p  ON p.id  = sd.user_id
    JOIN daily_max dm ON dm.date = sd.date AND dm.max_min = sd.minutes
    CROSS JOIN ref
    WHERE sd.date  >= ref.start_date
      AND sd.date   < ref.today
      AND p.public  = true
      AND p.clan_id = my_clan_id()
    GROUP BY sd.user_id
  )
  SELECT
    p.username                                                              AS name,
    w.wins,
    COALESCE((
      SELECT SUM(sd2.minutes) FROM study_days sd2 WHERE sd2.user_id = p.id
    ), 0)::bigint                                                           AS alltime_minutes,
    p.avatar_url
  FROM wins_per_user w
  JOIN profiles p ON p.id = w.user_id
  ORDER BY w.wins DESC, alltime_minutes DESC;
$$;

GRANT EXECUTE ON FUNCTION public.leaderboard_wins() TO anon, authenticated, service_role;
