-- Neue Karte (ID 33) einfügen
INSERT INTO public.cards (id, name, rarity) VALUES
  (33, 'Gilbert-Syndrom', 'rare')
ON CONFLICT (id) DO NOTHING;
