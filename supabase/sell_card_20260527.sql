-- RPC: sell_card(p_card_id int)
-- Verkauft ein Duplikat einer Karte gegen Diamanten.
-- Gibt den neuen Diamanten-Stand zurück.
-- Wirft Fehler wenn weniger als 2 Kopien vorhanden.

CREATE OR REPLACE FUNCTION sell_card(p_card_id int)
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_rarity      text;
  v_reward      int;
  v_row_id      uuid;
  v_count       int;
  v_new_diamonds int;
BEGIN
  -- Rarität der Karte ermitteln
  SELECT rarity INTO v_rarity FROM cards WHERE id = p_card_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'card_not_found'; END IF;

  -- Belohnung je Rarität
  v_reward := CASE v_rarity
    WHEN 'common'    THEN 2
    WHEN 'rare'      THEN 4
    WHEN 'epic'      THEN 6
    WHEN 'legendary' THEN 8
    WHEN 'mystic'    THEN 10
    ELSE 0
  END;

  -- Sicherstellen, dass mindestens 2 Kopien vorhanden sind
  SELECT COUNT(*) INTO v_count
  FROM user_cards
  WHERE user_id = auth.uid() AND card_id = p_card_id;

  IF v_count < 2 THEN RAISE EXCEPTION 'not_enough_copies'; END IF;

  -- Älteste Kopie löschen
  SELECT id INTO v_row_id
  FROM user_cards
  WHERE user_id = auth.uid() AND card_id = p_card_id
  ORDER BY obtained_at ASC
  LIMIT 1;

  DELETE FROM user_cards WHERE id = v_row_id;

  -- Diamanten gutschreiben
  UPDATE profiles
  SET diamonds = diamonds + v_reward
  WHERE id = auth.uid()
  RETURNING diamonds INTO v_new_diamonds;

  RETURN v_new_diamonds;
END;
$$;
