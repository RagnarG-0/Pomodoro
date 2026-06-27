-- Fix: daily-winners Cron-Job nach Entfernung von profiles.awards_last
-- awards_last wurde in Phase 1 gedroppt → die UPDATE-Zeile schlug fehl
-- → keine Diamanten wurden seit dem 04.05.2026 vergeben.
-- Klorolle (rank 99) entfernt, da awards_last nicht mehr existiert.
--
-- Im Supabase SQL Editor ausführen.

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
