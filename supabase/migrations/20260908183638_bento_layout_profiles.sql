-- Bis zu 5 benannte, speicherbare Bento-Layout-Profile pro Nutzer (Cross-
-- Device-Sync, additiv/getrennt von bento_layout, siehe index.html
-- reconcileBentoProfiles()/persistBentoState()). Struktur:
-- { activeId: string|null, profiles: [{ id, name, rows, removed }, ...] },
-- max. 5 Einträge. Server validiert Struktur/Anzahl nicht (wie bento_layout)
-- — clientseitig via sanitizeBentoProfiles() bei jedem Lesen durchgesetzt.
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS bento_layout_profiles jsonb;
