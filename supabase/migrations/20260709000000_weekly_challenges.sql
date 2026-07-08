-- Wöchentliche Challenges: 3 Schwierigkeitsstufen (Leicht/Mittel/Schwer),
-- je 3 aktive Challenges pro Woche aus einem 6er-Pool je Stufe, deterministisch
-- rotierend (kein Zufall, keine "diese Woche aktiv"-Speicherung nötig).
-- Fortschritt wird ausschließlich serverseitig aus study_days berechnet,
-- Claims sind manuell (Button) und serverseitig verifiziert.

-- ═══════════════════════════════════════════════════
-- 1. TABELLEN
-- ═══════════════════════════════════════════════════

CREATE TABLE public.weekly_challenges (
  challenge_key    text PRIMARY KEY,
  tier             text NOT NULL CHECK (tier IN ('leicht','mittel','schwer')),
  metric_type      text NOT NULL CHECK (metric_type IN ('total_minutes','streak_days','count_days_threshold','weekend_minutes')),
  param_n          int  NOT NULL CHECK (param_n > 0),
  param_h          int  CHECK (param_h IS NULL OR param_h > 0), -- nur für count_days_threshold
  reward_diamonds  int  NOT NULL CHECK (reward_diamonds > 0),
  pool_index       int  NOT NULL CHECK (pool_index >= 0),       -- feste Position, NIE umsortieren
  label            text NOT NULL,
  active           boolean NOT NULL DEFAULT true,
  UNIQUE (tier, pool_index)
);

CREATE TABLE public.weekly_challenge_claims (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id          uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  week_start       date NOT NULL,
  challenge_key    text NOT NULL REFERENCES public.weekly_challenges(challenge_key),
  reward_diamonds  int  NOT NULL, -- Snapshot zum Claim-Zeitpunkt
  claimed_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, week_start, challenge_key)
);

ALTER TABLE public.weekly_challenges       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.weekly_challenge_claims ENABLE ROW LEVEL SECURITY;

-- weekly_challenges: öffentlicher Katalog, jeder darf lesen (wie cards)
CREATE POLICY "weekly_challenges_select_all" ON public.weekly_challenges
  FOR SELECT USING (true);

-- weekly_challenge_claims: Nutzer sieht nur eigene Claims
-- (INSERT erfolgt ausschließlich via claim_weekly_challenge() SECURITY DEFINER)
CREATE POLICY "weekly_challenge_claims_select_own" ON public.weekly_challenge_claims
  FOR SELECT USING (auth.uid() = user_id);

GRANT ALL ON TABLE public.weekly_challenges       TO anon, authenticated, service_role;
GRANT ALL ON TABLE public.weekly_challenge_claims TO anon, authenticated, service_role;


-- ═══════════════════════════════════════════════════
-- 2. POOL-SEED (6 je Stufe, pool_index = Rotations-Position)
-- ═══════════════════════════════════════════════════

INSERT INTO public.weekly_challenges (challenge_key, tier, metric_type, param_n, param_h, reward_diamonds, pool_index, label) VALUES
  ('leicht_10pomos',   'leicht', 'total_minutes',         250, NULL, 1, 0, '10 Pomodoros diese Woche'),
  ('leicht_streak3',   'leicht', 'streak_days',             3, NULL, 1, 1, '3 Tage Streak'),
  ('leicht_5h',        'leicht', 'total_minutes',         300, NULL, 1, 2, '5 Stunden Fokuszeit'),
  ('leicht_8pomos',    'leicht', 'total_minutes',         200, NULL, 1, 3, '8 Pomodoros diese Woche'),
  ('leicht_2d2h',      'leicht', 'count_days_threshold',    2,  120, 1, 4, 'An 2 Tagen je 2 Stunden fokussieren'),
  ('leicht_streak2',   'leicht', 'streak_days',             2, NULL, 1, 5, '2 Tage Streak'),

  ('mittel_20h',       'mittel', 'total_minutes',        1200, NULL, 3, 0, '20 Stunden Fokuszeit'),
  ('mittel_streak5',   'mittel', 'streak_days',             5, NULL, 3, 1, '5 Tage Streak'),
  ('mittel_3d3h',      'mittel', 'count_days_threshold',    3,  180, 3, 2, 'An 3 Tagen je 3 Stunden fokussieren'),
  ('mittel_15h',       'mittel', 'total_minutes',         900, NULL, 3, 3, '15 Stunden Fokuszeit'),
  ('mittel_streak4',   'mittel', 'streak_days',             4, NULL, 3, 4, '4 Tage Streak'),
  ('mittel_weekend6h', 'mittel', 'weekend_minutes',       360, NULL, 3, 5, '6 Stunden am Wochenende'),

  ('schwer_3d6h',        'schwer', 'count_days_threshold',  3,  360, 5, 0, 'An 3 Tagen je 6 Stunden fokussieren'),
  ('schwer_35h',         'schwer', 'total_minutes',      2100, NULL, 5, 1, '35 Stunden Fokuszeit'),
  ('schwer_weekend10h',  'schwer', 'weekend_minutes',     600, NULL, 5, 2, '10 Stunden am Wochenende'),
  ('schwer_streak7',     'schwer', 'streak_days',           7, NULL, 5, 3, '7 Tage Streak'),
  ('schwer_4d5h',        'schwer', 'count_days_threshold',  4,  300, 5, 4, 'An 4 Tagen je 5 Stunden fokussieren'),
  ('schwer_30h',         'schwer', 'total_minutes',      1800, NULL, 5, 5, '30 Stunden Fokuszeit');


-- ═══════════════════════════════════════════════════
-- 3. calc_week_streak — identische Semantik zu computeCurrentStreak() (index.html),
--    nur auf die aktuelle Kalenderwoche begrenzt
-- ═══════════════════════════════════════════════════

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


-- ═══════════════════════════════════════════════════
-- 4. claim_weekly_challenge — serverseitige Neuberechnung, kein Client-Vertrauen
-- ═══════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.claim_weekly_challenge(p_challenge_key text)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_challenge    record;
  v_week_start   date;
  v_week_index   int;
  v_tier_offset  int;
  v_offset       int;
  v_progress     numeric;
  v_new_diamonds int;
BEGIN
  SELECT * INTO v_challenge FROM weekly_challenges WHERE challenge_key = p_challenge_key AND active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'challenge_not_found'; END IF;

  v_week_start := date_trunc('week', (now() AT TIME ZONE 'Europe/Berlin') - interval '4 hours')::date;
  v_week_index := floor((v_week_start - date '2024-01-01') / 7)::int;

  v_tier_offset := CASE v_challenge.tier WHEN 'leicht' THEN 0 WHEN 'mittel' THEN 2 WHEN 'schwer' THEN 4 END;
  v_offset := ((v_week_index + v_tier_offset) % 6 + 6) % 6;

  IF v_challenge.pool_index NOT IN (v_offset, (v_offset + 1) % 6, (v_offset + 2) % 6) THEN
    RAISE EXCEPTION 'challenge_not_active_this_week';
  END IF;

  IF EXISTS (
    SELECT 1 FROM weekly_challenge_claims
    WHERE user_id = auth.uid() AND week_start = v_week_start AND challenge_key = p_challenge_key
  ) THEN
    RAISE EXCEPTION 'already_claimed';
  END IF;

  IF v_challenge.metric_type = 'total_minutes' THEN
    SELECT COALESCE(SUM(minutes), 0) INTO v_progress
    FROM study_days WHERE user_id = auth.uid() AND date BETWEEN v_week_start AND v_week_start + 6;
  ELSIF v_challenge.metric_type = 'weekend_minutes' THEN
    SELECT COALESCE(SUM(minutes), 0) INTO v_progress
    FROM study_days
    WHERE user_id = auth.uid() AND date BETWEEN v_week_start AND v_week_start + 6
      AND extract(isodow FROM date) IN (6, 7);
  ELSIF v_challenge.metric_type = 'streak_days' THEN
    v_progress := calc_week_streak(v_week_start, auth.uid());
  ELSIF v_challenge.metric_type = 'count_days_threshold' THEN
    SELECT COUNT(*) INTO v_progress
    FROM study_days
    WHERE user_id = auth.uid() AND date BETWEEN v_week_start AND v_week_start + 6
      AND minutes >= v_challenge.param_h;
  END IF;

  IF v_progress < v_challenge.param_n THEN
    RAISE EXCEPTION 'threshold_not_met';
  END IF;

  INSERT INTO weekly_challenge_claims (user_id, week_start, challenge_key, reward_diamonds)
  VALUES (auth.uid(), v_week_start, p_challenge_key, v_challenge.reward_diamonds);

  UPDATE profiles SET diamonds = diamonds + v_challenge.reward_diamonds
  WHERE id = auth.uid()
  RETURNING diamonds INTO v_new_diamonds;

  RETURN v_new_diamonds;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.calc_week_streak(date, uuid) FROM anon;
REVOKE EXECUTE ON FUNCTION public.claim_weekly_challenge(text) FROM anon;
