-- Einmalige Diamanten-Vergabe für 2026-05-19
-- Im Supabase SQL Editor ausführen.

with ranked as (
  select
    p.id as user_id,
    sum(s.minutes)::integer as minutes,
    row_number() over (order by sum(s.minutes) desc, random()) as rn
  from study_days s
  join profiles p on p.id = s.user_id
  where s.date = '2026-05-19'
    and p.public is true
    and s.off is not true
    and s.minutes > 0
  group by p.id
),
inserted as (
  insert into daily_winners (date, rank, user_id, username, minutes)
  select '2026-05-19', r.rn, r.user_id, p.username, r.minutes
  from ranked r join profiles p on p.id = r.user_id
  where r.rn <= 3
  on conflict (date, rank) do nothing
  returning user_id, rank
)
update profiles p set
  diamonds = diamonds + case i.rank when 1 then 3 when 2 then 2 when 3 then 1 end
from inserted i
where p.id = i.user_id;
