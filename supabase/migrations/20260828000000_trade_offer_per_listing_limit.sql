-- Ersetzt das globale "1 Gegenangebot pro Tag"-Limit durch ein Limit pro
-- Listing: ein Nutzer darf pro card_listings-Zeile höchstens ein offenes
-- (pending) Gegenangebot haben. Zieht er es zurück (neue RPC
-- cancel_trade_offer, Pendant zu cancel_listing), kann er ein neues für
-- dasselbe Listing abgeben. Für unterschiedliche Listings gibt es weiterhin
-- kein Limit.

-- ═══════════════════════════════════════════════════
-- 1. 'cancelled' als gültigen trade_offers-Status zulassen
--    (Zurückziehen durch den Angebotssteller selbst, analog
--    card_listings.status)
-- ═══════════════════════════════════════════════════
ALTER TABLE public.trade_offers DROP CONSTRAINT trade_offers_status_check;
ALTER TABLE public.trade_offers ADD CONSTRAINT trade_offers_status_check
  CHECK (status IN ('pending', 'accepted', 'rejected', 'cancelled'));

-- ═══════════════════════════════════════════════════
-- 2. DB-seitiger Claim-Mutex gegen doppelte pending-Angebote auf dasselbe
--    Listing durch denselben Nutzer (Race-Schutz, analog
--    card_listings_one_active_per_card)
-- ═══════════════════════════════════════════════════
CREATE UNIQUE INDEX trade_offers_one_pending_per_listing_offerer
  ON public.trade_offers (listing_id, offerer_id)
  WHERE status = 'pending';

-- ═══════════════════════════════════════════════════
-- 3. create_trade_offer(): Tages-Limit entfernt, stattdessen Prüfung auf
--    bereits bestehendes pending Gegenangebot desselben Nutzers auf
--    dasselbe Listing.
--
--    Begleitfix: die Kartenauswahl schloss bisher JEDE jemals in
--    trade_offer_cards aufgetauchte Kopie aus (auch aus längst
--    abgelehnten/zurückgezogenen Angeboten) — dadurch konnte eine Karte mit
--    nur einer Kopie nach einem abgelehnten/zurückgezogenen Gegenangebot nie
--    wieder angeboten werden. Das hätte das neue Zurückziehen-Feature
--    faktisch nutzlos gemacht. Jetzt zählen nur noch Kopien, die Teil eines
--    *aktuell* pending Angebots sind.
-- ═══════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.create_trade_offer(p_listing_id uuid, p_offered_card_ids int[])
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_listing      card_listings%ROWTYPE;
  v_offer_id     uuid;
  v_card_id      int;
  v_user_card_id uuid;
BEGIN
  IF p_offered_card_ids IS NULL OR array_length(p_offered_card_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'no_cards_offered';
  END IF;

  SELECT * INTO v_listing FROM card_listings WHERE id = p_listing_id AND status = 'active';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'listing_not_available';
  END IF;

  IF v_listing.seller_id = auth.uid() THEN
    RAISE EXCEPTION 'cannot_offer_on_own_listing';
  END IF;

  IF EXISTS (
    SELECT 1 FROM trade_offers
    WHERE offerer_id = auth.uid() AND listing_id = p_listing_id AND status = 'pending'
  ) THEN
    RAISE EXCEPTION 'offer_already_pending';
  END IF;

  INSERT INTO trade_offers (listing_id, offerer_id)
  VALUES (p_listing_id, auth.uid())
  RETURNING id INTO v_offer_id;

  FOREACH v_card_id IN ARRAY p_offered_card_ids LOOP
    -- Älteste eigene Kopie dieser Karte, die weder aktiv gelistet noch
    -- Teil irgendeines *aktuell pending* Gegenangebots ist — verhindert,
    -- dieselbe physische Karte doppelt zu verplanen, ohne bereits
    -- abgeschlossene (angenommene/abgelehnte/zurückgezogene) Gegenangebote
    -- dauerhaft zu blockieren.
    SELECT id INTO v_user_card_id
    FROM user_cards
    WHERE user_id = auth.uid()
      AND card_id = v_card_id
      AND id NOT IN (SELECT user_card_id FROM card_listings WHERE status = 'active')
      AND id NOT IN (
        SELECT toc.user_card_id
        FROM trade_offer_cards toc
        JOIN trade_offers o ON o.id = toc.trade_offer_id
        WHERE o.status = 'pending'
      )
    ORDER BY obtained_at ASC
    LIMIT 1;

    IF v_user_card_id IS NULL THEN
      RAISE EXCEPTION 'card_not_available';
    END IF;

    INSERT INTO trade_offer_cards (trade_offer_id, user_card_id, card_id)
    VALUES (v_offer_id, v_user_card_id, v_card_id);
  END LOOP;

  RETURN v_offer_id;
END;
$$;
GRANT EXECUTE ON FUNCTION public.create_trade_offer(uuid, int[]) TO anon, authenticated, service_role;

-- ═══════════════════════════════════════════════════
-- 4. Neue RPC: eigenes pending Gegenangebot zurückziehen
--    (fehlte bisher komplett — Pendant zu cancel_listing())
-- ═══════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.cancel_trade_offer(p_offer_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE trade_offers
     SET status = 'cancelled', responded_at = now()
   WHERE id = p_offer_id
     AND offerer_id = auth.uid()
     AND status = 'pending';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'offer_not_cancellable';
  END IF;
END;
$$;
GRANT EXECUTE ON FUNCTION public.cancel_trade_offer(uuid) TO anon, authenticated, service_role;
