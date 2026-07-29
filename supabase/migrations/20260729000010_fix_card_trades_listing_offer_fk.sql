-- ═══════════════════════════════════════════════════
-- Fix Teil 2: sell_card() scheitert weiterhin, jetzt an card_listings/
-- trade_offers-FKs von card_trades
-- ═══════════════════════════════════════════════════
-- 20260729000000 hat card_trades.user_card_id auf ON DELETE SET NULL
-- umgestellt. Das DELETE FROM user_cards kaskadiert aber weiter:
--   user_cards --CASCADE--> card_listings --CASCADE--> trade_offers
-- Beide Zwischenschritte werden von card_trades blockiert, das ohne
-- ON DELETE-Klausel (NO ACTION) auf listing_id bzw. trade_offer_id verweist
-- — dieselbe Ursache wie beim ersten Fix, nur eine Ebene tiefer. Reproduziert
-- mit: DELETE FROM user_cards WHERE id = '831f880c-...' -> jetzt Fehler auf
-- "card_trades_listing_id_fkey" (Listing 809f9788-...) statt user_card_id.
--
-- Gleicher Fix wie zuvor: ON DELETE SET NULL, damit die Kaskade durchlaufen
-- kann. card_trades-Zeilen bleiben (Audit-Log wird nie gelöscht), verlieren
-- nur den Bezug zu einem inzwischen weggeräumten Listing/Trade-Offer —
-- card_id/seller_id/buyer_id/traded_at bleiben unverändert aussagekräftig.

ALTER TABLE public.card_trades ALTER COLUMN listing_id DROP NOT NULL;

ALTER TABLE public.card_trades
  DROP CONSTRAINT IF EXISTS card_trades_listing_id_fkey;

ALTER TABLE public.card_trades
  ADD CONSTRAINT card_trades_listing_id_fkey
  FOREIGN KEY (listing_id) REFERENCES public.card_listings(id) ON DELETE SET NULL;

ALTER TABLE public.card_trades
  DROP CONSTRAINT IF EXISTS card_trades_trade_offer_id_fkey;

ALTER TABLE public.card_trades
  ADD CONSTRAINT card_trades_trade_offer_id_fkey
  FOREIGN KEY (trade_offer_id) REFERENCES public.trade_offers(id) ON DELETE SET NULL;
