-- Neue Karten (ID 35-37) einfügen
INSERT INTO public.cards (id, name, rarity) VALUES
  (35, 'Froschi', 'rare'),
  (36, 'OA-Hagel', 'rare'),
  (37, 'Rebecca-Kabel', 'epic')
ON CONFLICT (id) DO NOTHING;
