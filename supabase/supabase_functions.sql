-- Supabase — Funktionen, Tabellen & Policies
-- Letzte Änderung: 2026-05-14
-- Alle RPCs: SECURITY DEFINER, search_path = public


-- ═══════════════════════════════════════════════════
-- TABELLEN
-- ═══════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.clans (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  name          text        UNIQUE NOT NULL,
  leader_id     uuid        REFERENCES auth.users(id) ON DELETE SET NULL,
  min_focus_min int         NOT NULL DEFAULT 1,
  max_focus_min int         NOT NULL DEFAULT 300,
  level_config  jsonb,
  created_at    timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.clan_requests (
  id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  clan_id    uuid        NOT NULL REFERENCES public.clans(id) ON DELETE CASCADE,
  user_id    uuid        NOT NULL REFERENCES auth.users(id)   ON DELETE CASCADE,
  status     text        NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','accepted','rejected')),
  created_at timestamptz DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS clan_requests_pending_unique
  ON public.clan_requests (clan_id, user_id) WHERE status = 'pending';

-- profiles-Erweiterungen
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS clan_id         uuid REFERENCES public.clans(id) ON DELETE SET NULL;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS clan_role       text CHECK (clan_role IN ('leader','member'));
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS label_focus_mins jsonb NOT NULL DEFAULT '{}'::jsonb;

CREATE TABLE IF NOT EXISTS pomodoro_sessions (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id          uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  date             date        NOT NULL,
  label            text        NOT NULL DEFAULT 'not specified',
  duration_minutes integer     NOT NULL DEFAULT 25,
  created_at       timestamptz DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_pomo_sessions_user_date
  ON pomodoro_sessions(user_id, date);


-- ═══════════════════════════════════════════════════
-- RLS
-- ═══════════════════════════════════════════════════

ALTER TABLE public.clans          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.clan_requests  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pomodoro_sessions ENABLE ROW LEVEL SECURITY;

-- clans
DROP POLICY IF EXISTS "clans_select_auth"   ON public.clans;
DROP POLICY IF EXISTS "clans_update_leader" ON public.clans;
CREATE POLICY "clans_select_auth"   ON public.clans FOR SELECT TO authenticated USING (true);
CREATE POLICY "clans_update_leader" ON public.clans FOR UPDATE TO authenticated USING (auth.uid() = leader_id);

-- clan_requests
DROP POLICY IF EXISTS "clan_requests_insert" ON public.clan_requests;
DROP POLICY IF EXISTS "clan_requests_select" ON public.clan_requests;
CREATE POLICY "clan_requests_insert" ON public.clan_requests FOR INSERT TO authenticated
  WITH CHECK (auth.uid() = user_id);
CREATE POLICY "clan_requests_select" ON public.clan_requests FOR SELECT TO authenticated
  USING (
    auth.uid() = user_id OR
    clan_id IN (SELECT id FROM public.clans WHERE leader_id = auth.uid())
  );

-- pomodoro_sessions
CREATE POLICY "Users can view own sessions"   ON pomodoro_sessions FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "Users can insert own sessions" ON pomodoro_sessions FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Users can update own sessions" ON pomodoro_sessions FOR UPDATE USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

-- profiles
CREATE POLICY "profiles_read_own" ON public.profiles
  FOR SELECT TO authenticated USING (id = auth.uid());

-- Clan-Peers lesen (nutzt my_clan_id() um Rekursion zu vermeiden)
DROP POLICY IF EXISTS "profiles_read_clan_peers" ON public.profiles;
CREATE POLICY "profiles_read_clan_peers" ON public.profiles
  FOR SELECT TO authenticated
  USING (clan_id IS NOT NULL AND clan_id = public.my_clan_id());


-- ═══════════════════════════════════════════════════
-- HILFSFUNKTIONEN
-- ═══════════════════════════════════════════════════

-- Gibt die clan_id des aufrufenden Nutzers zurück.
-- SECURITY DEFINER verhindert rekursiven Loop beim Lesen von profiles.
CREATE OR REPLACE FUNCTION public.my_clan_id()
RETURNS uuid
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT clan_id FROM profiles WHERE id = auth.uid();
$$;


-- ═══════════════════════════════════════════════════
-- LERNZEIT
-- ═══════════════════════════════════════════════════

-- Addiert delta auf study_days (nicht idempotent!).
-- Nur über das Claim-Mutex in clearTimerState aufrufen.
CREATE OR REPLACE FUNCTION add_study_minutes(p_date date, p_minutes int)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  INSERT INTO study_days (user_id, date, minutes)
  VALUES (auth.uid(), p_date, p_minutes)
  ON CONFLICT (user_id, date) DO UPDATE
    SET minutes = study_days.minutes + EXCLUDED.minutes;
$$;


-- ═══════════════════════════════════════════════════
-- LABEL-STATISTIKEN
-- ═══════════════════════════════════════════════════

-- Gibt je Label: Minuten heute / diese Woche / diesen Monat / gesamt.
DROP FUNCTION IF EXISTS get_label_stats(uuid);
CREATE OR REPLACE FUNCTION get_label_stats(p_user_id uuid)
RETURNS TABLE(
  label           text,
  today_minutes   bigint,
  week_minutes    bigint,
  month_minutes   bigint,
  alltime_minutes bigint
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    ps.label,
    COALESCE(SUM(CASE WHEN ps.date = CURRENT_DATE
                      THEN ps.duration_minutes ELSE 0 END), 0)::bigint AS today_minutes,
    COALESCE(SUM(CASE WHEN ps.date >= CURRENT_DATE - 6
                      THEN ps.duration_minutes ELSE 0 END), 0)::bigint AS week_minutes,
    COALESCE(SUM(CASE WHEN ps.date >= date_trunc('month', CURRENT_DATE)::date
                      THEN ps.duration_minutes ELSE 0 END), 0)::bigint AS month_minutes,
    COALESCE(SUM(ps.duration_minutes), 0)::bigint                      AS alltime_minutes
  FROM pomodoro_sessions ps
  WHERE ps.user_id = p_user_id
  GROUP BY ps.label
  ORDER BY alltime_minutes DESC;
$$;


-- ═══════════════════════════════════════════════════
-- LEADERBOARD
-- ═══════════════════════════════════════════════════

-- Tages-Rangliste: nur Clan-Mitglieder mit > 0 Minuten heute.
-- Tagesgrenze: 04:00 Uhr Berliner Zeit.
DROP FUNCTION IF EXISTS leaderboard_today();
CREATE OR REPLACE FUNCTION leaderboard_today()
RETURNS TABLE (
  name            text,
  minutes         int,
  alltime_minutes bigint,
  diamonds        int,
  awards_last     int,
  avatar_url      text,
  timer_active    bool
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  WITH today AS (
    SELECT ((now() AT TIME ZONE 'Europe/Berlin') - interval '4 hours')::date AS d
  )
  SELECT
    p.username,
    sd_today.minutes                                       AS minutes,
    COALESCE((
      SELECT SUM(sd.minutes) FROM study_days sd WHERE sd.user_id = p.id
    ), 0)::bigint                                          AS alltime_minutes,
    COALESCE(p.diamonds, 0),
    COALESCE(p.awards_last, 0),
    p.avatar_url,
    COALESCE((
      SELECT ts.end_at IS NOT NULL AND ts.end_at > now() AND ts.mode = 'work'
      FROM timer_state ts WHERE ts.user_id = p.id LIMIT 1
    ), false)                                              AS timer_active
  FROM profiles p
  CROSS JOIN today
  JOIN study_days sd_today
    ON sd_today.user_id = p.id AND sd_today.date = today.d AND sd_today.minutes > 0
  WHERE p.public = true
    AND p.clan_id = my_clan_id()
  ORDER BY minutes DESC, alltime_minutes DESC;
$$;

-- Zeitraum-Rangliste (Woche / Monat / All Time).
-- minutes = Summe ab date_from; alltime_minutes immer Gesamtsumme (für Level-Anzeige).
DROP FUNCTION IF EXISTS leaderboard_aggregated(date);
CREATE OR REPLACE FUNCTION leaderboard_aggregated(date_from date)
RETURNS TABLE (
  name            text,
  minutes         bigint,
  alltime_minutes bigint,
  diamonds        int,
  awards_last     int,
  avatar_url      text,
  timer_active    bool
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT
    p.username,
    COALESCE((
      SELECT SUM(sd.minutes) FROM study_days sd
      WHERE sd.user_id = p.id AND sd.date >= date_from
    ), 0)::bigint                                          AS minutes,
    COALESCE((
      SELECT SUM(sd.minutes) FROM study_days sd WHERE sd.user_id = p.id
    ), 0)::bigint                                          AS alltime_minutes,
    COALESCE(p.diamonds, 0),
    COALESCE(p.awards_last, 0),
    p.avatar_url,
    COALESCE((
      SELECT ts.end_at IS NOT NULL AND ts.end_at > now() AND ts.mode = 'work'
      FROM timer_state ts WHERE ts.user_id = p.id LIMIT 1
    ), false)                                              AS timer_active
  FROM profiles p
  WHERE p.public = true
    AND p.clan_id = my_clan_id()
  ORDER BY minutes DESC, alltime_minutes DESC;
$$;

-- Gestrigen Tagessieger aus dem eigenen Clan.
DROP FUNCTION IF EXISTS get_yesterday_winner();
CREATE OR REPLACE FUNCTION get_yesterday_winner()
RETURNS text
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  WITH yesterday AS (
    SELECT ((now() AT TIME ZONE 'Europe/Berlin') - interval '4 hours')::date - 1 AS d
  )
  SELECT p.username
  FROM study_days sd
  CROSS JOIN yesterday
  JOIN profiles p ON p.id = sd.user_id
  WHERE sd.date = yesterday.d
    AND p.public = true
    AND p.clan_id = my_clan_id()
  ORDER BY sd.minutes DESC
  LIMIT 1;
$$;


-- ═══════════════════════════════════════════════════
-- TÄGLICHE AWARDS (pg_cron: 01:59 UTC = ~03:59 Berliner Zeit)
-- Schutzregel: Top-3-Plätze bekommen KEINE Klorolle.
-- Klorolle nur wenn > 3 Teilnehmer mit echten Minuten (> 0).
-- ═══════════════════════════════════════════════════

-- Im Supabase SQL Editor ausführen:
select cron.unschedule('daily-winners');
select cron.schedule(
  'daily-winners',
  '59 1 * * *',
  $$
    with today_de as (
      select case
        when extract(hour from now() at time zone 'Europe/Berlin') < 4
        then (now() at time zone 'Europe/Berlin')::date - 1
        else (now() at time zone 'Europe/Berlin')::date
      end as d
    ),
    ranked as (
      select
        p.id as user_id, p.username,
        sum(s.minutes)::integer as minutes,
        row_number() over (order by sum(s.minutes) desc, random()) as rn
      from study_days s
      join profiles p on p.id = s.user_id
      cross join today_de
      where s.date = today_de.d
        and p.public is true
        and s.off is not true
        and s.minutes > 0
      group by p.id, p.username
    ),
    inserted as (
      insert into daily_winners (date, rank, user_id, username, minutes)
      select (select d from today_de), rn, user_id, username, minutes
      from ranked where rn <= 3
      on conflict (date, rank) do nothing
      returning user_id, rank
    )
    update profiles p set
      diamonds = diamonds + case i.rank when 1 then 3 when 2 then 2 when 3 then 1 end
    from inserted i
    where p.id = i.user_id
      and (select d from today_de) >= '2026-05-04';
  $$
);


-- ═══════════════════════════════════════════════════
-- CLAN-RPCS
-- ═══════════════════════════════════════════════════

-- Mitglieder des eigenen Clans abrufen.
CREATE OR REPLACE FUNCTION public.get_clan_members()
RETURNS TABLE(id uuid, username text, clan_role text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_clan_id uuid;
BEGIN
  SELECT clan_id INTO v_clan_id FROM profiles WHERE id = auth.uid();
  IF v_clan_id IS NULL THEN RETURN; END IF;
  RETURN QUERY
    SELECT p.id, p.username, p.clan_role
    FROM profiles p
    WHERE p.clan_id = v_clan_id
    ORDER BY p.username;
END;
$$;

-- Beitrittsanfrage bestätigen oder ablehnen (nur Leader).
CREATE OR REPLACE FUNCTION public.respond_to_clan_request(p_request_id uuid, p_accept boolean)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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
END;
$$;

-- Mitglied aus dem Clan entfernen (nur Leader).
CREATE OR REPLACE FUNCTION public.remove_clan_member(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_clan_id uuid;
BEGIN
  SELECT clan_id INTO v_clan_id FROM profiles WHERE id = auth.uid();
  IF NOT EXISTS (SELECT 1 FROM clans WHERE id = v_clan_id AND leader_id = auth.uid()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF p_user_id = auth.uid() THEN RAISE EXCEPTION 'Cannot remove yourself'; END IF;
  UPDATE profiles SET clan_id = NULL, clan_role = NULL
    WHERE id = p_user_id AND clan_id = v_clan_id;
END;
$$;

-- Neuen Clan erstellen; Ersteller wird automatisch Leader.
CREATE OR REPLACE FUNCTION create_clan(p_name text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_clan_id uuid;
BEGIN
  IF EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND clan_id IS NOT NULL) THEN
    RAISE EXCEPTION 'already_in_clan';
  END IF;
  INSERT INTO clans (name, leader_id) VALUES (p_name, auth.uid()) RETURNING id INTO v_clan_id;
  UPDATE profiles SET clan_id = v_clan_id, clan_role = 'leader' WHERE id = auth.uid();
  RETURN v_clan_id;
END;
$$;

-- Beitrittsanfrage an einen bestimmten Clan senden.
CREATE OR REPLACE FUNCTION submit_join_request_to(p_clan_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND clan_id IS NOT NULL) THEN
    RAISE EXCEPTION 'already_in_clan';
  END IF;
  IF EXISTS (
    SELECT 1 FROM clan_requests
    WHERE user_id = auth.uid() AND clan_id = p_clan_id AND status = 'pending'
  ) THEN RETURN; END IF;
  INSERT INTO clan_requests (clan_id, user_id, status) VALUES (p_clan_id, auth.uid(), 'pending');
END;
$$;

-- Automatisch dem einzigen vorhandenen Clan beitreten (Fallback für neue Nutzer).
CREATE OR REPLACE FUNCTION public.submit_join_request()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_clan_id uuid;
BEGIN
  IF EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND clan_id IS NOT NULL) THEN RETURN; END IF;
  SELECT id INTO v_clan_id FROM clans LIMIT 1;
  IF NOT FOUND THEN RETURN; END IF;
  INSERT INTO clan_requests (clan_id, user_id) VALUES (v_clan_id, auth.uid()) ON CONFLICT DO NOTHING;
END;
$$;


-- ═══════════════════════════════════════════════════
-- EINMALIGE DATENMIGRATION (bereits ausgeführt)
-- ═══════════════════════════════════════════════════

-- Clan „Schwitzende Verbindung Halle" anlegen
-- INSERT INTO public.clans (name, leader_id, min_focus_min, max_focus_min, level_config)
-- VALUES (
--   'Schwitzende Verbindung Halle',
--   '1ecb3c26-1fc7-4616-96b9-3d657365052b',
--   1, 300,
--   '[
--     {"name":"Level 1",  "label":"They/Them",                  "icon":"🧊","minMinutes":0},
--     {"name":"Level 2",  "label":"Soziologiestudent",           "icon":"🧊","minMinutes":300},
--     {"name":"Level 3",  "label":"Awareness-Seminarleiter",     "icon":"🧊","minMinutes":600},
--     {"name":"Level 4",  "label":"Bunter Nagellack",            "icon":"🧊","minMinutes":900},
--     {"name":"Level 5",  "label":"FSR-Mitglied",                "icon":"🧊","minMinutes":1500},
--     {"name":"Level 6",  "label":"Warmduscher",                 "icon":"🛋️","minMinutes":2100},
--     {"name":"Level 7",  "label":"Mensa-Frau",                  "icon":"🛋️","minMinutes":3000},
--     {"name":"Level 8",  "label":"Histo-Tutor",                 "icon":"🛋️","minMinutes":3900},
--     {"name":"Level 9",  "label":"Gym10-Duscher ohne Latschen", "icon":"🛋️","minMinutes":4800},
--     {"name":"Level 10", "label":"Skillslab-Schauspieler",      "icon":"🛋️","minMinutes":6000},
--     {"name":"Level 11", "label":"Anki-Controller-Besitzer",    "icon":"🔥","minMinutes":7800},
--     {"name":"Level 12", "label":"Transportdienst UKH",         "icon":"🔥","minMinutes":9600},
--     {"name":"Level 13", "label":"Präp-Tutor",                  "icon":"🔥","minMinutes":12000},
--     {"name":"Level 14", "label":"Doktorand",                   "icon":"🔥","minMinutes":14400},
--     {"name":"Level 15", "label":"Peter Hippe",                 "icon":"🔥","minMinutes":17400},
--     {"name":"Level 16", "label":"Löwe",                        "icon":"🦁","minMinutes":21000},
--     {"name":"Level 17", "label":"Daniel Fister",               "icon":"🦁","minMinutes":25200},
--     {"name":"Level 18", "label":"Schwester Rabiata",           "icon":"🦁","minMinutes":30000},
--     {"name":"Level 19", "label":"Oberarzt Hagel",              "icon":"🦁","minMinutes":35400},
--     {"name":"Level 20", "label":"Penig-Bürgermeister",         "icon":"🦁","minMinutes":41400},
--     {"name":"Level 21", "label":"Monster White - Abonnent",    "icon":"👑","minMinutes":45000},
--     {"name":"Level 22", "label":"ST-Hebungsüberseher",         "icon":"👑","minMinutes":49200},
--     {"name":"Level 23", "label":"Koffein-Tablette",            "icon":"👑","minMinutes":54000},
--     {"name":"Level 24", "label":"Beta-GPC-Konsument",          "icon":"👑","minMinutes":58800},
--     {"name":"Level 25", "label":"Pomodoro-Messi",              "icon":"👑","minMinutes":63000}
--   ]'::jsonb
-- );

-- Ragnar als Leader setzen
-- UPDATE public.profiles
-- SET clan_id   = (SELECT id FROM public.clans WHERE name = 'Schwitzende Verbindung Halle'),
--     clan_role = 'leader'
-- WHERE id = '1ecb3c26-1fc7-4616-96b9-3d657365052b';

-- Alle anderen öffentlichen Nutzer als Member hinzufügen
-- UPDATE public.profiles
-- SET clan_id   = (SELECT id FROM public.clans WHERE name = 'Schwitzende Verbindung Halle'),
--     clan_role = 'member'
-- WHERE public = true
--   AND id != '1ecb3c26-1fc7-4616-96b9-3d657365052b'
--   AND clan_id IS NULL;
