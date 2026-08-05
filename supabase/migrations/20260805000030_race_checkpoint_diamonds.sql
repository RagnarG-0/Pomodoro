-- ═══════════════════════════════════════════════════
-- 1. Claims-Tabelle: pro Tag+Checkpoint genau ein Gewinner (oder ein
--    System-Platzhalter ohne Gewinner, siehe Rollout-Backfill unten)
-- ═══════════════════════════════════════════════════
CREATE TABLE public.race_checkpoint_claims (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  date             date NOT NULL,
  checkpoint       text NOT NULL CHECK (checkpoint IN ('flag','finish')),
  user_id          uuid REFERENCES public.profiles(id) ON DELETE CASCADE, -- NULL = System-Platzhalter (Rollout-Backfill, kein Gewinner)
  reward_diamonds  int  NOT NULL DEFAULT 0,
  claimed_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (date, checkpoint)
);

ALTER TABLE public.race_checkpoint_claims ENABLE ROW LEVEL SECURITY;

-- Öffentlich lesbar (auch ohne Login) — steuert nur, ob der 💎-Marker auf der
-- Strecke angezeigt wird; keine privaten Nutzerdaten, daher unproblematisch,
-- anders als die user-gebundenen *_claims-Tabellen sonst im Projekt.
CREATE POLICY "race_checkpoint_claims_select_all" ON public.race_checkpoint_claims
  FOR SELECT USING (true);

GRANT ALL ON TABLE public.race_checkpoint_claims TO anon, authenticated, service_role;

-- ═══════════════════════════════════════════════════
-- 2. RPC: serverseitige Neuprüfung + atomarer Claim-Mutex + Diamanten-Gutschrift
-- ═══════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.claim_race_checkpoint(p_checkpoint text)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_today        date;
  v_minutes      int;
  v_threshold    int;
  v_reward       int;
  v_claimed_id   uuid;
  v_new_diamonds int;
BEGIN
  v_today := ((now() AT TIME ZONE 'Europe/Berlin') - interval '4 hours')::date;

  IF p_checkpoint = 'flag' THEN
    v_threshold := 280; v_reward := 1;   -- Feld 14 (RACE_FLAG_MINUTES)
  ELSIF p_checkpoint = 'finish' THEN
    v_threshold := 700; v_reward := 5;   -- echte Ziellinie (RACE_FINISH_MINUTES)
  ELSE
    RAISE EXCEPTION 'invalid_checkpoint';
  END IF;

  SELECT minutes INTO v_minutes FROM study_days WHERE user_id = auth.uid() AND date = v_today;
  IF COALESCE(v_minutes, 0) < v_threshold THEN
    RAISE EXCEPTION 'threshold_not_met';
  END IF;

  INSERT INTO race_checkpoint_claims (date, checkpoint, user_id, reward_diamonds)
  VALUES (v_today, p_checkpoint, auth.uid(), v_reward)
  ON CONFLICT (date, checkpoint) DO NOTHING
  RETURNING id INTO v_claimed_id;

  IF v_claimed_id IS NULL THEN
    RETURN NULL; -- schon vergeben (an jemand anderen oder System-Platzhalter) — kein Fehler
  END IF;

  UPDATE profiles SET diamonds = diamonds + v_reward
  WHERE id = auth.uid()
  RETURNING diamonds INTO v_new_diamonds;

  RETURN v_new_diamonds;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.claim_race_checkpoint(text) FROM anon;
GRANT EXECUTE ON FUNCTION public.claim_race_checkpoint(text) TO authenticated, service_role;

-- ═══════════════════════════════════════════════════
-- 3. Einmaliger Rollout-Backfill: heute wurde das Flaggen-Feld bereits von
--    mehreren Nutzern passiert, BEVOR dieses Feature existierte — kein
--    rückwirkender Diamanten-Regen. Markiert 'flag' (und vorsorglich
--    'finish') für HEUTE als bereits verbraucht, falls die Schwelle schon
--    erreicht wurde, ohne einen Gewinner einzutragen. Ab morgen (neue Zeile
--    in der Tabelle, da UNIQUE(date, checkpoint)) läuft der Mechanismus
--    regulär.
-- ═══════════════════════════════════════════════════
INSERT INTO public.race_checkpoint_claims (date, checkpoint, user_id, reward_diamonds)
SELECT ((now() AT TIME ZONE 'Europe/Berlin') - interval '4 hours')::date, 'flag', NULL, 0
WHERE EXISTS (
  SELECT 1 FROM public.study_days
  WHERE date = ((now() AT TIME ZONE 'Europe/Berlin') - interval '4 hours')::date
    AND minutes >= 280
)
ON CONFLICT (date, checkpoint) DO NOTHING;

INSERT INTO public.race_checkpoint_claims (date, checkpoint, user_id, reward_diamonds)
SELECT ((now() AT TIME ZONE 'Europe/Berlin') - interval '4 hours')::date, 'finish', NULL, 0
WHERE EXISTS (
  SELECT 1 FROM public.study_days
  WHERE date = ((now() AT TIME ZONE 'Europe/Berlin') - interval '4 hours')::date
    AND minutes >= 700
)
ON CONFLICT (date, checkpoint) DO NOTHING;
