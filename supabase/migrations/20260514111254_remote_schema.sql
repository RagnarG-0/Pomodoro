


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE EXTENSION IF NOT EXISTS "pg_cron" WITH SCHEMA "pg_catalog";






COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE OR REPLACE FUNCTION "public"."add_study_minutes"("p_date" "date", "p_minutes" integer) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
begin
  insert into study_days (user_id, date, minutes)
  values (auth.uid(), p_date, p_minutes)
  on conflict (user_id, date)
  do update set 
    minutes = study_days.minutes + p_minutes,
    updated_at = now()
  where study_days.updated_at < now() - interval '2 seconds';
  -- ↑ Ignoriert doppelte Requests innerhalb von 2 Sekunden
end;
$$;


ALTER FUNCTION "public"."add_study_minutes"("p_date" "date", "p_minutes" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_clan"("p_name" "text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
  DECLARE
    v_clan_id uuid;
  BEGIN
    IF EXISTS (
      SELECT 1 FROM profiles WHERE id = auth.uid() AND clan_id IS NOT NULL
    ) THEN
      RAISE EXCEPTION 'already_in_clan';
    END IF;

    INSERT INTO clans (name, leader_id)
    VALUES (p_name, auth.uid())
    RETURNING id INTO v_clan_id;

    UPDATE profiles
    SET clan_id = v_clan_id, clan_role = 'leader'
    WHERE id = auth.uid();

    RETURN v_clan_id;
  END;
  $$;


ALTER FUNCTION "public"."create_clan"("p_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_clan_members"() RETURNS TABLE("id" "uuid", "username" "text", "clan_role" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
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
  END; $$;


ALTER FUNCTION "public"."get_clan_members"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_label_stats"("p_user_id" "uuid") RETURNS TABLE("label" "text", "today_minutes" bigint, "week_minutes" bigint, "month_minutes" bigint, "alltime_minutes" bigint)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    AS $$
    SELECT
      ps.label,
      COALESCE(SUM(CASE WHEN ps.date = CURRENT_DATE
                        THEN ps.duration_minutes ELSE 0 END), 0)::BIGINT AS today_minutes,
      COALESCE(SUM(CASE WHEN ps.date >= CURRENT_DATE - 6
                        THEN ps.duration_minutes ELSE 0 END), 0)::BIGINT AS week_minutes,
      COALESCE(SUM(CASE WHEN ps.date >= date_trunc('month', CURRENT_DATE)::DATE
                        THEN ps.duration_minutes ELSE 0 END), 0)::BIGINT AS month_minutes,
      COALESCE(SUM(ps.duration_minutes), 0)::BIGINT AS alltime_minutes
    FROM pomodoro_sessions ps
    WHERE ps.user_id = p_user_id
    GROUP BY ps.label
    ORDER BY alltime_minutes DESC;
  $$;


ALTER FUNCTION "public"."get_label_stats"("p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_yesterday_winner"() RETURNS "text"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
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


ALTER FUNCTION "public"."get_yesterday_winner"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."leaderboard_aggregated"("date_from" "date") RETURNS TABLE("name" "text", "minutes" bigint, "alltime_minutes" bigint, "diamonds" integer, "awards_last" integer, "avatar_url" "text", "timer_active" boolean)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
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
      SELECT ts.end_at IS NOT NULL
             AND ts.end_at > now()
             AND ts.mode = 'work'
      FROM timer_state ts WHERE ts.user_id = p.id LIMIT 1
    ), false)                                              AS timer_active
  FROM profiles p
  WHERE p.public = true
    AND p.clan_id = my_clan_id()
  ORDER BY minutes DESC, alltime_minutes DESC;
$$;


ALTER FUNCTION "public"."leaderboard_aggregated"("date_from" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."leaderboard_today"() RETURNS TABLE("name" "text", "minutes" integer, "alltime_minutes" bigint, "diamonds" integer, "awards_last" integer, "avatar_url" "text", "timer_active" boolean)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  WITH today AS (
    SELECT ((now() AT TIME ZONE 'Europe/Berlin') - interval '4 hours')::date AS d
  )
  SELECT
    p.username,
    COALESCE(sd_today.minutes, 0)                          AS minutes,
    COALESCE((
      SELECT SUM(sd.minutes) FROM study_days sd WHERE sd.user_id = p.id
    ), 0)::bigint                                          AS alltime_minutes,
    COALESCE(p.diamonds, 0),
    COALESCE(p.awards_last, 0),
    p.avatar_url,
    COALESCE((
      SELECT ts.end_at IS NOT NULL
             AND ts.end_at > now()
             AND ts.mode = 'work'
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


ALTER FUNCTION "public"."leaderboard_today"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."log_study_days_change"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
declare
  uname text;
begin
  select username into uname from profiles where id = NEW.user_id;

  if TG_OP = 'INSERT' then
    insert into study_days_log 
      (user_id, username, date, minutes_before, minutes_after, minutes_delta, action)
    values 
      (NEW.user_id, uname, NEW.date, 0, NEW.minutes, NEW.minutes, 'insert');
  elsif TG_OP = 'UPDATE' then
    insert into study_days_log 
      (user_id, username, date, minutes_before, minutes_after, minutes_delta, action)
    values 
      (NEW.user_id, uname, NEW.date, OLD.minutes, NEW.minutes, NEW.minutes - OLD.minutes, 'update');
  end if;

  -- Automatisch Einträge älter als 48h löschen
  delete from study_days_log where logged_at < now() - interval '48 hours';

  return NEW;
end;
$$;


ALTER FUNCTION "public"."log_study_days_change"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."my_clan_id"() RETURNS "uuid"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
    SELECT clan_id FROM profiles WHERE id = auth.uid();
  $$;


ALTER FUNCTION "public"."my_clan_id"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."remove_clan_member"("p_user_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
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
END; $$;


ALTER FUNCTION "public"."remove_clan_member"("p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."respond_to_clan_request"("p_request_id" "uuid", "p_accept" boolean) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
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
END; $$;


ALTER FUNCTION "public"."respond_to_clan_request"("p_request_id" "uuid", "p_accept" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."submit_join_request"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  DECLARE v_clan_id uuid;
  BEGIN
    IF EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND clan_id IS NOT NULL) THEN
  RETURN; END IF;
    SELECT id INTO v_clan_id FROM clans LIMIT 1;
    IF NOT FOUND THEN RETURN; END IF;
    INSERT INTO clan_requests (clan_id, user_id)
      VALUES (v_clan_id, auth.uid())
      ON CONFLICT DO NOTHING;
  END; $$;


ALTER FUNCTION "public"."submit_join_request"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."submit_join_request_to"("p_clan_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
  BEGIN
    IF EXISTS (
      SELECT 1 FROM profiles WHERE id = auth.uid() AND clan_id IS NOT NULL
    ) THEN
      RAISE EXCEPTION 'already_in_clan';
    END IF;
  
    IF EXISTS (
      SELECT 1 FROM clan_requests
      WHERE user_id = auth.uid() AND clan_id = p_clan_id AND status = 'pending'
    ) THEN
      RETURN;
    END IF;

    INSERT INTO clan_requests (clan_id, user_id, status)
    VALUES (p_clan_id, auth.uid(), 'pending');
  END;
  $$;


ALTER FUNCTION "public"."submit_join_request_to"("p_clan_id" "uuid") OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."clan_requests" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "clan_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "clan_requests_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'accepted'::"text", 'rejected'::"text"])))
);


ALTER TABLE "public"."clan_requests" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."clans" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "leader_id" "uuid",
    "min_focus_min" integer DEFAULT 1 NOT NULL,
    "max_focus_min" integer DEFAULT 300 NOT NULL,
    "level_config" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."clans" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."daily_winners" (
    "date" "date" NOT NULL,
    "rank" integer NOT NULL,
    "user_id" "uuid",
    "username" "text" NOT NULL,
    "minutes" integer NOT NULL
);


ALTER TABLE "public"."daily_winners" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."leaderboard" (
    "name" "text" NOT NULL,
    "date" "date" DEFAULT CURRENT_DATE NOT NULL,
    "minutes" integer DEFAULT 0 NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."leaderboard" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."pomodoro_sessions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "date" "date" NOT NULL,
    "label" "text" DEFAULT 'not specified'::"text" NOT NULL,
    "duration_minutes" integer DEFAULT 25 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."pomodoro_sessions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "id" "uuid" NOT NULL,
    "username" "text" NOT NULL,
    "public" boolean DEFAULT true,
    "focus_min" integer DEFAULT 25,
    "short_min" integer DEFAULT 5,
    "long_min" integer DEFAULT 15,
    "long_after" integer DEFAULT 4,
    "display_unit" "text" DEFAULT 'pomodoros'::"text",
    "sound" "text" DEFAULT 'bell'::"text",
    "off_weekdays" integer[] DEFAULT '{}'::integer[],
    "created_at" timestamp with time zone DEFAULT "now"(),
    "avatar_url" "text",
    "diamonds" integer DEFAULT 0,
    "awards_last" integer DEFAULT 0,
    "clan_id" "uuid",
    "clan_role" "text",
    CONSTRAINT "profiles_clan_role_check" CHECK (("clan_role" = ANY (ARRAY['leader'::"text", 'member'::"text"])))
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."study_days" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid",
    "date" "date" NOT NULL,
    "minutes" integer DEFAULT 0 NOT NULL,
    "off" boolean DEFAULT false,
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."study_days" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."study_days_log" (
    "id" bigint NOT NULL,
    "user_id" "uuid",
    "username" "text",
    "date" "date" NOT NULL,
    "minutes_before" integer,
    "minutes_after" integer,
    "minutes_delta" integer,
    "action" "text" NOT NULL,
    "logged_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."study_days_log" OWNER TO "postgres";


ALTER TABLE "public"."study_days_log" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."study_days_log_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."timer_state" (
    "user_id" "uuid" NOT NULL,
    "end_at" timestamp with time zone,
    "total_sec" integer,
    "mode" "text" DEFAULT 'work'::"text",
    "paused_remaining" integer,
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "pomoday" "date"
);


ALTER TABLE "public"."timer_state" OWNER TO "postgres";


ALTER TABLE ONLY "public"."clan_requests"
    ADD CONSTRAINT "clan_requests_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."clans"
    ADD CONSTRAINT "clans_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."clans"
    ADD CONSTRAINT "clans_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."daily_winners"
    ADD CONSTRAINT "daily_winners_pkey" PRIMARY KEY ("date", "rank");



ALTER TABLE ONLY "public"."leaderboard"
    ADD CONSTRAINT "leaderboard_pkey" PRIMARY KEY ("name", "date");



ALTER TABLE ONLY "public"."pomodoro_sessions"
    ADD CONSTRAINT "pomodoro_sessions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_username_key" UNIQUE ("username");



ALTER TABLE ONLY "public"."study_days_log"
    ADD CONSTRAINT "study_days_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."study_days"
    ADD CONSTRAINT "study_days_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."study_days"
    ADD CONSTRAINT "study_days_user_id_date_key" UNIQUE ("user_id", "date");



ALTER TABLE ONLY "public"."timer_state"
    ADD CONSTRAINT "timer_state_pkey" PRIMARY KEY ("user_id");



CREATE UNIQUE INDEX "clan_requests_pending_unique" ON "public"."clan_requests" USING "btree" ("clan_id", "user_id") WHERE ("status" = 'pending'::"text");



CREATE INDEX "idx_pomo_sessions_user_date" ON "public"."pomodoro_sessions" USING "btree" ("user_id", "date");



CREATE OR REPLACE TRIGGER "study_days_audit" AFTER INSERT OR UPDATE ON "public"."study_days" FOR EACH ROW EXECUTE FUNCTION "public"."log_study_days_change"();



ALTER TABLE ONLY "public"."clan_requests"
    ADD CONSTRAINT "clan_requests_clan_id_fkey" FOREIGN KEY ("clan_id") REFERENCES "public"."clans"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."clan_requests"
    ADD CONSTRAINT "clan_requests_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."clans"
    ADD CONSTRAINT "clans_leader_id_fkey" FOREIGN KEY ("leader_id") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."daily_winners"
    ADD CONSTRAINT "daily_winners_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."pomodoro_sessions"
    ADD CONSTRAINT "pomodoro_sessions_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_clan_id_fkey" FOREIGN KEY ("clan_id") REFERENCES "public"."clans"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."study_days_log"
    ADD CONSTRAINT "study_days_log_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."study_days"
    ADD CONSTRAINT "study_days_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."timer_state"
    ADD CONSTRAINT "timer_state_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



CREATE POLICY "Eigene Tage lesen" ON "public"."study_days" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Eigene Tage löschen" ON "public"."study_days" FOR DELETE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Eigene Tage schreiben" ON "public"."study_days" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Eigene Tage updaten" ON "public"."study_days" FOR UPDATE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Eigener Timer" ON "public"."timer_state" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Eigenes Profil schreiben" ON "public"."profiles" FOR INSERT WITH CHECK (("auth"."uid"() = "id"));



CREATE POLICY "Eigenes Profil updaten" ON "public"."profiles" FOR UPDATE USING (("auth"."uid"() = "id"));



CREATE POLICY "Jeder kann eigene Einträge löschen" ON "public"."leaderboard" FOR DELETE USING (true);



CREATE POLICY "Jeder kann einfügen" ON "public"."leaderboard" FOR INSERT WITH CHECK (true);



CREATE POLICY "Jeder kann lesen" ON "public"."daily_winners" FOR SELECT USING (true);



CREATE POLICY "Jeder kann lesen" ON "public"."leaderboard" FOR SELECT USING (true);



CREATE POLICY "Jeder kann updaten" ON "public"."leaderboard" FOR UPDATE USING (true);



CREATE POLICY "Profile lesen" ON "public"."profiles" FOR SELECT USING ((("public" = true) OR ("auth"."uid"() = "id")));



CREATE POLICY "Service kann schreiben" ON "public"."daily_winners" FOR INSERT WITH CHECK (true);



CREATE POLICY "Users can insert own sessions" ON "public"."pomodoro_sessions" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can update own sessions" ON "public"."pomodoro_sessions" FOR UPDATE USING (("auth"."uid"() = "user_id")) WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can view own sessions" ON "public"."pomodoro_sessions" FOR SELECT USING (("auth"."uid"() = "user_id"));



ALTER TABLE "public"."clan_requests" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "clan_requests_insert" ON "public"."clan_requests" FOR INSERT TO "authenticated" WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "clan_requests_select" ON "public"."clan_requests" FOR SELECT TO "authenticated" USING ((("auth"."uid"() = "user_id") OR ("clan_id" IN ( SELECT "clans"."id"
   FROM "public"."clans"
  WHERE ("clans"."leader_id" = "auth"."uid"())))));



ALTER TABLE "public"."clans" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "clans_select_auth" ON "public"."clans" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "clans_update_leader" ON "public"."clans" FOR UPDATE TO "authenticated" USING (("auth"."uid"() = "leader_id"));



ALTER TABLE "public"."daily_winners" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."leaderboard" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."pomodoro_sessions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "profiles_read_clan_peers" ON "public"."profiles" FOR SELECT TO "authenticated" USING ((("clan_id" IS NOT NULL) AND ("clan_id" = "public"."my_clan_id"())));



CREATE POLICY "profiles_read_own" ON "public"."profiles" FOR SELECT TO "authenticated" USING (("id" = "auth"."uid"()));



ALTER TABLE "public"."study_days" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."study_days_log" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."timer_state" ENABLE ROW LEVEL SECURITY;




ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";





GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";











































































































































































GRANT ALL ON FUNCTION "public"."add_study_minutes"("p_date" "date", "p_minutes" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."add_study_minutes"("p_date" "date", "p_minutes" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."add_study_minutes"("p_date" "date", "p_minutes" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."create_clan"("p_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."create_clan"("p_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_clan"("p_name" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_clan_members"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_clan_members"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_clan_members"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_label_stats"("p_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_label_stats"("p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_label_stats"("p_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_yesterday_winner"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_yesterday_winner"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_yesterday_winner"() TO "service_role";



GRANT ALL ON FUNCTION "public"."leaderboard_aggregated"("date_from" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."leaderboard_aggregated"("date_from" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."leaderboard_aggregated"("date_from" "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."leaderboard_today"() TO "anon";
GRANT ALL ON FUNCTION "public"."leaderboard_today"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."leaderboard_today"() TO "service_role";



GRANT ALL ON FUNCTION "public"."log_study_days_change"() TO "anon";
GRANT ALL ON FUNCTION "public"."log_study_days_change"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."log_study_days_change"() TO "service_role";



GRANT ALL ON FUNCTION "public"."my_clan_id"() TO "anon";
GRANT ALL ON FUNCTION "public"."my_clan_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."my_clan_id"() TO "service_role";



GRANT ALL ON FUNCTION "public"."remove_clan_member"("p_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."remove_clan_member"("p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."remove_clan_member"("p_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."respond_to_clan_request"("p_request_id" "uuid", "p_accept" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."respond_to_clan_request"("p_request_id" "uuid", "p_accept" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."respond_to_clan_request"("p_request_id" "uuid", "p_accept" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."submit_join_request"() TO "anon";
GRANT ALL ON FUNCTION "public"."submit_join_request"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."submit_join_request"() TO "service_role";



GRANT ALL ON FUNCTION "public"."submit_join_request_to"("p_clan_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."submit_join_request_to"("p_clan_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."submit_join_request_to"("p_clan_id" "uuid") TO "service_role";
























GRANT ALL ON TABLE "public"."clan_requests" TO "anon";
GRANT ALL ON TABLE "public"."clan_requests" TO "authenticated";
GRANT ALL ON TABLE "public"."clan_requests" TO "service_role";



GRANT ALL ON TABLE "public"."clans" TO "anon";
GRANT ALL ON TABLE "public"."clans" TO "authenticated";
GRANT ALL ON TABLE "public"."clans" TO "service_role";



GRANT ALL ON TABLE "public"."daily_winners" TO "anon";
GRANT ALL ON TABLE "public"."daily_winners" TO "authenticated";
GRANT ALL ON TABLE "public"."daily_winners" TO "service_role";



GRANT ALL ON TABLE "public"."leaderboard" TO "anon";
GRANT ALL ON TABLE "public"."leaderboard" TO "authenticated";
GRANT ALL ON TABLE "public"."leaderboard" TO "service_role";



GRANT ALL ON TABLE "public"."pomodoro_sessions" TO "anon";
GRANT ALL ON TABLE "public"."pomodoro_sessions" TO "authenticated";
GRANT ALL ON TABLE "public"."pomodoro_sessions" TO "service_role";



GRANT ALL ON TABLE "public"."profiles" TO "anon";
GRANT ALL ON TABLE "public"."profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."profiles" TO "service_role";



GRANT ALL ON TABLE "public"."study_days" TO "anon";
GRANT ALL ON TABLE "public"."study_days" TO "authenticated";
GRANT ALL ON TABLE "public"."study_days" TO "service_role";



GRANT ALL ON TABLE "public"."study_days_log" TO "anon";
GRANT ALL ON TABLE "public"."study_days_log" TO "authenticated";
GRANT ALL ON TABLE "public"."study_days_log" TO "service_role";



GRANT ALL ON SEQUENCE "public"."study_days_log_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."study_days_log_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."study_days_log_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."timer_state" TO "anon";
GRANT ALL ON TABLE "public"."timer_state" TO "authenticated";
GRANT ALL ON TABLE "public"."timer_state" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";































