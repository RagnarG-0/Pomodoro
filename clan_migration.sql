-- ═══════════════════════════════════════════════════
-- Clan-Migration: Schwitzende Verbindung Halle
-- Im Supabase SQL-Editor ausführen
-- ═══════════════════════════════════════════════════

-- 1. clans-Tabelle
CREATE TABLE IF NOT EXISTS public.clans (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name          text UNIQUE NOT NULL,
  leader_id     uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  min_focus_min int  NOT NULL DEFAULT 1,
  max_focus_min int  NOT NULL DEFAULT 300,
  level_config  jsonb,
  created_at    timestamptz DEFAULT now()
);
ALTER TABLE public.clans ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "clans_select_auth"    ON public.clans;
DROP POLICY IF EXISTS "clans_update_leader"  ON public.clans;
CREATE POLICY "clans_select_auth"   ON public.clans FOR SELECT TO authenticated USING (true);
CREATE POLICY "clans_update_leader" ON public.clans FOR UPDATE TO authenticated USING (auth.uid() = leader_id);

-- 2. clan_requests-Tabelle
CREATE TABLE IF NOT EXISTS public.clan_requests (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  clan_id    uuid NOT NULL REFERENCES public.clans(id) ON DELETE CASCADE,
  user_id    uuid NOT NULL REFERENCES auth.users(id)   ON DELETE CASCADE,
  status     text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','accepted','rejected')),
  created_at timestamptz DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS clan_requests_pending_unique
  ON public.clan_requests (clan_id, user_id) WHERE status = 'pending';
ALTER TABLE public.clan_requests ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "clan_requests_insert" ON public.clan_requests;
DROP POLICY IF EXISTS "clan_requests_select" ON public.clan_requests;
CREATE POLICY "clan_requests_insert" ON public.clan_requests FOR INSERT TO authenticated
  WITH CHECK (auth.uid() = user_id);
CREATE POLICY "clan_requests_select" ON public.clan_requests FOR SELECT TO authenticated
  USING (
    auth.uid() = user_id OR
    clan_id IN (SELECT id FROM public.clans WHERE leader_id = auth.uid())
  );

-- 3. Spalten zu profiles hinzufügen
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS clan_id   uuid REFERENCES public.clans(id) ON DELETE SET NULL;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS clan_role text CHECK (clan_role IN ('leader','member'));

-- 4. RPC: respond_to_clan_request
CREATE OR REPLACE FUNCTION public.respond_to_clan_request(p_request_id uuid, p_accept boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_clan_id uuid;
  v_user_id uuid;
BEGIN
  SELECT clan_id, user_id INTO v_clan_id, v_user_id
    FROM clan_requests WHERE id = p_request_id AND status = 'pending';
  IF NOT FOUND THEN RAISE EXCEPTION 'Request not found or already processed'; END IF;
  IF NOT EXISTS (SELECT 1 FROM clans WHERE id = v_clan_id AND leader_id = auth.uid()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  UPDATE clan_requests
    SET status = CASE WHEN p_accept THEN 'accepted' ELSE 'rejected' END
    WHERE id = p_request_id;
  IF p_accept THEN
    UPDATE profiles SET clan_id = v_clan_id, clan_role = 'member' WHERE id = v_user_id;
  END IF;
END; $$;

-- 5. RPC: remove_clan_member
CREATE OR REPLACE FUNCTION public.remove_clan_member(p_user_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_clan_id uuid;
BEGIN
  SELECT clan_id INTO v_clan_id FROM profiles WHERE id = auth.uid();
  IF NOT EXISTS (SELECT 1 FROM clans WHERE id = v_clan_id AND leader_id = auth.uid()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF p_user_id = auth.uid() THEN RAISE EXCEPTION 'Cannot remove yourself'; END IF;
  UPDATE profiles SET clan_id = NULL, clan_role = NULL
    WHERE id = p_user_id AND clan_id = v_clan_id;
END; $$;

-- 6. Clan anlegen (mit aktueller Level-Liste)
INSERT INTO public.clans (name, leader_id, min_focus_min, max_focus_min, level_config)
VALUES (
  'Schwitzende Verbindung Halle',
  '1ecb3c26-1fc7-4616-96b9-3d657365052b',
  1, 300,
  '[
    {"name":"Level 1",  "label":"They/Them",                  "icon":"🧊","minMinutes":0},
    {"name":"Level 2",  "label":"Soziologiestudent",           "icon":"🧊","minMinutes":300},
    {"name":"Level 3",  "label":"Awareness-Seminarleiter",     "icon":"🧊","minMinutes":600},
    {"name":"Level 4",  "label":"Bunter Nagellack",            "icon":"🧊","minMinutes":900},
    {"name":"Level 5",  "label":"FSR-Mitglied",                "icon":"🧊","minMinutes":1500},
    {"name":"Level 6",  "label":"Warmduscher",                 "icon":"🛋️","minMinutes":2100},
    {"name":"Level 7",  "label":"Mensa-Frau",                  "icon":"🛋️","minMinutes":3000},
    {"name":"Level 8",  "label":"Histo-Tutor",                 "icon":"🛋️","minMinutes":3900},
    {"name":"Level 9",  "label":"Gym10-Duscher ohne Latschen", "icon":"🛋️","minMinutes":4800},
    {"name":"Level 10", "label":"Skillslab-Schauspieler",      "icon":"🛋️","minMinutes":6000},
    {"name":"Level 11", "label":"Anki-Controller-Besitzer",    "icon":"🔥","minMinutes":7800},
    {"name":"Level 12", "label":"Transportdienst UKH",         "icon":"🔥","minMinutes":9600},
    {"name":"Level 13", "label":"Präp-Tutor",                  "icon":"🔥","minMinutes":12000},
    {"name":"Level 14", "label":"Doktorand",                   "icon":"🔥","minMinutes":14400},
    {"name":"Level 15", "label":"Peter Hippe",                 "icon":"🔥","minMinutes":17400},
    {"name":"Level 16", "label":"Löwe",                        "icon":"🦁","minMinutes":21000},
    {"name":"Level 17", "label":"Daniel Fister",               "icon":"🦁","minMinutes":25200},
    {"name":"Level 18", "label":"Schwester Rabiata",           "icon":"🦁","minMinutes":30000},
    {"name":"Level 19", "label":"Oberarzt Hagel",              "icon":"🦁","minMinutes":35400},
    {"name":"Level 20", "label":"Penig-Bürgermeister",         "icon":"🦁","minMinutes":41400},
    {"name":"Level 21", "label":"Monster White - Abonnent",    "icon":"👑","minMinutes":45000},
    {"name":"Level 22", "label":"ST-Hebungsüberseher",         "icon":"👑","minMinutes":49200},
    {"name":"Level 23", "label":"Koffein-Tablette",            "icon":"👑","minMinutes":54000},
    {"name":"Level 24", "label":"Beta-GPC-Konsument",          "icon":"👑","minMinutes":58800},
    {"name":"Level 25", "label":"Pomodoro-Messi",              "icon":"👑","minMinutes":63000}
  ]'::jsonb
);

-- 7. Ragnar als Leader setzen
UPDATE public.profiles
SET clan_id   = (SELECT id FROM public.clans WHERE name = 'Schwitzende Verbindung Halle'),
    clan_role = 'leader'
WHERE id = '1ecb3c26-1fc7-4616-96b9-3d657365052b';

-- 8. Alle anderen öffentlichen Nutzer als Member hinzufügen
UPDATE public.profiles
SET clan_id   = (SELECT id FROM public.clans WHERE name = 'Schwitzende Verbindung Halle'),
    clan_role = 'member'
WHERE public = true
  AND id != '1ecb3c26-1fc7-4616-96b9-3d657365052b'
  AND clan_id IS NULL;
