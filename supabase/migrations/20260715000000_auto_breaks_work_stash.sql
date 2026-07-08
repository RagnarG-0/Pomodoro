-- Automatische Pausen (Limitless, Opt-in-Einstellung): der Fokus-Timer wird
-- beim Wechsel zur Pause nicht mehr verworfen, sondern pausiert und danach
-- an derselben Stelle fortgesetzt. timer_state hat aber nur eine Zeile pro
-- Nutzer (PK user_id) und kann nicht gleichzeitig "Pause läuft" UND "Fokus
-- pausiert bei X" abbilden — diese stash_*-Spalten halten den pausierten
-- Fokus-Zustand parallel zur aktiven Pause. Anwesenheit eines Stash wird
-- über stash_paused_remaining IS NOT NULL erkannt (analog zu
-- paused_remaining für den aktiven Timer).

ALTER TABLE public.timer_state
  ADD COLUMN IF NOT EXISTS stash_total_sec integer,
  ADD COLUMN IF NOT EXISTS stash_paused_remaining integer,
  ADD COLUMN IF NOT EXISTS stash_limitless boolean,
  ADD COLUMN IF NOT EXISTS stash_pomoday date,
  ADD COLUMN IF NOT EXISTS stash_credited_min integer;
