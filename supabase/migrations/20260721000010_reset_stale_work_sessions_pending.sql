-- reset_stale_work_sessions(): zweiter unabhängiger Auslöser (Idle) zusätzlich
-- zum bestehenden Boundary-Auslöser. Für Limitless-Sessions geht die
-- Kreditierung jetzt in pending_focus_sessions statt direkt in
-- study_days/pomodoro_sessions — der Nutzer muss eine vergessene Session
-- aktiv bestätigen ("Gutschreiben") statt dass sie still durchläuft. Siehe
-- CLAUDE.md, "Vergessene Limitless-Timer".
--
-- Boundary (unverändert in seiner eigenen Logik): 4-Uhr-Berlin-Grenze seit
-- pomoday überschritten. Gilt weiterhin für Countdown UND Limitless.
-- Idle (neu, nur Limitless): eine Session lief seit ihrem letzten manuellen
-- Play-Klick (unbroken_since) mehr als 3h10min ohne Unterbrechung — der
-- 10-Minuten-Puffer gibt dem Client (3h-Schwelle + 2min Bestätigungsfenster)
-- garantiert Vorrang; der Cron greift nur, wenn der Tab wirklich nicht mehr
-- reagiert hat.
--
-- Nur Limitless-Kredite gehen in pending_focus_sessions: eine Limitless-
-- Session kann unbemerkt beliebig lange weiterlaufen (das eigentliche
-- Fairness-Problem dieses Features), ein Countdown ist dagegen durch seine
-- feste, selbst gewählte Dauer von sich aus begrenzt — dessen Boundary-Fall
-- bleibt daher wie vor diesem Feature eine direkte Gutschrift.
--
-- Minuten werden in beiden Fällen an v_cap := LEAST(now(), v_boundary)
-- gedeckelt (im Idle-Fall ist v_boundary typischerweise noch nicht erreicht,
-- v_cap ist dann einfach now() — im Boundary-Fall ist v_cap = v_boundary,
-- identisch zum bisherigen Verhalten).

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
  v_cap timestamptz;
  v_session_start timestamptz;
  v_elapsed_sec numeric;
  v_credit_min integer;
  v_trigger_boundary boolean;
  v_trigger_idle boolean;
  v_reason text;
BEGIN
  FOR r IN
    SELECT * FROM timer_state
    WHERE mode = 'work' AND pomoday IS NOT NULL
      AND (end_at IS NOT NULL OR started_at IS NOT NULL OR paused_remaining IS NOT NULL)
  LOOP
    -- 4:00 Berlin am Tag nach pomoday, DST-sicher via AT TIME ZONE
    v_boundary := (r.pomoday + 1) + time '04:00' AT TIME ZONE 'Europe/Berlin';
    v_trigger_boundary := now() >= v_boundary;

    IF v_trigger_boundary AND NOT r.limitless AND r.end_at IS NOT NULL AND r.end_at <= v_boundary THEN
      CONTINUE; -- wäre vor 4 Uhr regulär fertig geworden, nicht unser Fall
    END IF;

    v_trigger_idle := r.limitless AND r.started_at IS NOT NULL AND r.unbroken_since IS NOT NULL
                       AND now() >= r.unbroken_since + interval '3h10min';

    IF NOT v_trigger_boundary AND NOT v_trigger_idle THEN CONTINUE; END IF;
    v_reason := CASE WHEN v_trigger_boundary THEN 'day_boundary' ELSE 'idle_3h' END;

    -- Claim-Mutex: nur weiterrechnen, wenn DIESER Aufruf die Zeile wirklich
    -- noch löscht — sonst hat der Client (oder ein paralleler Cron-Lauf)
    -- sie bereits beansprucht.
    DELETE FROM timer_state WHERE user_id = r.user_id
    RETURNING * INTO v_deleted;
    IF NOT FOUND THEN CONTINUE; END IF;

    v_cap := LEAST(now(), v_boundary);

    IF v_deleted.limitless THEN
      IF v_deleted.started_at IS NOT NULL THEN
        v_elapsed_sec := extract(epoch FROM (v_cap - v_deleted.started_at));
        v_credit_min := greatest(0, floor(v_elapsed_sec / 60)::int - coalesce(v_deleted.credited_min, 0));
      ELSE
        -- pausierte Stoppuhr: paused_remaining hält bereits verstrichene Sekunden
        v_credit_min := greatest(0, floor(coalesce(v_deleted.paused_remaining, 0) / 60)::int - coalesce(v_deleted.credited_min, 0));
      END IF;
    ELSE
      IF v_deleted.end_at IS NOT NULL THEN
        v_session_start := v_deleted.end_at - make_interval(secs => v_deleted.total_sec);
        v_elapsed_sec := extract(epoch FROM (v_cap - v_session_start));
        v_credit_min := floor(least(v_elapsed_sec, v_deleted.total_sec) / 60)::int;
      ELSE
        -- pausierter Countdown
        v_credit_min := floor((v_deleted.total_sec - coalesce(v_deleted.paused_remaining, 0)) / 60)::int;
      END IF;
    END IF;

    IF v_credit_min > 0 THEN
      IF v_deleted.limitless THEN
        INSERT INTO pending_focus_sessions (user_id, date, minutes, label, reason)
        VALUES (r.user_id, r.pomoday, v_credit_min, 'not specified', v_reason);
      ELSE
        INSERT INTO study_days (user_id, date, minutes)
        VALUES (r.user_id, r.pomoday, v_credit_min)
        ON CONFLICT (user_id, date) DO UPDATE SET minutes = study_days.minutes + v_credit_min;

        INSERT INTO pomodoro_sessions (user_id, date, label, duration_minutes)
        VALUES (r.user_id, r.pomoday, 'not specified', v_credit_min);
      END IF;
    END IF;
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION public.reset_stale_work_sessions() FROM PUBLIC;
