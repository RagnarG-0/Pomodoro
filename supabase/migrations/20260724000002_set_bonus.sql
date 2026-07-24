-- Einmaliger Bonus pro Rarität für "mind. 1 Kopie jeder Karte dieser
-- Rarität besitzen". cards.rarity ist die Quelle der Wahrheit für die
-- Katalog-Größe je Rarität (muss synchron zu CARD_CATALOG in index.html
-- gehalten werden, exakt wie beim Karten-Katalog an anderer Stelle schon
-- etabliert).

CREATE TABLE public.set_bonus_claims (
  user_id          uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  rarity           text NOT NULL CHECK (rarity IN ('common','rare','epic','legendary','mystic')),
  reward_diamonds  int  NOT NULL,
  claimed_at       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, rarity)
);

ALTER TABLE public.set_bonus_claims ENABLE ROW LEVEL SECURITY;

-- (INSERT erfolgt ausschließlich via claim_set_bonus() SECURITY DEFINER)
CREATE POLICY "set_bonus_claims_select_own" ON public.set_bonus_claims
  FOR SELECT USING (auth.uid() = user_id);

GRANT ALL ON TABLE public.set_bonus_claims TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.claim_set_bonus(p_rarity text)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reward       int;
  v_total        int;
  v_owned        int;
  v_new_diamonds int;
BEGIN
  -- Reward-Höhe folgt der tatsächlichen Set-Schwierigkeit (Coupon-Collector-
  -- Erwartungswert aus Katalog-Größe x Ziehquote), nicht der reinen
  -- Rarität-Bezeichnung — "rare" (17 Karten, 30%) ist trotz gemäßigter
  -- Ziehquote das schwerste Set, "legendary" (3 Karten, 9%) ist dagegen
  -- vergleichsweise leicht komplettierbar.
  v_reward := CASE p_rarity
    WHEN 'common'    THEN 15
    WHEN 'legendary' THEN 20
    WHEN 'epic'      THEN 25
    WHEN 'mystic'    THEN 35
    WHEN 'rare'      THEN 50
    ELSE NULL
  END;
  IF v_reward IS NULL THEN RAISE EXCEPTION 'invalid_rarity'; END IF;

  IF EXISTS (
    SELECT 1 FROM set_bonus_claims WHERE user_id = auth.uid() AND rarity = p_rarity
  ) THEN
    RAISE EXCEPTION 'already_claimed';
  END IF;

  SELECT COUNT(*) INTO v_total FROM cards WHERE rarity = p_rarity;

  SELECT COUNT(DISTINCT card_id) INTO v_owned
  FROM user_cards
  WHERE user_id = auth.uid()
    AND card_id IN (SELECT id FROM cards WHERE rarity = p_rarity);

  IF v_owned < v_total THEN
    RAISE EXCEPTION 'set_not_complete';
  END IF;

  INSERT INTO set_bonus_claims (user_id, rarity, reward_diamonds)
  VALUES (auth.uid(), p_rarity, v_reward);

  UPDATE profiles SET diamonds = diamonds + v_reward
  WHERE id = auth.uid()
  RETURNING diamonds INTO v_new_diamonds;

  RETURN v_new_diamonds;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.claim_set_bonus(text) FROM anon;
