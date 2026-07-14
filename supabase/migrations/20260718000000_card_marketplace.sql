-- Karten-Tauschbörse: Nutzer bieten Karten aus user_cards für einen frei
-- gewählten Diamanten-Preis an, alle Spieler sehen alle Angebote.
--
-- Transaktionsmodell: keine Blockchain (Hash-Chaining/verteilter Konsens löst
-- ein Problem, das hier nicht existiert — es gibt nur eine vertrauenswürdige
-- Postgres-Instanz). Stattdessen: ACID-Transaktion (SECURITY DEFINER-RPC,
-- Claim-Mutex-Pattern wie bei timer_state) + unveränderliches Audit-Log
-- (card_trades, insert-only).

-- ═══════════════════════════════════════════════════
-- 1. TABELLEN
-- ═══════════════════════════════════════════════════

CREATE TABLE public.card_listings (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  seller_id       uuid        NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  user_card_id    uuid        NOT NULL REFERENCES public.user_cards(id) ON DELETE CASCADE,
  card_id         int         NOT NULL REFERENCES public.cards(id),
  price_diamonds  int         NOT NULL CHECK (price_diamonds > 0 AND price_diamonds <= 9999),
  status          text        NOT NULL DEFAULT 'active' CHECK (status IN ('active','sold','cancelled')),
  buyer_id        uuid        REFERENCES public.profiles(id) ON DELETE SET NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  sold_at         timestamptz
);

-- Kern-Constraint: eine physische Karten-Kopie kann nie zweimal gleichzeitig aktiv gelistet sein
CREATE UNIQUE INDEX card_listings_one_active_per_card
  ON public.card_listings (user_card_id) WHERE (status = 'active');

-- Browse-Query ("Alle Angebote"): neueste zuerst, nur aktive
CREATE INDEX card_listings_active_idx
  ON public.card_listings (status, created_at DESC) WHERE (status = 'active');

-- "Meine Angebote"
CREATE INDEX card_listings_seller_idx ON public.card_listings (seller_id, status);

-- Unveränderliches Audit-Log — kein UPDATE/DELETE möglich (keine entsprechende
-- RLS-Policy weiter unten), Schreibzugriff ausschließlich über buy_listing()
-- (SECURITY DEFINER, umgeht RLS als Funktions-Owner).
CREATE TABLE public.card_trades (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  listing_id      uuid        NOT NULL REFERENCES public.card_listings(id),
  seller_id       uuid        NOT NULL REFERENCES public.profiles(id),
  buyer_id        uuid        NOT NULL REFERENCES public.profiles(id),
  card_id         int         NOT NULL REFERENCES public.cards(id),
  user_card_id    uuid        NOT NULL REFERENCES public.user_cards(id),
  price_diamonds  int         NOT NULL,
  traded_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX card_trades_seller_idx ON public.card_trades (seller_id);
CREATE INDEX card_trades_buyer_idx  ON public.card_trades (buyer_id);

-- ═══════════════════════════════════════════════════
-- 2. RLS
-- ═══════════════════════════════════════════════════

ALTER TABLE public.card_listings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.card_trades   ENABLE ROW LEVEL SECURITY;

CREATE POLICY "card_listings_select" ON public.card_listings
  FOR SELECT USING (status = 'active' OR seller_id = auth.uid() OR buyer_id = auth.uid());
-- keine INSERT/UPDATE/DELETE-Policy — analog zu user_cards, Schreiben nur via RPC

CREATE POLICY "card_trades_select_own" ON public.card_trades
  FOR SELECT USING (seller_id = auth.uid() OR buyer_id = auth.uid());
-- keine INSERT/UPDATE/DELETE-Policy → strukturell insert-only

GRANT ALL ON TABLE public.card_listings TO anon, authenticated, service_role;
GRANT ALL ON TABLE public.card_trades   TO anon, authenticated, service_role;

-- Damit "Alle Angebote" auch den Verkäufer-Namen zeigen kann — profiles-RLS
-- blockt sonst private, nicht-öffentliche/nicht-Clan-Profile komplett.
CREATE OR REPLACE FUNCTION public.has_active_listing(p_user_id uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM card_listings WHERE seller_id = p_user_id AND status = 'active'
  );
$$;
GRANT EXECUTE ON FUNCTION public.has_active_listing(uuid) TO anon, authenticated, service_role;

CREATE POLICY "profiles_read_active_sellers" ON public.profiles
  FOR SELECT USING (public.has_active_listing(id));

-- ═══════════════════════════════════════════════════
-- 3. RPC: create_listing(p_card_id, p_price_diamonds)
-- ═══════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.create_listing(p_card_id int, p_price_diamonds int)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_card_id uuid;
  v_listing_id   uuid;
BEGIN
  IF p_price_diamonds IS NULL OR p_price_diamonds <= 0 OR p_price_diamonds > 9999 THEN
    RAISE EXCEPTION 'invalid_price';
  END IF;

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

  INSERT INTO card_listings (seller_id, user_card_id, card_id, price_diamonds)
  VALUES (auth.uid(), v_user_card_id, p_card_id, p_price_diamonds)
  RETURNING id INTO v_listing_id;

  RETURN v_listing_id;
END;
$$;
GRANT EXECUTE ON FUNCTION public.create_listing(int, int) TO anon, authenticated, service_role;

-- ═══════════════════════════════════════════════════
-- 4. RPC: cancel_listing(p_listing_id)
-- ═══════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.cancel_listing(p_listing_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Claim-Mutex-Pattern: nur wer den Übergang active→cancelled tatsächlich schafft,
  -- "gewinnt". Läuft parallel gerade buy_listing() und hat die Zeile schon auf
  -- 'sold' gehoben, matcht dieses UPDATE 0 Zeilen → sauberer Fehler statt Race.
  UPDATE card_listings
     SET status = 'cancelled'
   WHERE id = p_listing_id
     AND seller_id = auth.uid()
     AND status = 'active';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'listing_not_cancellable';
  END IF;
END;
$$;
GRANT EXECUTE ON FUNCTION public.cancel_listing(uuid) TO anon, authenticated, service_role;

-- ═══════════════════════════════════════════════════
-- 5. RPC: buy_listing(p_listing_id) — atomarer Kern
-- ═══════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.buy_listing(p_listing_id uuid)
RETURNS int  -- neuer Diamanten-Stand des Käufers
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_listing        card_listings%ROWTYPE;
  v_buyer_id       uuid := auth.uid();
  v_buyer_diamonds int;
  v_new_diamonds   int;
BEGIN
  IF v_buyer_id IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  -- 1) Claim-Mutex: nur wer active→sold schafft, gewinnt das Rennen um dieses
  --    Angebot. 0 Zeilen zurück = Angebot schon verkauft/storniert.
  UPDATE card_listings
     SET status = 'sold', buyer_id = v_buyer_id, sold_at = now()
   WHERE id = p_listing_id
     AND status = 'active'
  RETURNING * INTO v_listing;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'listing_not_available';
  END IF;

  -- 2) Selbstkauf-Schutz
  IF v_listing.seller_id = v_buyer_id THEN
    RAISE EXCEPTION 'cannot_buy_own_listing';
  END IF;

  -- 3) Käufer-Zeile sperren (FOR UPDATE), BEVOR der Kontostand geprüft wird.
  --    Verhindert, dass zwei parallele Käufe desselben Nutzers (zwei Tabs)
  --    beide denselben veralteten Kontostand lesen, beide die Prüfung
  --    bestehen und den Saldo ins Negative treiben.
  SELECT diamonds INTO v_buyer_diamonds
  FROM profiles WHERE id = v_buyer_id FOR UPDATE;

  IF v_buyer_diamonds < v_listing.price_diamonds THEN
    RAISE EXCEPTION 'not_enough_diamonds';
  END IF;

  -- 4) Diamanten-Transfer (kein Sink, keine Gebühr — reiner Transfer)
  UPDATE profiles SET diamonds = diamonds - v_listing.price_diamonds
   WHERE id = v_buyer_id
  RETURNING diamonds INTO v_new_diamonds;

  UPDATE profiles SET diamonds = diamonds + v_listing.price_diamonds
   WHERE id = v_listing.seller_id;

  -- 5) Eigentumsübertragung: dieselbe user_cards-Zeile wechselt den Besitzer
  UPDATE user_cards
     SET user_id = v_buyer_id, obtained_at = now()
   WHERE id = v_listing.user_card_id
     AND user_id = v_listing.seller_id;

  IF NOT FOUND THEN
    -- Sollte durch die UNIQUE-Constraint + Claim-Mutex nie passieren;
    -- harte Absicherung, die die gesamte Transaktion zurückrollt.
    RAISE EXCEPTION 'source_card_missing';
  END IF;

  -- 6) Unveränderliches Audit-Log
  INSERT INTO card_trades (listing_id, seller_id, buyer_id, card_id, user_card_id, price_diamonds)
  VALUES (v_listing.id, v_listing.seller_id, v_buyer_id, v_listing.card_id, v_listing.user_card_id, v_listing.price_diamonds);

  RETURN v_new_diamonds;
END;
$$;
GRANT EXECUTE ON FUNCTION public.buy_listing(uuid) TO anon, authenticated, service_role;

-- ═══════════════════════════════════════════════════
-- 6. sell_card() anpassen: aktiv gelistete Kopien ausschließen
-- ═══════════════════════════════════════════════════
-- Ohne diesen Fix könnte ein Duplikat-Verkauf genau die Kopie löschen, die
-- gerade auf dem Marktplatz aktiv ist — führt zwar wegen buy_listing()s
-- source_card_missing-Guard nicht zu Diamanten-Diebstahl, aber zu einem
-- permanent unverkäuflichen Geister-Angebot.
-- Nebenbei: SET search_path = public fehlte in der bisherigen Version
-- (supabase/sell_card_20260527.sql), im Gegensatz zu draw_card() — hier
-- nachgezogen.

CREATE OR REPLACE FUNCTION public.sell_card(p_card_id int)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rarity text; v_reward int; v_row_id uuid; v_count int; v_new_diamonds int;
BEGIN
  SELECT rarity INTO v_rarity FROM cards WHERE id = p_card_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'card_not_found'; END IF;

  v_reward := CASE v_rarity
    WHEN 'common' THEN 4 WHEN 'rare' THEN 8 WHEN 'epic' THEN 12
    WHEN 'legendary' THEN 16 WHEN 'mystic' THEN 20 ELSE 0
  END;

  SELECT COUNT(*) INTO v_count FROM user_cards WHERE user_id = auth.uid() AND card_id = p_card_id;
  IF v_count < 2 THEN RAISE EXCEPTION 'not_enough_copies'; END IF;

  SELECT id INTO v_row_id
  FROM user_cards
  WHERE user_id = auth.uid() AND card_id = p_card_id
    AND id NOT IN (SELECT user_card_id FROM card_listings WHERE status = 'active')
  ORDER BY obtained_at ASC
  LIMIT 1;

  IF v_row_id IS NULL THEN RAISE EXCEPTION 'all_copies_listed'; END IF;

  DELETE FROM user_cards WHERE id = v_row_id;
  UPDATE profiles SET diamonds = diamonds + v_reward WHERE id = auth.uid() RETURNING diamonds INTO v_new_diamonds;
  RETURN v_new_diamonds;
END;
$$;
