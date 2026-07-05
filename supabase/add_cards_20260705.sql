-- Neue Karte (ID 34) einfügen
INSERT INTO public.cards (id, name, rarity) VALUES
  (34, 'UKH-Transport', 'rare')
ON CONFLICT (id) DO NOTHING;
