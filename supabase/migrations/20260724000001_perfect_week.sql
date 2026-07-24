-- Bonus für eine "perfekte Woche": alle 7 Tage (Mo 4h - So 4h Berlin) der
-- AKTUELLEN App-Woche haben minutes > 0 in study_days. Freie Tage retten
-- nicht (gleiche Designentscheidung wie bei Streaks, siehe
-- week_streak_ignores_off_days.sql) — ein 0-Minuten-Tag bricht die perfekte
-- Woche, ob als frei markiert oder nicht.

CREATE TABLE public.perfect_week_claims (
  user_id          uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  week_start       date NOT NULL,
  reward_diamonds  int  NOT NULL,
  claimed_at       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, week_start)
);

ALTER TABLE public.perfect_week_claims ENABLE ROW LEVEL SECURITY;

-- (INSERT erfolgt ausschließlich via claim_perfect_week() SECURITY DEFINER)
CREATE POLICY "perfect_week_claims_select_own" ON public.perfect_week_claims
  FOR SELECT USING (auth.uid() = user_id);

GRANT ALL ON TABLE public.perfect_week_claims TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.claim_perfect_week()
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_today        date;
  v_week_start   date;
  v_reward       CONSTANT int := 15;
  v_full_days    int;
  v_new_diamonds int;
BEGIN
  v_today      := ((now() AT TIME ZONE 'Europe/Berlin') - interval '4 hours')::date;
  v_week_start := date_trunc('week', (now() AT TIME ZONE 'Europe/Berlin') - interval '4 hours')::date;

  -- Verteidigung in der Tiefe: study_days-Schreibpfade validieren das Datum
  -- nicht gegen "heute" (siehe add_study_minutes-Vertrauensmodell in
  -- CLAUDE.md), daher zusätzlich verlangen, dass die Woche tatsächlich
  -- vorbei ist, bevor "alle 7 Tage" überhaupt geprüft wird.
  IF v_today < v_week_start + 6 THEN
    RAISE EXCEPTION 'week_not_over';
  END IF;

  IF EXISTS (
    SELECT 1 FROM perfect_week_claims WHERE user_id = auth.uid() AND week_start = v_week_start
  ) THEN
    RAISE EXCEPTION 'already_claimed';
  END IF;

  SELECT COUNT(*) INTO v_full_days
  FROM study_days
  WHERE user_id = auth.uid()
    AND date BETWEEN v_week_start AND v_week_start + 6
    AND minutes > 0;

  IF v_full_days < 7 THEN
    RAISE EXCEPTION 'week_not_perfect';
  END IF;

  INSERT INTO perfect_week_claims (user_id, week_start, reward_diamonds)
  VALUES (auth.uid(), v_week_start, v_reward);

  UPDATE profiles SET diamonds = diamonds + v_reward
  WHERE id = auth.uid()
  RETURNING diamonds INTO v_new_diamonds;

  RETURN v_new_diamonds;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.claim_perfect_week() FROM anon;
