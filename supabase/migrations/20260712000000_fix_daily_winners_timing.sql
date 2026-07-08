-- Fix: daily-winners wertete "gestern" VOR der echten 4-Uhr-Berlin-Grenze aus.
--
-- Der Cron lief fix um 01:59 UTC (~03:59 Berlin im Sommer, ~02:59 im Winter) —
-- beides VOR 4 Uhr. Bei kurzen, sofort abgeschlossenen Pomodoros fiel das nie
-- auf, aber eine über Nacht laufende Limitless-Session oder eine pausierte
-- Session wird erst NACH 4 Uhr durch reset_stale_work_sessions() final
-- verbucht (siehe 20260708000000_reset_stale_work_sessions.sql). Lief
-- daily-winners vorher, fehlte genau diese letzte Zeitspanne in der Summe —
-- und wegen ON CONFLICT (date, rank) DO NOTHING wurde das nie nachträglich
-- korrigiert.
--
-- Fix: alle 5 Minuten prüfen (wie reset_stale_work_sessions), aber nur
-- auswerten, sobald wir wirklich über 4 Uhr Berlin sind (today_de bleibt vor
-- 4 Uhr eine leere CTE -> ranked/inserted bleiben leer -> No-Op). Der Zeitplan
-- ist 2 Minuten gegenüber reset-stale-work-sessions (*/5, also :00/:05/...)
-- versetzt (:02/:07/...), damit übrig gebliebene Nacht-Sessions garantiert
-- zuerst verbucht sind, bevor die Rangliste für den Tag gezogen wird.

select cron.unschedule('daily-winners');

select cron.schedule(
  'daily-winners',
  '2-59/5 * * * *',
  $$
    with today_de as (
      select (now() at time zone 'Europe/Berlin')::date - 1 as d
      where extract(hour from now() at time zone 'Europe/Berlin') >= 4
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
