-- Vergessene Limitless-Timer: statt eine 3h+ ohne manuelle Interaktion
-- durchgelaufene (oder über die 4-Uhr-Grenze gelaufene) Fokus-Session
-- stillschweigend zu kreditieren, wird sie zwischengespeichert und muss vom
-- Nutzer aktiv bestätigt ("Gutschreiben") oder verworfen ("Löschen") werden.
-- Siehe CLAUDE.md, Abschnitt "Vergessene Limitless-Timer".

-- Zeitpunkt des letzten MANUELLEN Play-Klicks/Mode-Wechsels in einer
-- limitless=true-Work-Session. Bleibt über automatische Pausen-Zyklen
-- (interruptWorkForBreak(true), Auto-Resume via workStash) unverändert
-- stehen — nur ein echter Präsenznachweis setzt ihn neu.
ALTER TABLE public.timer_state
  ADD COLUMN IF NOT EXISTS unbroken_since timestamptz;

CREATE TABLE public.pending_focus_sessions (
  id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  date       date        NOT NULL,
  minutes    integer     NOT NULL CHECK (minutes > 0),
  label      text,
  reason     text        NOT NULL CHECK (reason IN ('idle_3h', 'day_boundary')),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX pending_focus_sessions_user_idx ON public.pending_focus_sessions (user_id, created_at);

ALTER TABLE public.pending_focus_sessions ENABLE ROW LEVEL SECURITY;

-- Kein UPDATE nötig — Claim-Mutex ist DELETE ... RETURNING *, wie überall
-- sonst in dieser Codebase (clearTimerState(), cancel_listing(), etc.).
-- INSERT durch den Client selbst ist erlaubt: der Client kann heute schon
-- über add_study_minutes()/pomodoro_sessions beliebige Minuten auf beliebige
-- eigene Tage schreiben, ein Client-INSERT hier öffnet also keine neue
-- Angriffsfläche gegenüber dem bestehenden Vertrauensmodell.
CREATE POLICY "pending_focus_sessions_select" ON public.pending_focus_sessions
  FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "pending_focus_sessions_insert" ON public.pending_focus_sessions
  FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY "pending_focus_sessions_delete" ON public.pending_focus_sessions
  FOR DELETE USING (auth.uid() = user_id);

GRANT SELECT, INSERT, DELETE ON TABLE public.pending_focus_sessions TO anon, authenticated, service_role;
