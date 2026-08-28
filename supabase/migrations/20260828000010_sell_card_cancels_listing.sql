-- Verkauft ein Nutzer ein Duplikat einer Karte, sollen alle eigenen aktiven
-- Tausch-Angebote dieser Karte (card_id) automatisch mit zurückgezogen
-- werden, inkl. Ablehnung noch offener Gegenangebote darauf — ein
-- Duplikat-Verkauf ("ich brauche das nicht mehr") ist inkompatibel mit einem
-- weiterhin aktiven Tauschangebot für dieselbe Karte.
--
-- Vorher wählte sell_card() lediglich eine nicht aktiv gelistete Kopie zum
-- Löschen aus und ließ eine bestehende Listung unangetastet stehen —
-- sichtbar als weiterhin aktives Angebot in der Tauschbörse nach dem
-- Verkauf und als weiterhin sichtbares eingehendes Gegenangebot in der
-- Kopf-Glocke, bis der Nutzer die Listung manuell zurückzog.
CREATE OR REPLACE FUNCTION public.sell_card(p_card_id int)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rarity text; v_reward int; v_row_id uuid; v_count int; v_new_diamonds int;
  v_cancelled_ids uuid[];
BEGIN
  SELECT rarity INTO v_rarity FROM cards WHERE id = p_card_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'card_not_found'; END IF;

  v_reward := CASE v_rarity
    WHEN 'common' THEN 4 WHEN 'rare' THEN 8 WHEN 'epic' THEN 12
    WHEN 'legendary' THEN 16 WHEN 'mystic' THEN 20 ELSE 0
  END;

  SELECT COUNT(*) INTO v_count FROM user_cards WHERE user_id = auth.uid() AND card_id = p_card_id;
  IF v_count < 2 THEN RAISE EXCEPTION 'not_enough_copies'; END IF;

  -- Eigene aktive Listings dieser Karte zurückziehen + offene
  -- Gegenangebote darauf ablehnen (identisches Muster wie cancel_listing()).
  WITH cancelled AS (
    UPDATE card_listings
       SET status = 'cancelled'
     WHERE seller_id = auth.uid() AND card_id = p_card_id AND status = 'active'
    RETURNING id
  )
  SELECT array_agg(id) INTO v_cancelled_ids FROM cancelled;

  IF v_cancelled_ids IS NOT NULL THEN
    UPDATE trade_offers
       SET status = 'rejected', responded_at = now()
     WHERE listing_id = ANY(v_cancelled_ids) AND status = 'pending';
  END IF;

  -- Keine aktive Listung dieser card_id existiert an dieser Stelle mehr
  -- (gerade oben zurückgezogen) — einfach die älteste Kopie wählen.
  SELECT id INTO v_row_id
  FROM user_cards
  WHERE user_id = auth.uid() AND card_id = p_card_id
  ORDER BY obtained_at ASC
  LIMIT 1;

  DELETE FROM user_cards WHERE id = v_row_id;
  UPDATE profiles SET diamonds = diamonds + v_reward WHERE id = auth.uid() RETURNING diamonds INTO v_new_diamonds;
  RETURN v_new_diamonds;
END;
$$;
