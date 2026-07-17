-- Tauschbörse: von Fixpreis-Kauf (Diamanten) zu echtem Karten-Tausch.
-- Ersetzt buy_listing() durch ein Gegenangebot-Modell: Spieler bieten Karten
-- zum Tausch an (card_listings, wie bisher, nur ohne Preis), andere Spieler
-- machen Gegenangebote aus einer oder mehreren eigenen Karten (trade_offers +
-- trade_offer_cards), der Angebotsersteller nimmt an oder lehnt ab.

-- ═══════════════════════════════════════════════════
-- 1. card_listings umbauen (kein Preis mehr)
-- ═══════════════════════════════════════════════════

-- Bestehende aktive Angebote sind unter dem Preis-Modell entstanden und damit
-- unter dem neuen Tausch-Modell semantisch ungültig — sauber schließen statt
-- migrieren.
UPDATE public.card_listings SET status = 'cancelled' WHERE status = 'active';

-- Policy referenziert buyer_id — muss vor dem DROP COLUMN weg, sonst Fehler.
DROP POLICY IF EXISTS "card_listings_select" ON public.card_listings;

-- Alter CHECK ('active'/'sold'/'cancelled') muss weg, BEVOR 'sold'-Zeilen auf
-- 'traded' umgeschrieben werden — sonst verbietet noch der alte Constraint
-- genau den Wert, den wir gerade erst per neuem Constraint erlauben wollen.
ALTER TABLE public.card_listings DROP CONSTRAINT IF EXISTS card_listings_status_check;

-- Bereits abgeschlossene Käufe ('sold', altes Preis-Modell) sind unter dem
-- neuen status-CHECK ('active'/'traded'/'cancelled') kein gültiger Wert mehr
-- — als bereits abgeschlossene Transaktion ist 'traded' die richtige Analogie.
UPDATE public.card_listings SET status = 'traded' WHERE status = 'sold';

ALTER TABLE public.card_listings DROP COLUMN price_diamonds;
ALTER TABLE public.card_listings DROP COLUMN buyer_id;
ALTER TABLE public.card_listings RENAME COLUMN sold_at TO traded_at;
ALTER TABLE public.card_listings ADD CONSTRAINT card_listings_status_check
  CHECK (status IN ('active', 'traded', 'cancelled'));

CREATE POLICY "card_listings_select" ON public.card_listings
  FOR SELECT USING (status = 'active' OR seller_id = auth.uid());

-- ═══════════════════════════════════════════════════
-- 2. trade_offers + trade_offer_cards (das Gegenangebot)
-- ═══════════════════════════════════════════════════

CREATE TABLE public.trade_offers (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  listing_id   uuid        NOT NULL REFERENCES public.card_listings(id) ON DELETE CASCADE,
  offerer_id   uuid        NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  status       text        NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'accepted', 'rejected')),
  created_at   timestamptz NOT NULL DEFAULT now(),
  responded_at timestamptz
);
CREATE INDEX trade_offers_listing_idx ON public.trade_offers (listing_id, status);
CREATE INDEX trade_offers_offerer_idx ON public.trade_offers (offerer_id, created_at);

CREATE TABLE public.trade_offer_cards (
  trade_offer_id uuid NOT NULL REFERENCES public.trade_offers(id) ON DELETE CASCADE,
  user_card_id   uuid NOT NULL REFERENCES public.user_cards(id) ON DELETE CASCADE,
  card_id        int  NOT NULL REFERENCES public.cards(id),
  PRIMARY KEY (trade_offer_id, user_card_id)
);

ALTER TABLE public.trade_offers      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.trade_offer_cards ENABLE ROW LEVEL SECURITY;

-- SECURITY DEFINER-Helper statt direkter Cross-Table-Subqueries in den
-- Policies — sonst rekursiver RLS-Loop (card_listings ↔ trade_offers),
-- gleiches Muster wie has_active_listing()/my_clan_id().
CREATE OR REPLACE FUNCTION public.owns_listing(p_listing_id uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM card_listings WHERE id = p_listing_id AND seller_id = auth.uid()
  );
$$;
GRANT EXECUTE ON FUNCTION public.owns_listing(uuid) TO anon, authenticated, service_role;

CREATE POLICY "trade_offers_select" ON public.trade_offers
  FOR SELECT USING (offerer_id = auth.uid() OR public.owns_listing(listing_id));
-- keine INSERT/UPDATE/DELETE-Policy — Schreiben nur via RPC

CREATE OR REPLACE FUNCTION public.can_view_trade_offer(p_trade_offer_id uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM trade_offers o
    WHERE o.id = p_trade_offer_id
      AND (o.offerer_id = auth.uid() OR public.owns_listing(o.listing_id))
  );
$$;
GRANT EXECUTE ON FUNCTION public.can_view_trade_offer(uuid) TO anon, authenticated, service_role;

CREATE POLICY "trade_offer_cards_select" ON public.trade_offer_cards
  FOR SELECT USING (public.can_view_trade_offer(trade_offer_id));

GRANT ALL ON TABLE public.trade_offers      TO anon, authenticated, service_role;
GRANT ALL ON TABLE public.trade_offer_cards TO anon, authenticated, service_role;

-- ═══════════════════════════════════════════════════
-- 3. card_trades (Audit-Log): price_diamonds raus, trade_offer_id rein
-- ═══════════════════════════════════════════════════
-- Pro abgeschlossenem Tausch entsteht künftig eine Zeile PRO bewegter Karte
-- (nicht mehr eine Zeile pro Trade) — eine für die gelistete Karte
-- (seller→offerer) und je eine pro angebotener Karte (offerer→seller), alle
-- mit derselben trade_offer_id gruppiert. seller_id/buyer_id bleiben als
-- "Abgeber"/"Empfänger" DIESER EINEN Karte bestehen.

ALTER TABLE public.card_trades DROP COLUMN price_diamonds;
ALTER TABLE public.card_trades ADD COLUMN trade_offer_id uuid REFERENCES public.trade_offers(id);
CREATE INDEX card_trades_offer_idx ON public.card_trades (trade_offer_id);

-- ═══════════════════════════════════════════════════
-- 4. create_listing(p_card_id) — kein Preis mehr
-- ═══════════════════════════════════════════════════

DROP FUNCTION IF EXISTS public.create_listing(int, int);

CREATE OR REPLACE FUNCTION public.create_listing(p_card_id int)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_card_id uuid;
  v_listing_id   uuid;
BEGIN
  -- Älteste noch nicht aktiv gelistete Kopie dieser Karte finden.
  -- Keine Mindestbestand-Prüfung — auch die letzte Kopie ist listbar.
  SELECT id INTO v_user_card_id
  FROM user_cards
  WHERE user_id = auth.uid()
    AND card_id = p_card_id
    AND id NOT IN (SELECT user_card_id FROM card_listings WHERE status = 'active')
  ORDER BY obtained_at ASC
  LIMIT 1;

  IF v_user_card_id IS NULL THEN
    RAISE EXCEPTION 'no_available_copy';
  END IF;

  INSERT INTO card_listings (seller_id, user_card_id, card_id)
  VALUES (auth.uid(), v_user_card_id, p_card_id)
  RETURNING id INTO v_listing_id;

  RETURN v_listing_id;
END;
$$;
GRANT EXECUTE ON FUNCTION public.create_listing(int) TO anon, authenticated, service_role;

-- ═══════════════════════════════════════════════════
-- 5. cancel_listing(p_listing_id) — zusätzlich offene Gegenangebote verwerfen
-- ═══════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.cancel_listing(p_listing_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE card_listings
     SET status = 'cancelled'
   WHERE id = p_listing_id
     AND seller_id = auth.uid()
     AND status = 'active';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'listing_not_cancellable';
  END IF;

  -- Gegenangebote auf ein zurückgezogenes Angebot sind gegenstandslos.
  UPDATE trade_offers
     SET status = 'rejected', responded_at = now()
   WHERE listing_id = p_listing_id AND status = 'pending';
END;
$$;
GRANT EXECUTE ON FUNCTION public.cancel_listing(uuid) TO anon, authenticated, service_role;

-- ═══════════════════════════════════════════════════
-- 6. buy_listing() entfernen — ersetzt durch create_trade_offer/respond_to_trade_offer
-- ═══════════════════════════════════════════════════

DROP FUNCTION IF EXISTS public.buy_listing(uuid);

-- ═══════════════════════════════════════════════════
-- 7. create_trade_offer(p_listing_id, p_offered_card_ids)
-- ═══════════════════════════════════════════════════
-- Tages-Limit: max. 1 Gegenangebot pro Nutzer pro App-Tag (global, nicht pro
-- Angebot). App-Tag-Grenze = 4 Uhr Berliner Zeit, DST-sicher, gleiches Muster
-- wie reset_stale_work_sessions() ((datum + zeit) AT TIME ZONE 'Europe/Berlin'
-- konstruiert eine timestamptz aus einem in dieser Zone interpretierten
-- naiven Zeitpunkt).

-- p_offered_card_ids referenziert Katalog-Karten (cards.id), nicht user_cards.id
-- — wie create_listing()/sell_card() lässt der Client den Server die konkrete
-- Kopie wählen. eggDeck (Client) kennt ohnehin nur card_id + Stückzahl, nie
-- einzelne user_cards-Zeilen-IDs. Mehrfachnennung derselben card_id ist
-- erlaubt (mehrere eigene Kopien derselben Karte anbieten).
CREATE OR REPLACE FUNCTION public.create_trade_offer(p_listing_id uuid, p_offered_card_ids int[])
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_listing      card_listings%ROWTYPE;
  v_now_berlin   timestamp;
  v_day_start    timestamptz;
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

  v_now_berlin := now() AT TIME ZONE 'Europe/Berlin';
  v_day_start := (v_now_berlin::date - CASE WHEN v_now_berlin::time < time '04:00' THEN 1 ELSE 0 END)
                 + time '04:00' AT TIME ZONE 'Europe/Berlin';

  IF EXISTS (
    SELECT 1 FROM trade_offers WHERE offerer_id = auth.uid() AND created_at >= v_day_start
  ) THEN
    RAISE EXCEPTION 'daily_offer_limit_reached';
  END IF;

  INSERT INTO trade_offers (listing_id, offerer_id)
  VALUES (p_listing_id, auth.uid())
  RETURNING id INTO v_offer_id;

  FOREACH v_card_id IN ARRAY p_offered_card_ids LOOP
    -- Älteste eigene Kopie dieser Karte, die weder aktiv gelistet noch
    -- bereits Teil irgendeines (auch dieses gerade entstehenden) Gegenangebots
    -- ist — verhindert, dieselbe physische Karte doppelt zu verplanen.
    SELECT id INTO v_user_card_id
    FROM user_cards
    WHERE user_id = auth.uid()
      AND card_id = v_card_id
      AND id NOT IN (SELECT user_card_id FROM card_listings WHERE status = 'active')
      AND id NOT IN (SELECT user_card_id FROM trade_offer_cards)
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
-- 8. respond_to_trade_offer(p_offer_id, p_accept) — atomarer Kern
-- ═══════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.respond_to_trade_offer(p_offer_id uuid, p_accept boolean)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_offer                 trade_offers%ROWTYPE;
  v_listing                card_listings%ROWTYPE;
  v_expected_offered_count int;
  v_moved_offered_count    int;
  v_moved_ids              uuid[];
BEGIN
  SELECT * INTO v_offer FROM trade_offers WHERE id = p_offer_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'offer_not_found';
  END IF;

  SELECT * INTO v_listing FROM card_listings WHERE id = v_offer.listing_id;
  IF NOT FOUND OR v_listing.seller_id <> auth.uid() THEN
    RAISE EXCEPTION 'not_listing_owner';
  END IF;

  -- Claim-Mutex: nur der erste Accept/Reject auf ein noch pending Angebot gewinnt.
  UPDATE trade_offers
     SET status = CASE WHEN p_accept THEN 'accepted' ELSE 'rejected' END,
         responded_at = now()
   WHERE id = p_offer_id AND status = 'pending'
  RETURNING * INTO v_offer;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'offer_not_pending';
  END IF;

  IF NOT p_accept THEN
    RETURN;
  END IF;

  -- Listing-Claim-Mutex active→traded (Verteidigung; kann durch obigen
  -- Offer-Mutex + Seller-Check eigentlich nur active sein).
  UPDATE card_listings
     SET status = 'traded', traded_at = now()
   WHERE id = v_listing.id AND status = 'active'
  RETURNING * INTO v_listing;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'listing_no_longer_active';
  END IF;

  -- Gelistete Karte → Offerer
  UPDATE user_cards
     SET user_id = v_offer.offerer_id, obtained_at = now()
   WHERE id = v_listing.user_card_id AND user_id = v_listing.seller_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'source_card_missing';
  END IF;

  -- Angebotene Karten → Seller (Guard: Offerer könnte eine der Karten
  -- inzwischen über einen anderen akzeptierten Tausch verloren haben —
  -- rollt in diesem Fall die gesamte Transaktion zurück).
  SELECT count(*) INTO v_expected_offered_count
  FROM trade_offer_cards WHERE trade_offer_id = v_offer.id;

  UPDATE user_cards uc
     SET user_id = v_listing.seller_id, obtained_at = now()
    FROM trade_offer_cards toc
   WHERE toc.trade_offer_id = v_offer.id
     AND uc.id = toc.user_card_id
     AND uc.user_id = v_offer.offerer_id;
  GET DIAGNOSTICS v_moved_offered_count = ROW_COUNT;

  IF v_moved_offered_count <> v_expected_offered_count THEN
    RAISE EXCEPTION 'offered_card_missing';
  END IF;

  -- Unveränderliches Audit-Log: eine Zeile pro bewegter Karte
  INSERT INTO card_trades (listing_id, seller_id, buyer_id, card_id, user_card_id, trade_offer_id)
  VALUES (v_listing.id, v_listing.seller_id, v_offer.offerer_id, v_listing.card_id, v_listing.user_card_id, v_offer.id);

  INSERT INTO card_trades (listing_id, seller_id, buyer_id, card_id, user_card_id, trade_offer_id)
  SELECT v_listing.id, v_offer.offerer_id, v_listing.seller_id, toc.card_id, toc.user_card_id, v_offer.id
  FROM trade_offer_cards toc
  WHERE toc.trade_offer_id = v_offer.id;

  -- Cleanup-Kaskade: alle Angebote/Gegenangebote, die mit den soeben
  -- bewegten physischen Karten zusammenhängen, sind gegenstandslos.
  SELECT array_agg(user_card_id) INTO v_moved_ids
  FROM (
    SELECT v_listing.user_card_id AS user_card_id
    UNION ALL
    SELECT user_card_id FROM trade_offer_cards WHERE trade_offer_id = v_offer.id
  ) moved;

  UPDATE card_listings
     SET status = 'cancelled'
   WHERE user_card_id = ANY(v_moved_ids) AND status = 'active';

  UPDATE trade_offers
     SET status = 'rejected', responded_at = now()
   WHERE status = 'pending'
     AND (
       listing_id = v_listing.id
       OR id IN (SELECT trade_offer_id FROM trade_offer_cards WHERE user_card_id = ANY(v_moved_ids))
     );
END;
$$;
GRANT EXECUTE ON FUNCTION public.respond_to_trade_offer(uuid, boolean) TO anon, authenticated, service_role;

-- ═══════════════════════════════════════════════════
-- 9. get_incoming_trade_offers() — für die Glocke
-- ═══════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.get_incoming_trade_offers()
RETURNS TABLE (
  offer_id         uuid,
  listing_id       uuid,
  card_id          int,
  offerer_username text,
  created_at       timestamptz
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT o.id, o.listing_id, l.card_id, p.username, o.created_at
  FROM trade_offers o
  JOIN card_listings l ON l.id = o.listing_id
  JOIN profiles p ON p.id = o.offerer_id
  WHERE l.seller_id = auth.uid() AND o.status = 'pending'
  ORDER BY o.created_at DESC;
$$;
GRANT EXECUTE ON FUNCTION public.get_incoming_trade_offers() TO anon, authenticated, service_role;
