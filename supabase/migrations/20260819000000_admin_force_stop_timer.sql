-- Admin: laufende/pausierte Timer fremder Nutzer einsehen und zwangsbeenden
-- (primär für vergessene Endless-Sessions anderer Accounts). Rein additiv,
-- kein neuer Ansatz für die Timer-Speicherung nötig — timer_state enthält
-- bereits alles (started_at/end_at/paused_remaining/mode/limitless/
-- credited_min/pomoday), um serverseitig zu berechnen, wie viel Zeit fällig
-- ist. reset_stale_work_sessions() macht das schon automatisch; hier wird
-- dieselbe Kreditierungs-Logik in eine Helper-Funktion extrahiert und
-- zusätzlich manuell/gezielt über eine neue Admin-RPC nutzbar gemacht.
--
-- Admin-Konzept ist bewusst minimal: ein einzelnes profiles.is_admin-Flag,
-- kein allgemeines Rollensystem. Betrifft ausschließlich den App-Betreiber
-- selbst. Siehe CLAUDE.md, Abschnitt "Admin".

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS is_admin boolean NOT NULL DEFAULT false;

-- Dritter Reason-Wert für admin-initiiertes Zwangsbeenden fremder Limitless-
-- Sessions. Gleiche Kreditierungs-Semantik wie idle_3h/day_boundary: landet
-- in pending_focus_sessions, der betroffene Nutzer bestätigt ("Gutschreiben")
-- oder verwirft ("Löschen") selbst über die bestehende Pending-Liste-UI —
-- kein stiller Fremd-Credit durch den Admin.
ALTER TABLE public.pending_focus_sessions
  DROP CONSTRAINT IF EXISTS pending_focus_sessions_reason_check;
ALTER TABLE public.pending_focus_sessions
  ADD CONSTRAINT pending_focus_sessions_reason_check
  CHECK (reason IN ('idle_3h', 'day_boundary', 'admin_stop'));

-- Gemeinsamer Kern für "beende diese timer_state-Zeile jetzt, wie viele
-- Minuten sind fällig, wohin geht die Gutschrift" — extrahiert aus
-- reset_stale_work_sessions() (dessen Verhalten unverändert bleibt), jetzt
-- zusätzlich von admin_force_stop_timer() genutzt. Erwartet eine BEREITS per
-- Claim-Mutex (DELETE ... RETURNING) entfernte timer_state-Zeile; berechnet
-- nichts selbst am aktuellen DB-Zustand.
CREATE OR REPLACE FUNCTION public.credit_elapsed_timer_state(
  p_row    public.timer_state,
  p_cutoff timestamptz,
  p_reason text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_session_start timestamptz;
  v_elapsed_sec   numeric;
  v_credit_min    integer;
BEGIN
  IF p_row.pomoday IS NULL THEN RETURN; END IF;

  IF p_row.limitless THEN
    IF p_row.started_at IS NOT NULL THEN
      v_elapsed_sec := extract(epoch FROM (p_cutoff - p_row.started_at));
      v_credit_min := greatest(0, floor(v_elapsed_sec / 60)::int - coalesce(p_row.credited_min, 0));
    ELSE
      -- pausierte Stoppuhr: paused_remaining hält bereits verstrichene Sekunden
      v_credit_min := greatest(0, floor(coalesce(p_row.paused_remaining, 0) / 60)::int - coalesce(p_row.credited_min, 0));
    END IF;
  ELSE
    IF p_row.end_at IS NOT NULL THEN
      v_session_start := p_row.end_at - make_interval(secs => p_row.total_sec);
      v_elapsed_sec := extract(epoch FROM (p_cutoff - v_session_start));
      v_credit_min := floor(least(v_elapsed_sec, p_row.total_sec) / 60)::int;
    ELSE
      -- pausierter Countdown
      v_credit_min := floor((p_row.total_sec - coalesce(p_row.paused_remaining, 0)) / 60)::int;
    END IF;
  END IF;

  IF v_credit_min > 0 THEN
    IF p_row.limitless THEN
      INSERT INTO pending_focus_sessions (user_id, date, minutes, label, reason)
      VALUES (p_row.user_id, p_row.pomoday, v_credit_min, 'not specified', p_reason);
    ELSE
      INSERT INTO study_days (user_id, date, minutes)
      VALUES (p_row.user_id, p_row.pomoday, v_credit_min)
      ON CONFLICT (user_id, date) DO UPDATE SET minutes = study_days.minutes + v_credit_min;

      INSERT INTO pomodoro_sessions (user_id, date, label, duration_minutes)
      VALUES (p_row.user_id, p_row.pomoday, 'not specified', v_credit_min);
    END IF;
  END IF;
END;
$$;

-- Nur intern von SECURITY DEFINER-Funktionen genutzt, kein direkter
-- Client-Zugriff nötig (analog reset_stale_work_sessions()).
REVOKE ALL ON FUNCTION public.credit_elapsed_timer_state(public.timer_state, timestamptz, text) FROM PUBLIC;

-- reset_stale_work_sessions(): Signatur/Rückgabetyp unverändert (kein
-- DROP FUNCTION nötig, anders als bei draw_card()/leaderboard_today(), deren
-- RETURNS TABLE-Spaltenliste sich änderte) — Body ruft die Branch-Logik jetzt
-- über den neuen gemeinsamen Helper statt sie auszuschreiben. Verhalten
-- identisch zur Vorversion (20260721000010).
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
    PERFORM public.credit_elapsed_timer_state(v_deleted, v_cap, v_reason);
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION public.reset_stale_work_sessions() FROM PUBLIC;

-- Admin-Panel: eigene, offene Timer-Zeilen anderer Nutzer sichten. Rein
-- lesend und nicht sicherheitskritisch, falls versehentlich von einem
-- Nicht-Admin aufgerufen — liefert dann still ein leeres Resultset statt
-- eines Fehlers (WHERE-Klausel statt RAISE EXCEPTION).
CREATE OR REPLACE FUNCTION public.admin_list_running_timers()
RETURNS TABLE (
  user_id          uuid,
  username         text,
  mode             text,
  limitless        boolean,
  started_at       timestamptz,
  end_at           timestamptz,
  total_sec        integer,
  paused_remaining integer,
  credited_min     integer,
  pomoday          date,
  updated_at       timestamptz
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT ts.user_id, p.username, ts.mode, ts.limitless, ts.started_at, ts.end_at,
         ts.total_sec, ts.paused_remaining, ts.credited_min, ts.pomoday, ts.updated_at
  FROM timer_state ts
  JOIN profiles p ON p.id = ts.user_id
  WHERE ts.mode IN ('work', 'short')
    AND EXISTS (SELECT 1 FROM profiles me WHERE me.id = auth.uid() AND me.is_admin = true)
  ORDER BY ts.started_at NULLS LAST, ts.updated_at DESC;
$$;

REVOKE EXECUTE ON FUNCTION public.admin_list_running_timers() FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_list_running_timers() TO authenticated, service_role;
-- REVOKE FROM anon ist in diesem Projekt bekanntlich wirkungslos (PUBLIC-
-- Default-Grant, siehe CLAUDE.md, "Rennstrecke") — funktional unkritisch:
-- auth.uid() ist für anon NULL, der EXISTS-Check matcht dann nie eine
-- is_admin-Zeile, das Resultset bleibt leer.

-- Admin-Panel: fremden Timer zwangsbeenden. Claim-Mutex wie überall sonst in
-- dieser Codebase (nur wer wirklich löscht, kreditiert). 'short' (Pause)
-- braucht keine Gutschrift, nur 'work' wird kreditiert.
CREATE OR REPLACE FUNCTION public.admin_force_stop_timer(p_user_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_deleted timer_state%ROWTYPE;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND is_admin = true) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  DELETE FROM timer_state WHERE user_id = p_user_id AND mode IN ('work', 'short')
  RETURNING * INTO v_deleted;
  IF NOT FOUND THEN RETURN false; END IF;

  IF v_deleted.mode = 'work' THEN
    PERFORM public.credit_elapsed_timer_state(v_deleted, now(), 'admin_stop');
  END IF;

  RETURN true;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.admin_force_stop_timer(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_force_stop_timer(uuid) TO authenticated, service_role;
