-- Neue Karten (IDs 22–28) einfügen
INSERT INTO public.cards (id, name, rarity) VALUES
  (22, 'Ersti',             'common'),
  (23, 'Bubbletrinker',     'rare'),
  (24, 'Juri-Gänger',       'rare'),
  (25, 'Party-Löwe',        'rare'),
  (26, 'Performative Male', 'rare'),
  (27, 'Sozialist',         'rare'),
  (28, 'Team-Leader',       'rare')
ON CONFLICT (id) DO NOTHING;
