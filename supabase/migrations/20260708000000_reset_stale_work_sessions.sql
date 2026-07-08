-- 4-Uhr-Reset für laufende/pausierte Fokus-Sessions (Countdown + Limitless).
-- Kreditiert die bis 4 Uhr Berliner Zeit tatsächlich verstrichene Zeit dem
-- Tag, an dem die Session gestartet wurde (pomoday), und räumt die Zeile.
-- Läuft alle 5 Minuten (idempotent, grenzwertbasiert statt zeitpunktbasiert
-- geprüft) und ist damit unabhängig von Cron-Jitter/DST korrekt.
CREATE OR REPLACE FUNCTION public.reset_stale_work_sessions()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  r record;
  v_boundary timestamptz;
  v_session_start timestamptz;
  v_elapsed_sec numeric;
  v_credit_min integer;
BEGIN
  FOR r IN
    SELECT * FROM timer_state
    WHERE mode = 'work' AND pomoday IS NOT NULL
      AND (end_at IS NOT NULL OR started_at IS NOT NULL OR paused_remaining IS NOT NULL)
  LOOP
    -- 4:00 Berlin am Tag nach pomoday, DST-sicher via AT TIME ZONE
    v_boundary := (r.pomoday + 1) + time '04:00' AT TIME ZONE 'Europe/Berlin';
    IF now() < v_boundary THEN CONTINUE; END IF;

    IF r.limitless THEN
      IF r.started_at IS NOT NULL THEN
        v_elapsed_sec := extract(epoch FROM (v_boundary - r.started_at));
        v_credit_min := greatest(0, floor(v_elapsed_sec / 60)::int - coalesce(r.credited_min, 0));
      ELSE
        -- pausierte Stoppuhr: paused_remaining hält bereits verstrichene Sekunden
        v_credit_min := greatest(0, floor(coalesce(r.paused_remaining, 0) / 60)::int - coalesce(r.credited_min, 0));
      END IF;
    ELSE
      IF r.end_at IS NOT NULL THEN
        IF r.end_at <= v_boundary THEN CONTINUE; END IF; -- wäre vor 4 Uhr regulär fertig geworden, nicht unser Fall
        v_session_start := r.end_at - make_interval(secs => r.total_sec);
        v_elapsed_sec := extract(epoch FROM (v_boundary - v_session_start));
        v_credit_min := floor(least(v_elapsed_sec, r.total_sec) / 60)::int;
      ELSE
        -- pausierter Countdown
        v_credit_min := floor((r.total_sec - coalesce(r.paused_remaining, 0)) / 60)::int;
      END IF;
    END IF;

    IF v_credit_min > 0 THEN
      INSERT INTO study_days (user_id, date, minutes)
      VALUES (r.user_id, r.pomoday, v_credit_min)
      ON CONFLICT (user_id, date) DO UPDATE SET minutes = study_days.minutes + v_credit_min;

      INSERT INTO pomodoro_sessions (user_id, date, label, duration_minutes)
      VALUES (r.user_id, r.pomoday, 'not specified', v_credit_min);
    END IF;

    DELETE FROM timer_state WHERE user_id = r.user_id;
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION public.reset_stale_work_sessions() FROM PUBLIC;

SELECT cron.schedule('reset-stale-work-sessions', '*/5 * * * *',
  $$ SELECT public.reset_stale_work_sessions(); $$);
