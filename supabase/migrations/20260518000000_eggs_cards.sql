-- Phase 1: Eier & Kartensammlung
-- 1. profiles migrieren
-- 2. Neue Tabellen: incubator, cards, user_cards + RLS
-- 3. cards befüllen (21 Einträge)
-- 4. RPC draw_card()
-- 5. Leaderboard-RPCs: awards_last entfernen (Spalte fällt weg)


-- ═══════════════════════════════════════════════════
-- 1. PROFILES MIGRIEREN
-- ═══════════════════════════════════════════════════

ALTER TABLE public.profiles DROP COLUMN IF EXISTS awards_last;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS eggs TEXT NOT NULL DEFAULT '0-0-0-0-0-0-0-0-0-0';


-- ═══════════════════════════════════════════════════
-- 2. NEUE TABELLEN
-- ═══════════════════════════════════════════════════

-- Brutkasten: 1 Slot pro Nutzer, Fortschritt über Fokusminuten
CREATE TABLE IF NOT EXISTS public.incubator (
  user_id                    uuid        PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
  egg_color                  char(1)     NOT NULL CHECK (egg_color IN ('y','b','g','r')),
  placed_at                  timestamptz NOT NULL DEFAULT now(),
  focus_minutes_at_placement int         NOT NULL
);

-- Karten-Stammdaten (hardcoded, kein Netzwerkabruf nötig)
CREATE TABLE IF NOT EXISTS public.cards (
  id     int  PRIMARY KEY,
  name   text NOT NULL,
  rarity text NOT NULL CHECK (rarity IN ('common','rare','epic','legendary','mystic'))
);

-- Gezogene Karten pro Nutzer (Duplikate = mehrere Zeilen)
CREATE TABLE IF NOT EXISTS public.user_cards (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid        NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  card_id     int         NOT NULL REFERENCES public.cards(id),
  obtained_at timestamptz NOT NULL DEFAULT now()
);


-- ═══════════════════════════════════════════════════
-- RLS FÜR NEUE TABELLEN
-- ═══════════════════════════════════════════════════

ALTER TABLE public.incubator  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cards      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_cards ENABLE ROW LEVEL SECURITY;

-- incubator: Nutzer liest/schreibt nur eigene Zeile
CREATE POLICY "incubator_own" ON public.incubator
  USING (auth.uid() = user_id);

-- cards: jeder darf lesen (kein Geheimnis)
CREATE POLICY "cards_select_all" ON public.cards
  FOR SELECT USING (true);

-- user_cards: Nutzer sieht nur eigene Karten
-- (INSERT erfolgt ausschließlich via draw_card() SECURITY DEFINER)
CREATE POLICY "user_cards_select_own" ON public.user_cards
  FOR SELECT USING (auth.uid() = user_id);


-- ═══════════════════════════════════════════════════
-- GRANTS FÜR NEUE TABELLEN
-- ═══════════════════════════════════════════════════

GRANT ALL ON TABLE public.incubator  TO anon, authenticated, service_role;
GRANT ALL ON TABLE public.cards      TO anon, authenticated, service_role;
GRANT ALL ON TABLE public.user_cards TO anon, authenticated, service_role;


-- ═══════════════════════════════════════════════════
-- 3. CARDS BEFÜLLEN (21 Einträge)
-- ═══════════════════════════════════════════════════

INSERT INTO public.cards (id, name, rarity) VALUES
  (1,  'FSr-Mitglied',          'common'),
  (2,  'Glutenboykottierer',    'common'),
  (3,  'Histotutor',            'common'),
  (4,  'M1Schwitzer',           'common'),
  (5,  'Skillslabschauspieler', 'common'),
  (6,  'Soziologiestudent-in',  'common'),
  (7,  'Warmduscher',           'common'),
  (8,  'Anki-Controler-User',   'rare'),
  (9,  'Biochemietrader',       'rare'),
  (10, 'Mensafrau',             'rare'),
  (11, 'Schwesterrabiata',      'rare'),
  (12, 'gym10duscher',          'rare'),
  (13, 'Medienny',              'epic'),
  (14, 'STHebungsüberseher',    'epic'),
  (15, 'TomS',                  'epic'),
  (16, 'Bibliothek-Schläfer',   'legendary'),
  (17, 'FreundausHarvard',      'legendary'),
  (18, 'glasn',                 'legendary'),
  (19, 'Mediraggy',             'legendary'),
  (20, 'Neurotutor',            'legendary'),
  (21, 'Penig-BG',              'mystic')
ON CONFLICT (id) DO NOTHING;


-- ═══════════════════════════════════════════════════
-- 4. RPC draw_card()
-- ═══════════════════════════════════════════════════

-- Würfelt eine Rarität, wählt eine zufällige Karte daraus,
-- schreibt sie in user_cards und gibt die card_id zurück.
-- Wahrscheinlichkeiten: common 40%, rare 30%, epic 18%, legendary 9%, mystic 3%
CREATE OR REPLACE FUNCTION public.draw_card()
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

  IF    v_roll < 0.40 THEN v_rarity := 'common';
  ELSIF v_roll < 0.70 THEN v_rarity := 'rare';
  ELSIF v_roll < 0.88 THEN v_rarity := 'epic';
  ELSIF v_roll < 0.97 THEN v_rarity := 'legendary';
  ELSE                      v_rarity := 'mystic';
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

GRANT EXECUTE ON FUNCTION public.draw_card() TO anon, authenticated, service_role;


-- ═══════════════════════════════════════════════════
-- 5. LEADERBOARD-RPCs: awards_last entfernen
-- (Spalte wurde oben gedroppt; RPCs müssen aktualisiert werden)
-- ═══════════════════════════════════════════════════

DROP FUNCTION IF EXISTS public.leaderboard_today();
CREATE OR REPLACE FUNCTION public.leaderboard_today()
RETURNS TABLE (
  name            text,
  minutes         int,
  alltime_minutes bigint,
  diamonds        int,
  avatar_url      text,
  timer_active    bool
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  WITH today AS (
    SELECT ((now() AT TIME ZONE 'Europe/Berlin') - interval '4 hours')::date AS d
  )
  SELECT
    p.username,
    sd_today.minutes                                       AS minutes,
    COALESCE((
      SELECT SUM(sd.minutes) FROM study_days sd WHERE sd.user_id = p.id
    ), 0)::bigint                                          AS alltime_minutes,
    COALESCE(p.diamonds, 0),
    p.avatar_url,
    COALESCE((
      SELECT ts.end_at IS NOT NULL AND ts.end_at > now() AND ts.mode = 'work'
      FROM timer_state ts WHERE ts.user_id = p.id LIMIT 1
    ), false)                                              AS timer_active
  FROM profiles p
  CROSS JOIN today
  JOIN study_days sd_today
    ON sd_today.user_id = p.id AND sd_today.date = today.d AND sd_today.minutes > 0
  WHERE p.public = true
    AND p.clan_id = my_clan_id()
  ORDER BY minutes DESC, alltime_minutes DESC;
$$;

GRANT EXECUTE ON FUNCTION public.leaderboard_today() TO anon, authenticated, service_role;


DROP FUNCTION IF EXISTS public.leaderboard_aggregated(date);
CREATE OR REPLACE FUNCTION public.leaderboard_aggregated(date_from date)
RETURNS TABLE (
  name            text,
  minutes         bigint,
  alltime_minutes bigint,
  diamonds        int,
  avatar_url      text,
  timer_active    bool
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT
    p.username,
    COALESCE((
      SELECT SUM(sd.minutes) FROM study_days sd
      WHERE sd.user_id = p.id AND sd.date >= date_from
    ), 0)::bigint                                          AS minutes,
    COALESCE((
      SELECT SUM(sd.minutes) FROM study_days sd WHERE sd.user_id = p.id
    ), 0)::bigint                                          AS alltime_minutes,
    COALESCE(p.diamonds, 0),
    p.avatar_url,
    COALESCE((
      SELECT ts.end_at IS NOT NULL AND ts.end_at > now() AND ts.mode = 'work'
      FROM timer_state ts WHERE ts.user_id = p.id LIMIT 1
    ), false)                                              AS timer_active
  FROM profiles p
  WHERE p.public = true
    AND p.clan_id = my_clan_id()
  ORDER BY minutes DESC, alltime_minutes DESC;
$$;

GRANT EXECUTE ON FUNCTION public.leaderboard_aggregated(date) TO anon, authenticated, service_role;
