DROP FUNCTION IF EXISTS "public"."get_yesterday_winner"();

CREATE FUNCTION "public"."get_yesterday_winner"()
RETURNS TABLE("username" "text", "minutes" integer)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  WITH yesterday AS (
    SELECT ((now() AT TIME ZONE 'Europe/Berlin') - interval '4 hours')::date - 1 AS d
  )
  SELECT p.username, sd.minutes
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

GRANT ALL ON FUNCTION "public"."get_yesterday_winner"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_yesterday_winner"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_yesterday_winner"() TO "service_role";
