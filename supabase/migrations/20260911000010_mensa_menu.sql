-- Tagesaktueller Speiseplan der 4 Mensen (Harzmensa, Franckesche
-- Stiftungen, Neuwerk, Tulpe), ausschließlich serverseitig befüllt durch
-- die scrape-mensa-menu Edge Function via pg_cron (siehe
-- 20260911000030_mensa_scrape_cron.sql). Voller Delete+Insert-Replace pro
-- Scrape-Lauf statt Historie — die Tabelle bildet IMMER nur "heute" ab,
-- kein unbeaufsichtigtes Wachstum über die Zeit (siehe CLAUDE.md
-- "Datenbank-Größe / pg_cron-Housekeeping").
CREATE TABLE public.mensa_menu_items (
  id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  mensa_key      text        NOT NULL CHECK (mensa_key IN
                    ('harzmensa', 'franckesche', 'neuwerk', 'tulpe')),
  date           date        NOT NULL,
  dish_name      text        NOT NULL,
  price_student  numeric(5,2),
  price_staff    numeric(5,2),
  price_guest    numeric(5,2),
  badges         text[]      NOT NULL DEFAULT '{}',
  -- Zusatzstoff-/Allergen-Codes aus der "Zusatzstoffe"-Liste je Gericht,
  -- z.B. {'2','A1','A3','G2'}. Codes ab Buchstabe "A" kennzeichnen
  -- glutenhaltiges Getreide (A1 Weizen-, A2 Roggen-, A3 Gersten-,
  -- A4 Hafergluten, ...) — Client markiert solche Gerichte rot, siehe
  -- docs/mensa.md.
  allergen_codes text[]      NOT NULL DEFAULT '{}',
  sort_order     integer     NOT NULL DEFAULT 0,
  scraped_at     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (mensa_key, date, sort_order)
);
CREATE INDEX mensa_menu_items_date_idx ON public.mensa_menu_items (date, mensa_key, sort_order);

ALTER TABLE public.mensa_menu_items ENABLE ROW LEVEL SECURITY;

CREATE POLICY "mensa_menu_items_select" ON public.mensa_menu_items
  FOR SELECT USING (true);

GRANT SELECT ON TABLE public.mensa_menu_items TO anon, authenticated, service_role;
-- Bewusst KEIN INSERT/UPDATE/DELETE-Grant für anon/authenticated — Schreiben
-- ausschließlich über replace_mensa_menu() (SECURITY DEFINER + expliziter
-- service_role-Guard, s.u.).

-- Atomarer Full-Replace: löscht den kompletten bisherigen Inhalt und fügt
-- den neu gescrapten Tag ein — in EINEM Funktionsaufruf, damit kein Client
-- je einen halb geleerten Zwischenzustand sieht. p_items ist ein
-- JSONB-Array wie
-- [{"mensa_key":"harzmensa","dish_name":"...","price_student":3.4,
--   "price_staff":6.3,"price_guest":8.4,"badges":["vegan"],
--   "allergen_codes":["2","A1"],"sort_order":0}, ...]
--
-- WICHTIG: REVOKE EXECUTE ... FROM anon ist in diesem Projekt nachweislich
-- wirkungslos (siehe docs/racetrack.md, verifiziert bei
-- claim_streak_milestone()/draw_card()) — anders als bei jenen Funktionen
-- gibt es hier aber KEINEN natürlichen auth.uid()-Filter, der einen
-- Fremdzugriff harmlos macht (die Funktion schreibt unconditional für
-- ALLE). Deshalb expliziter Rollen-Guard statt nur GRANT/REVOKE (gleiches
-- Muster wie admin_force_stop_timer()).
CREATE OR REPLACE FUNCTION public.replace_mensa_menu(p_date date, p_items jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.role() <> 'service_role' THEN
    RAISE EXCEPTION 'replace_mensa_menu: nur service_role darf schreiben';
  END IF;

  DELETE FROM public.mensa_menu_items;

  INSERT INTO public.mensa_menu_items
    (mensa_key, date, dish_name, price_student, price_staff, price_guest, badges, allergen_codes, sort_order)
  SELECT
    item->>'mensa_key',
    p_date,
    item->>'dish_name',
    NULLIF(item->>'price_student', '')::numeric,
    NULLIF(item->>'price_staff', '')::numeric,
    NULLIF(item->>'price_guest', '')::numeric,
    COALESCE(ARRAY(SELECT jsonb_array_elements_text(item->'badges')), '{}'),
    COALESCE(ARRAY(SELECT jsonb_array_elements_text(item->'allergen_codes')), '{}'),
    COALESCE((item->>'sort_order')::int, 0)
  FROM jsonb_array_elements(p_items) AS item;
END;
$$;

REVOKE ALL ON FUNCTION public.replace_mensa_menu(date, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.replace_mensa_menu(date, jsonb) TO service_role, authenticated, anon;
