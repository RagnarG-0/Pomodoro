-- ═══════════════════════════════════════════════════
-- 1. incubator: 'm' (Mystisches Ei) als gültige Farbe zulassen
-- ═══════════════════════════════════════════════════
ALTER TABLE public.incubator DROP CONSTRAINT IF EXISTS incubator_egg_color_check;
ALTER TABLE public.incubator ADD CONSTRAINT incubator_egg_color_check
  CHECK (egg_color IN ('y','b','g','r','m'));

-- ═══════════════════════════════════════════════════
-- 2. draw_card(): Mystic-Modus (nur legendary/mystic, 30/70)
-- ═══════════════════════════════════════════════════
-- Alte 0-Parameter-Signatur entfernen, BEVOR die neue erstellt wird — sonst
-- existieren beide gleichzeitig und PostgREST kann bei einem Aufruf mit
-- leerem Body ({}) nicht mehr eindeutig zwischen draw_card() und
-- draw_card(p_mystic boolean DEFAULT false) entscheiden (PGRST203).
DROP FUNCTION IF EXISTS public.draw_card();

CREATE OR REPLACE FUNCTION public.draw_card(p_mystic boolean DEFAULT false)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_roll    float;
  v_rarity  text;
  v_card_id int;
BEGIN
  v_roll := random();

  IF p_mystic THEN
    -- Mystisches Ei: nur legendary (30%) / mystic (70%)
    IF v_roll < 0.30 THEN v_rarity := 'legendary';
    ELSE                   v_rarity := 'mystic';
    END IF;
  ELSE
    -- Normales Ei: unveränderte Verteilung
    IF    v_roll < 0.40 THEN v_rarity := 'common';
    ELSIF v_roll < 0.70 THEN v_rarity := 'rare';
    ELSIF v_roll < 0.88 THEN v_rarity := 'epic';
    ELSIF v_roll < 0.97 THEN v_rarity := 'legendary';
    ELSE                      v_rarity := 'mystic';
    END IF;
  END IF;

  SELECT id INTO v_card_id
  FROM cards
  WHERE rarity = v_rarity
  ORDER BY random()
  LIMIT 1;

  INSERT INTO user_cards (user_id, card_id)
  VALUES (auth.uid(), v_card_id);

  RETURN v_card_id;
END;
$$;

-- DROP FUNCTION entzieht implizit alle GRANTs — dieser Schritt ist Pflicht.
GRANT EXECUTE ON FUNCTION public.draw_card(boolean) TO anon, authenticated, service_role;
