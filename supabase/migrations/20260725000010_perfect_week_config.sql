-- Macht den Perfekte-Woche-Reward über Supabase editierbar (analog
-- streak_milestones), statt hardcodiert in claim_perfect_week() zu stehen.
-- Singleton-Config-Tabelle mit genau einer Zeile (id=1) statt einer
-- Konstanten im PL/pgSQL-Body.

CREATE TABLE public.perfect_week_config (
  id               int PRIMARY KEY DEFAULT 1,
  reward_diamonds  int NOT NULL DEFAULT 15,
  CONSTRAINT perfect_week_config_singleton CHECK (id = 1)
);

INSERT INTO public.perfect_week_config (id, reward_diamonds) VALUES (1, 15);

ALTER TABLE public.perfect_week_config ENABLE ROW LEVEL SECURITY;

-- Öffentlich lesbar (auch ohne Login), analog streak_milestones_select_all.
CREATE POLICY "perfect_week_config_select_all" ON public.perfect_week_config
  FOR SELECT USING (true);

GRANT SELECT ON TABLE public.perfect_week_config TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.claim_perfect_week()
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_today        date;
  v_week_start   date;
  v_reward       int;
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
    AND minutes >= 60;

  IF v_full_days < 7 THEN
    RAISE EXCEPTION 'week_not_perfect';
  END IF;

  SELECT reward_diamonds INTO v_reward FROM perfect_week_config WHERE id = 1;

  INSERT INTO perfect_week_claims (user_id, week_start, reward_diamonds)
  VALUES (auth.uid(), v_week_start, v_reward);

  UPDATE profiles SET diamonds = diamonds + v_reward
  WHERE id = auth.uid()
  RETURNING diamonds INTO v_new_diamonds;

  RETURN v_new_diamonds;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.claim_perfect_week() FROM anon;
