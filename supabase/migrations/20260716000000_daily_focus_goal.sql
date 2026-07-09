-- Tagesziel für den Limitless-Balken (updateLimitlessTrack() in index.html).
-- null = noch nicht gesetzt; Client fällt dann auf einen Default von 240 (4h) zurück.
-- Bestimmt die Länge des Balkens relativ zu 12h (720 min) verfügbarer Breite.
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS daily_focus_goal_min integer;
