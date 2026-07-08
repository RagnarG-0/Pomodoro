-- Fix: reset_stale_work_sessions() konnte eine Session doppelt kreditieren.
--
-- Der Cron las die timer_state-Zeile, kreditierte die berechnete Zeit und
-- löschte die Zeile erst danach — ohne zu prüfen, ob der Client
-- (checkDayRollover(), index.html) dieselbe Zeile zwischenzeitlich bereits
-- selbst per clearTimerState() beansprucht (gelöscht) und kreditiert hatte.
-- Lief eine über Nacht laufende Session in genau diesem 5-Minuten-Fenster
-- sowohl dem Client als auch dem Cron über den Weg, wurde die Restzeit
-- doppelt auf study_days gebucht — sichtbar u.a. als überzählige
-- Goldmedaillen in leaderboard_wins() (live aus study_days berechnet).
--
-- Fix: DELETE zuerst (Claim-Mutex, wie beim Client) — nur wenn die Zeile
-- durch DIESEN Aufruf wirklich noch gelöscht wird, wird mit den frisch
-- gelöschten (aktuellen) Werten kreditiert. Die Boundary-Prüfungen (ob
-- die Grenze schon erreicht ist, ob ein Countdown vor 4 Uhr regulär
-- fertig geworden wäre) laufen weiterhin auf dem ursprünglichen Read —
-- Staleness dort ist unkritisch und heilt sich beim nächsten 5-Minuten-Lauf
-- selbst aus, ohne Daten zu verlieren.

CREATE OR REPLACE FUNCTION public.reset_stale_work_sessions()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  r record;
  v_deleted timer_state%ROWTYPE;
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
    IF NOT r.limitless AND r.end_at IS NOT NULL AND r.end_at <= v_boundary THEN
      CONTINUE; -- wäre vor 4 Uhr regulär fertig geworden, nicht unser Fall
    END IF;

    -- Claim-Mutex: nur weiterrechnen, wenn DIESER Aufruf die Zeile wirklich
    -- noch löscht — sonst hat der Client (oder ein paralleler Cron-Lauf)
    -- sie bereits beansprucht und kreditiert.
    DELETE FROM timer_state WHERE user_id = r.user_id
    RETURNING * INTO v_deleted;
    IF NOT FOUND THEN CONTINUE; END IF;

    IF v_deleted.limitless THEN
      IF v_deleted.started_at IS NOT NULL THEN
        v_elapsed_sec := extract(epoch FROM (v_boundary - v_deleted.started_at));
        v_credit_min := greatest(0, floor(v_elapsed_sec / 60)::int - coalesce(v_deleted.credited_min, 0));
      ELSE
        -- pausierte Stoppuhr: paused_remaining hält bereits verstrichene Sekunden
        v_credit_min := greatest(0, floor(coalesce(v_deleted.paused_remaining, 0) / 60)::int - coalesce(v_deleted.credited_min, 0));
      END IF;
    ELSE
      IF v_deleted.end_at IS NOT NULL THEN
        v_session_start := v_deleted.end_at - make_interval(secs => v_deleted.total_sec);
        v_elapsed_sec := extract(epoch FROM (v_boundary - v_session_start));
        v_credit_min := floor(least(v_elapsed_sec, v_deleted.total_sec) / 60)::int;
      ELSE
        -- pausierter Countdown
        v_credit_min := floor((v_deleted.total_sec - coalesce(v_deleted.paused_remaining, 0)) / 60)::int;
      END IF;
    END IF;

    IF v_credit_min > 0 THEN
      INSERT INTO study_days (user_id, date, minutes)
      VALUES (r.user_id, r.pomoday, v_credit_min)
      ON CONFLICT (user_id, date) DO UPDATE SET minutes = study_days.minutes + v_credit_min;

      INSERT INTO pomodoro_sessions (user_id, date, label, duration_minutes)
      VALUES (r.user_id, r.pomoday, 'not specified', v_credit_min);
    END IF;
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION public.reset_stale_work_sessions() FROM PUBLIC;
