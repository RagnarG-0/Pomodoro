-- Aufmerksamkeits-Tracking: append-only Log jedes "Tired"-Klicks. Analog zu
-- pending_focus_sessions, aber ohne UPDATE/DELETE — ein einmal erfasster
-- Tired-Zeitpunkt wird nie mehr verändert oder entfernt.
CREATE TABLE public.tired_events (
  id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  date       date        NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX tired_events_user_idx ON public.tired_events (user_id, created_at);

ALTER TABLE public.tired_events ENABLE ROW LEVEL SECURITY;

CREATE POLICY "tired_events_select" ON public.tired_events
  FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "tired_events_insert" ON public.tired_events
  FOR INSERT WITH CHECK (auth.uid() = user_id);

GRANT SELECT, INSERT ON TABLE public.tired_events TO anon, authenticated, service_role;
