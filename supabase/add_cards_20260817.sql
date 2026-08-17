-- Neue Karten (ID 38, 39) einfügen
INSERT INTO public.cards (id, name, rarity) VALUES
  (38, 'Flappe-Peng', 'common'),
  (39, 'Scheinfreier', 'epic')
ON CONFLICT (id) DO NOTHING;
