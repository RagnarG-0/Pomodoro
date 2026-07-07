-- Limitless (Stoppuhr-)Fokus-Timer: erweitert timer_state um Stoppuhr-Unterstützung.
-- limitless    = true, solange die Zeile eine hochzählende Session repräsentiert
-- started_at   = Startzeitpunkt der aktuell laufenden Phase (Pendant zu end_at bei Countdown); null während Pause
-- credited_min = bereits per Zwischenkredit gutgeschriebene volle Minuten dieser Session
ALTER TABLE public.timer_state
  ADD COLUMN IF NOT EXISTS limitless boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS started_at timestamptz,
  ADD COLUMN IF NOT EXISTS credited_min integer NOT NULL DEFAULT 0;
