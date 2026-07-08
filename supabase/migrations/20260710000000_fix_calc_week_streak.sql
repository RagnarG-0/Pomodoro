-- Fix: calc_week_streak() ließ v_off_override/v_minutes bei Tagen ohne
-- study_days-Zeile auf dem Wert der vorherigen Schleifen-Iteration stehen
-- (PL/pgSQL SELECT INTO setzt Variablen bei 0 Treffern NICHT auf NULL zurück).
-- Dadurch konnte ein Tag ohne Eintrag fälschlich den Off-Status/die Minuten
-- des Vortages übernehmen und eine an sich gültige Streak-Challenge mit
-- threshold_not_met ablehnen.

CREATE OR REPLACE FUNCTION public.calc_week_streak(p_week_start date, p_user_id uuid)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_today        date;
  v_scan_start   date;
  v_day          date;
  v_off_weekdays integer[];
  v_streak       int := 0;
  v_is_off       boolean;
  v_off_override boolean;
  v_minutes      int;
BEGIN
  v_today := ((now() AT TIME ZONE 'Europe/Berlin') - interval '4 hours')::date;
  v_scan_start := LEAST(v_today, p_week_start + 6);

  SELECT off_weekdays INTO v_off_weekdays FROM profiles WHERE id = p_user_id;
  v_off_weekdays := COALESCE(v_off_weekdays, '{}');

  v_day := v_scan_start;
  WHILE v_day >= p_week_start LOOP
    v_off_override := NULL;
    v_minutes := NULL;
    SELECT off, minutes INTO v_off_override, v_minutes
    FROM study_days WHERE user_id = p_user_id AND date = v_day;

    IF v_off_override IS TRUE THEN
      v_is_off := true;
    ELSIF v_off_override IS FALSE THEN
      v_is_off := false;
    ELSE
      -- isodow (1=Mo..7=So) % 7 -> JS getDay() (0=So..6=Sa), da offWeekdays so gespeichert ist
      v_is_off := (extract(isodow FROM v_day)::int % 7) = ANY(v_off_weekdays);
    END IF;

    IF NOT v_is_off THEN
      IF COALESCE(v_minutes, 0) > 0 THEN
        v_streak := v_streak + 1;
      ELSIF v_day = v_today THEN
        NULL; -- heute noch leer, aber Tag ist noch nicht vorbei -> nicht abbrechen
      ELSE
        EXIT;
      END IF;
    END IF;

    v_day := v_day - 1;
  END LOOP;

  RETURN v_streak;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.calc_week_streak(date, uuid) FROM anon;
