-- Fix: Die Remote-Version von claim_set_bonus() wurde (noch vor der
-- CLI-Umstellung, manuell im SQL-Editor) mit abweichenden Reward-Werten
-- 10/12/15/18/20 eingespielt, während 20260724000002_set_bonus.sql und
-- SET_BONUS_REWARD in index.html 15/20/25/35/50 vorsehen. Diese Migration
-- setzt die Funktion auf die dokumentierten Werte und zahlt bestehenden
-- Claims die Differenz nach (idempotent: danach gibt es keine Differenz mehr).

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

-- Nachzahlung der Differenz für bereits eingelöste Set-Boni.
CREATE TEMP TABLE _set_bonus_target (rarity text PRIMARY KEY, reward int) ON COMMIT DROP;
INSERT INTO _set_bonus_target VALUES
  ('common', 15), ('legendary', 20), ('epic', 25), ('mystic', 35), ('rare', 50);

UPDATE profiles p
SET diamonds = p.diamonds + d.diff
FROM (
  SELECT c.user_id, SUM(t.reward - c.reward_diamonds) AS diff
  FROM set_bonus_claims c
  JOIN _set_bonus_target t ON t.rarity = c.rarity
  WHERE c.reward_diamonds < t.reward
  GROUP BY c.user_id
) d
WHERE p.id = d.user_id;

UPDATE set_bonus_claims c
SET reward_diamonds = t.reward
FROM _set_bonus_target t
WHERE t.rarity = c.rarity AND c.reward_diamonds < t.reward;
