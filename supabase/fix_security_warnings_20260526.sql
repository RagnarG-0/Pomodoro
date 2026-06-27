-- Security-Fixes für Supabase-Warnungen
-- Ausführen im Supabase SQL Editor
-- 2026-05-26


-- ═══════════════════════════════════════════════════════════════
-- 1. FUNCTION SEARCH_PATH — fehlende SET search_path ergänzen
-- ═══════════════════════════════════════════════════════════════

-- log_study_days_change: Trigger-Funktion, hatte kein SET search_path
CREATE OR REPLACE FUNCTION public.log_study_days_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  uname text;
BEGIN
  SELECT username INTO uname FROM profiles WHERE id = NEW.user_id;

  IF TG_OP = 'INSERT' THEN
    INSERT INTO study_days_log (user_id, username, date, minutes_before, minutes_after, minutes_delta, action)
    VALUES (NEW.user_id, uname, NEW.date, 0, NEW.minutes, NEW.minutes, 'insert');
  ELSIF TG_OP = 'UPDATE' THEN
    INSERT INTO study_days_log (user_id, username, date, minutes_before, minutes_after, minutes_delta, action)
    VALUES (NEW.user_id, uname, NEW.date, OLD.minutes, NEW.minutes, NEW.minutes - OLD.minutes, 'update');
  END IF;

  DELETE FROM study_days_log WHERE logged_at < now() - interval '48 hours';

  RETURN NEW;
END;
$$;

-- add_study_minutes: DB-Version hatte kein SET search_path
CREATE OR REPLACE FUNCTION public.add_study_minutes(p_date date, p_minutes int)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  INSERT INTO study_days (user_id, date, minutes)
  VALUES (auth.uid(), p_date, p_minutes)
  ON CONFLICT (user_id, date) DO UPDATE
    SET minutes = study_days.minutes + EXCLUDED.minutes;
$$;

-- create_clan: DB-Version hatte kein SET search_path
CREATE OR REPLACE FUNCTION public.create_clan(p_name text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_clan_id uuid;
BEGIN
  IF EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND clan_id IS NOT NULL) THEN
    RAISE EXCEPTION 'already_in_clan';
  END IF;
  INSERT INTO clans (name, leader_id) VALUES (p_name, auth.uid()) RETURNING id INTO v_clan_id;
  UPDATE profiles SET clan_id = v_clan_id, clan_role = 'leader' WHERE id = auth.uid();
  RETURN v_clan_id;
END;
$$;

-- get_label_stats: DB-Version hatte kein SET search_path
CREATE OR REPLACE FUNCTION public.get_label_stats(p_user_id uuid)
RETURNS TABLE(
  label           text,
  today_minutes   bigint,
  week_minutes    bigint,
  month_minutes   bigint,
  alltime_minutes bigint
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    ps.label,
    COALESCE(SUM(CASE WHEN ps.date = CURRENT_DATE
                      THEN ps.duration_minutes ELSE 0 END), 0)::bigint AS today_minutes,
    COALESCE(SUM(CASE WHEN ps.date >= CURRENT_DATE - 6
                      THEN ps.duration_minutes ELSE 0 END), 0)::bigint AS week_minutes,
    COALESCE(SUM(CASE WHEN ps.date >= date_trunc('month', CURRENT_DATE)::date
                      THEN ps.duration_minutes ELSE 0 END), 0)::bigint AS month_minutes,
    COALESCE(SUM(ps.duration_minutes), 0)::bigint                      AS alltime_minutes
  FROM pomodoro_sessions ps
  WHERE ps.user_id = p_user_id
  GROUP BY ps.label
  ORDER BY alltime_minutes DESC;
$$;

-- submit_join_request_to: DB-Version hatte kein SET search_path
CREATE OR REPLACE FUNCTION public.submit_join_request_to(p_clan_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND clan_id IS NOT NULL) THEN
    RAISE EXCEPTION 'already_in_clan';
  END IF;
  IF EXISTS (
    SELECT 1 FROM clan_requests
    WHERE user_id = auth.uid() AND clan_id = p_clan_id AND status = 'pending'
  ) THEN RETURN; END IF;
  INSERT INTO clan_requests (clan_id, user_id, status) VALUES (p_clan_id, auth.uid(), 'pending');
END;
$$;


-- ═══════════════════════════════════════════════════════════════
-- 2. REVOKE EXECUTE FROM anon — Auth-pflichtige Funktionen
-- ═══════════════════════════════════════════════════════════════

REVOKE EXECUTE ON FUNCTION public.add_study_minutes(date, integer)            FROM anon;
REVOKE EXECUTE ON FUNCTION public.create_clan(text)                           FROM anon;
REVOKE EXECUTE ON FUNCTION public.draw_card()                                 FROM anon;
REVOKE EXECUTE ON FUNCTION public.get_clan_members()                          FROM anon;
REVOKE EXECUTE ON FUNCTION public.get_label_stats(uuid)                       FROM anon;
REVOKE EXECUTE ON FUNCTION public.log_study_days_change()                     FROM anon;
REVOKE EXECUTE ON FUNCTION public.my_clan_id()                                FROM anon;
REVOKE EXECUTE ON FUNCTION public.remove_clan_member(uuid)                    FROM anon;
REVOKE EXECUTE ON FUNCTION public.respond_to_clan_request(uuid, boolean)      FROM anon;
REVOKE EXECUTE ON FUNCTION public.submit_join_request()                       FROM anon;
REVOKE EXECUTE ON FUNCTION public.submit_join_request_to(uuid)                FROM anon;


-- ═══════════════════════════════════════════════════════════════
-- 3. RLS — daily_winners INSERT auf service_role einschränken
-- ═══════════════════════════════════════════════════════════════

DROP POLICY IF EXISTS "Service kann schreiben" ON public.daily_winners;
CREATE POLICY "Service kann schreiben" ON public.daily_winners
  FOR INSERT TO service_role WITH CHECK (true);


-- ═══════════════════════════════════════════════════════════════
-- 4. Veraltete leaderboard-Tabelle entfernen
--    (App nutzt ausschließlich leaderboard_today() / leaderboard_aggregated() RPCs)
-- ═══════════════════════════════════════════════════════════════

DROP TABLE IF EXISTS public.leaderboard CASCADE;


-- ═══════════════════════════════════════════════════════════════
-- 5. HINWEIS: Leaked Password Protection
--    Nur im Dashboard aktivierbar:
--    Authentication → Providers → Email → "Check for leaked passwords"
-- ═══════════════════════════════════════════════════════════════
