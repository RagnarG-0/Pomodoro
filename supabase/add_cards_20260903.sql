-- Neue Karten (ID 40-43) einfügen
INSERT INTO public.cards (id, name, rarity) VALUES
  (40, 'Richard-von-Volkmann', 'rare'),
  (41, 'James-Tanner', 'common'),
  (42, 'Hans-Curschmann', 'common'),
  (43, 'Steintor-Opa', 'epic')
ON CONFLICT (id) DO NOTHING;
