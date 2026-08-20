-- ═══════════════════════════════════════════════════
-- Zwei zusätzliche Rennstrecken-Diamanten-Checkpoints bei 60 und 180 Minuten,
-- exakt nach dem Muster von 'flag'/'finish' (20260805000030). Einzel-Marker
-- (analog 'flag'), 1💎 je Checkpoint, nur der erste Nutzer des Tages.
-- ═══════════════════════════════════════════════════

-- 1. CHECK-Constraint um die zwei neuen Checkpoint-Namen erweitern
ALTER TABLE public.race_checkpoint_claims
  DROP CONSTRAINT IF EXISTS race_checkpoint_claims_checkpoint_check;
ALTER TABLE public.race_checkpoint_claims
  ADD CONSTRAINT race_checkpoint_claims_checkpoint_check
  CHECK (checkpoint IN ('flag','finish','checkpoint60','checkpoint180'));

-- 2. RPC um die zwei neuen Schwellen erweitern (Signatur/Rückgabetyp unverändert)
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

  IF p_checkpoint = 'checkpoint60' THEN
    v_threshold := 60; v_reward := 1;
  ELSIF p_checkpoint = 'checkpoint180' THEN
    v_threshold := 180; v_reward := 1;
  ELSIF p_checkpoint = 'flag' THEN
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
-- 3. Einmaliger Rollout-Backfill: 60 Minuten ist ein sehr häufig schon heute
--    erreichter Wert — ohne Backfill würde beim Deploy ein zufälliger, bereits
--    darüber liegender Nutzer den Diamanten nur wegen Poll-Timing "gratis"
--    bekommen. Markiert 'checkpoint60'/'checkpoint180' für HEUTE als bereits
--    verbraucht, falls die Schwelle schon erreicht wurde, ohne einen Gewinner
--    einzutragen. Ab morgen (neue Zeile, da UNIQUE(date, checkpoint)) läuft
--    der Mechanismus regulär.
-- ═══════════════════════════════════════════════════
INSERT INTO public.race_checkpoint_claims (date, checkpoint, user_id, reward_diamonds)
SELECT ((now() AT TIME ZONE 'Europe/Berlin') - interval '4 hours')::date, 'checkpoint60', NULL, 0
WHERE EXISTS (
  SELECT 1 FROM public.study_days
  WHERE date = ((now() AT TIME ZONE 'Europe/Berlin') - interval '4 hours')::date
    AND minutes >= 60
)
ON CONFLICT (date, checkpoint) DO NOTHING;

INSERT INTO public.race_checkpoint_claims (date, checkpoint, user_id, reward_diamonds)
SELECT ((now() AT TIME ZONE 'Europe/Berlin') - interval '4 hours')::date, 'checkpoint180', NULL, 0
WHERE EXISTS (
  SELECT 1 FROM public.study_days
  WHERE date = ((now() AT TIME ZONE 'Europe/Berlin') - interval '4 hours')::date
    AND minutes >= 180
)
ON CONFLICT (date, checkpoint) DO NOTHING;
