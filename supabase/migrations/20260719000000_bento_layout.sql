-- Server-seitige Kopie des Bento-Grid-Layouts (index.html, applyCustomBentoLayout()),
-- für Cross-Device-Sync des Layout-Editors. null = noch nie serverseitig gespeichert
-- (Client bleibt dann rein bei localStorage/pomo_bento_layout_v1, kein Auto-Push
-- beim bloßen Login). Struktur: Array<Array<{id, flex, height?}>>, siehe
-- BENTO_TILE_META in index.html — Server validiert die Struktur nicht, das
-- übernimmt clientseitig isValidBentoRows() bei jedem Lesen.
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS bento_layout jsonb;
