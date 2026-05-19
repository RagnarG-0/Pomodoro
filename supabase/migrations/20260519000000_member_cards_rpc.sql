-- RPC: Karten eines Clan-Mitglieds abrufen
-- Gibt card_ids zurück — nur wenn Ziel-Nutzer im selben Clan wie der Aufrufer ist.

CREATE OR REPLACE FUNCTION public.get_member_cards(p_username text)
RETURNS TABLE (card_id int)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT uc.card_id
  FROM user_cards uc
  JOIN profiles p ON p.id = uc.user_id
  WHERE p.username  = p_username
    AND p.public    = true
    AND p.clan_id   = my_clan_id()
  ORDER BY uc.obtained_at;
$$;

GRANT EXECUTE ON FUNCTION public.get_member_cards(text) TO anon, authenticated, service_role;
