-- Design-Entscheidung: freie Tage retten den Streak nicht mehr. Bisher
-- übersprang calc_week_streak() (wie computeCurrentStreak()/computeWeekStreak()
-- im Client) als "frei" markierte Tage komplett — ein Nutzer konnte also
-- rückwirkend einen 0-Minuten-Tag als frei markieren, um seinen Streak bzw.
-- eine laufende Streak-Challenge zu retten. Off-Tage sollen sich nur auf die
-- eigene Statistik auswirken (Wochendurchschnitt, rein client-seitig in
-- renderStats()), überall sonst — inkl. Streaks — zählen sie wie ganz
-- normale Tage. Diese Funktion prüft daher nur noch die Minuten, keinen
-- Off-Status mehr.

CREATE OR REPLACE FUNCTION public.calc_week_streak(p_week_start date, p_user_id uuid)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_today      date;
  v_scan_start date;
  v_day        date;
  v_streak     int := 0;
  v_minutes    int;
BEGIN
  v_today := ((now() AT TIME ZONE 'Europe/Berlin') - interval '4 hours')::date;
  v_scan_start := LEAST(v_today, p_week_start + 6);

  v_day := v_scan_start;
  WHILE v_day >= p_week_start LOOP
    v_minutes := NULL;
    SELECT minutes INTO v_minutes FROM study_days WHERE user_id = p_user_id AND date = v_day;

    IF COALESCE(v_minutes, 0) > 0 THEN
      v_streak := v_streak + 1;
    ELSIF v_day = v_today THEN
      NULL; -- heute noch leer, aber Tag ist noch nicht vorbei -> nicht abbrechen
    ELSE
      EXIT;
    END IF;

    v_day := v_day - 1;
  END LOOP;

  RETURN v_streak;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.calc_week_streak(date, uuid) FROM anon;
