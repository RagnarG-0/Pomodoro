-- Fix: replace_mensa_menu() schlug live fehl mit
-- "DELETE requires a WHERE clause" (SQLSTATE 21000) — dieses Supabase-
-- Projekt lehnt unqualifizierte DELETE-Statements auf Tabellen offenbar ab
-- (Sicherheitsvorkehrung gegen versehentliches Leeren ganzer Tabellen).
-- `DELETE FROM public.mensa_menu_items;` (ohne WHERE) wird durch
-- `WHERE date <= p_date` ersetzt — funktional weiterhin ein Full-Replace
-- für den aktuellen Scrape-Tag, räumt zusätzlich liegen gebliebene ältere
-- Zeilen aus einem vorherigen fehlgeschlagenen Lauf mit auf.
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

  DELETE FROM public.mensa_menu_items WHERE date <= p_date;

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
