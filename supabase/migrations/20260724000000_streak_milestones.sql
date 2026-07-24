-- Einmalige Diamanten-Boni für Streak-Meilensteine. Tunable Reward-Tabelle
-- (UPDATE ohne neue Migration möglich), Claims serverseitig verifiziert
-- über eine neue, ungebundene (nicht wochenbegrenzte) Streak-Funktion,
-- die exakt die Semantik von computeCurrentStreak() (index.html) spiegelt.

-- ═══════════════════════════════════════════════════
-- 1. TABELLEN
-- ═══════════════════════════════════════════════════

CREATE TABLE public.streak_milestones (
  days             int PRIMARY KEY CHECK (days > 0),
  reward_diamonds  int NOT NULL CHECK (reward_diamonds > 0)
);

CREATE TABLE public.streak_milestone_claims (
  user_id          uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  days             int  NOT NULL REFERENCES public.streak_milestones(days),
  reward_diamonds  int  NOT NULL, -- Snapshot zum Claim-Zeitpunkt
  claimed_at       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, days)
);

ALTER TABLE public.streak_milestones       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.streak_milestone_claims ENABLE ROW LEVEL SECURITY;

-- streak_milestones: öffentlicher Katalog, jeder darf lesen (wie weekly_challenges)
CREATE POLICY "streak_milestones_select_all" ON public.streak_milestones
  FOR SELECT USING (true);

-- streak_milestone_claims: Nutzer sieht nur eigene Claims
-- (INSERT erfolgt ausschließlich via claim_streak_milestone() SECURITY DEFINER)
CREATE POLICY "streak_milestone_claims_select_own" ON public.streak_milestone_claims
  FOR SELECT USING (auth.uid() = user_id);

GRANT ALL ON TABLE public.streak_milestones       TO anon, authenticated, service_role;
GRANT ALL ON TABLE public.streak_milestone_claims TO anon, authenticated, service_role;


-- ═══════════════════════════════════════════════════
-- 2. SEED
-- ═══════════════════════════════════════════════════

INSERT INTO public.streak_milestones (days, reward_diamonds) VALUES
  (7,   5),
  (14,  10),
  (30,  20),
  (60,  35),
  (100, 60),
  (200, 120),
  (365, 250);


-- ═══════════════════════════════════════════════════
-- 3. calc_current_streak — ungebundenes Pendant zu calc_week_streak(),
--    identische Semantik zu computeCurrentStreak() (index.html:2832):
--    rückwärts ab heute, "heute leer" bricht nicht ab, jeder andere leere
--    Tag schon. Kein Off-Day-Skip (siehe week_streak_ignores_off_days.sql —
--    dieselbe Designentscheidung gilt hier).
-- ═══════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.calc_current_streak(p_user_id uuid)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_today   date;
  v_day     date;
  v_streak  int := 0;
  v_minutes int;
BEGIN
  v_today := ((now() AT TIME ZONE 'Europe/Berlin') - interval '4 hours')::date;
  v_day   := v_today;

  LOOP
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


-- ═══════════════════════════════════════════════════
-- 4. claim_streak_milestone — serverseitige Neuberechnung, kein Client-Vertrauen
-- ═══════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.claim_streak_milestone(p_days int)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_milestone    record;
  v_streak       int;
  v_new_diamonds int;
BEGIN
  SELECT * INTO v_milestone FROM streak_milestones WHERE days = p_days;
  IF NOT FOUND THEN RAISE EXCEPTION 'milestone_not_found'; END IF;

  IF EXISTS (
    SELECT 1 FROM streak_milestone_claims WHERE user_id = auth.uid() AND days = p_days
  ) THEN
    RAISE EXCEPTION 'already_claimed';
  END IF;

  v_streak := calc_current_streak(auth.uid());
  IF v_streak < p_days THEN
    RAISE EXCEPTION 'threshold_not_met';
  END IF;

  INSERT INTO streak_milestone_claims (user_id, days, reward_diamonds)
  VALUES (auth.uid(), p_days, v_milestone.reward_diamonds);

  UPDATE profiles SET diamonds = diamonds + v_milestone.reward_diamonds
  WHERE id = auth.uid()
  RETURNING diamonds INTO v_new_diamonds;

  RETURN v_new_diamonds;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.calc_current_streak(uuid)   FROM anon;
REVOKE EXECUTE ON FUNCTION public.claim_streak_milestone(int) FROM anon;
