-- Zweiter Brutkasten-Slot (Kauf 💎30, ab Level 15). incubator hatte bisher
-- nur eine Zeile pro Nutzer (PK user_id) — slot_index erweitert den Schlüssel
-- auf (user_id, slot_index). Bestehende Zeilen werden implizit Slot 1
-- (DEFAULT 1, metadata-only, kein Table-Rewrite). RLS-Policy "incubator_own"
-- prüft nur user_id — unberührt von slot_index.

ALTER TABLE public.incubator
  ADD COLUMN IF NOT EXISTS slot_index int NOT NULL DEFAULT 1 CHECK (slot_index IN (1, 2));

ALTER TABLE public.incubator DROP CONSTRAINT IF EXISTS incubator_pkey;
ALTER TABLE public.incubator ADD CONSTRAINT incubator_pkey PRIMARY KEY (user_id, slot_index);

-- Kaufstatus, permanent (kein erneutes Level-Gating nach Kauf nötig).
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS second_incubator_purchased boolean NOT NULL DEFAULT false;
