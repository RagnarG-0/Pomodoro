-- ═══════════════════════════════════════════════════
-- Fix: sell_card() scheitert an card_trades FK für getauschte Karten
-- ═══════════════════════════════════════════════════
-- respond_to_trade_offer() überträgt eine Karte per UPDATE user_cards.user_id
-- (kein Re-Insert) — dieselbe physische user_cards-Zeile bleibt bestehen und
-- wird in card_trades.user_card_id verewigt. sell_card() filtert beim Löschen
-- nur aktiv gelistete Kopien aus, nicht bereits getauschte — das DELETE
-- scheitert dann an "card_trades_user_card_id_fkey" (23503), da die
-- ursprüngliche FK ohne ON DELETE-Klausel (NO ACTION) angelegt wurde.
--
-- Fix: ON DELETE SET NULL. card_trades bleibt als Audit-Log unverändert
-- (Zeile wird nie gelöscht), verliert beim Verkauf der referenzierten Kopie
-- nur den Bezug zur konkreten physischen Karte — card_id/seller_id/buyer_id/
-- traded_at bleiben vollständig aussagekräftig.

ALTER TABLE public.card_trades ALTER COLUMN user_card_id DROP NOT NULL;

ALTER TABLE public.card_trades
  DROP CONSTRAINT card_trades_user_card_id_fkey;

ALTER TABLE public.card_trades
  ADD CONSTRAINT card_trades_user_card_id_fkey
  FOREIGN KEY (user_card_id) REFERENCES public.user_cards(id) ON DELETE SET NULL;
