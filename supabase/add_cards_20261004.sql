-- Neue Karte (ID 44) einfügen
INSERT INTO public.cards (id, name, rarity) VALUES
  (44, 'Beatrix-Franz', 'common')
ON CONFLICT (id) DO NOTHING;
