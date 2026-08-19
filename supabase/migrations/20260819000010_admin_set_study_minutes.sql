-- Admin: Lernzeit eines Nutzers für einen Tag (i.d.R. heute) direkt auf einen
-- vorgegebenen Minutenwert SETZEN (nicht addieren) — für den Fall, dass ein
-- Nutzer vergessen hat, seinen Timer zu pausieren, und dadurch zu viele
-- Minuten für heute eingetragen bekommen hat. Anders als das Timer-Stop-
-- Feature läuft das NICHT über pending_focus_sessions (das Bestätigungs-
-- Queue-Muster passt für eine direkte Korrektur eines bereits falschen Werts
-- nicht) — direktes, sofortiges Upsert auf study_days.minutes, analog zu
-- add_study_minutes(), nur mit p_user_id-Parameter und SET- statt
-- ADD-Semantik. Siehe CLAUDE.md, Abschnitt "Admin".

-- Username → user_id + aktuelle Tagesminuten, für die Vorschau im
-- Bestätigungsdialog vor dem eigentlichen Setzen. Eigene RPC statt einer
-- reinen profiles?username=eq.X-REST-Suche, weil private Profile
-- (public=false) sonst laut RLS unauffindbar wären — hier admin-gated statt
-- privacy-gated.
CREATE OR REPLACE FUNCTION public.admin_lookup_user_day(p_username text, p_date date)
RETURNS TABLE (user_id uuid, minutes integer)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT p.id, COALESCE(sd.minutes, 0)
  FROM profiles p
  LEFT JOIN study_days sd ON sd.user_id = p.id AND sd.date = p_date
  WHERE p.username = p_username
    AND EXISTS (SELECT 1 FROM profiles me WHERE me.id = auth.uid() AND me.is_admin = true);
$$;

REVOKE EXECUTE ON FUNCTION public.admin_lookup_user_day(text, date) FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_lookup_user_day(text, date) TO authenticated, service_role;
-- REVOKE FROM anon wie beim Timer-Stop-Feature wissentlich wirkungslos
-- (PUBLIC-Default-Grant), funktional unkritisch: auth.uid() ist für anon
-- NULL, der EXISTS-Check matcht dann nie eine is_admin-Zeile.

CREATE OR REPLACE FUNCTION public.admin_set_study_minutes(p_user_id uuid, p_date date, p_minutes integer)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND is_admin = true) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF p_minutes < 0 OR p_minutes > 1440 THEN
    RAISE EXCEPTION 'Invalid minutes';
  END IF;

  INSERT INTO study_days (user_id, date, minutes)
  VALUES (p_user_id, p_date, p_minutes)
  ON CONFLICT (user_id, date) DO UPDATE SET minutes = p_minutes, updated_at = now();

  RETURN p_minutes;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.admin_set_study_minutes(uuid, date, integer) FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_set_study_minutes(uuid, date, integer) TO authenticated, service_role;
