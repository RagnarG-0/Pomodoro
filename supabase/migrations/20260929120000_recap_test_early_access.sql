-- M2-Recap: per-Account Früh-Freischaltung für Tests vor dem globalen
-- Start-Datum. Rein additiv, Flag bleibt für alle bestehenden Accounts
-- false (Default). Wer das Flag bekommt, entscheidet eine separate, NICHT
-- committete SQL-Anweisung direkt gegen die verlinkte DB — kein Account-UUID
-- im Git-Verlauf, analog zur is_admin-Konvention (siehe docs/admin.md).
alter table public.profiles
  add column if not exists recap_test_early_access boolean not null default false;

create or replace function public.recap_available()
returns boolean
language sql
stable
as $$
  select ((now() at time zone 'Europe/Berlin') - interval '4 hours')::date >= date '2026-10-04'
     or exists (
       select 1 from public.profiles
       where id = auth.uid() and recap_test_early_access = true
     );
$$;

revoke all on function public.recap_available() from public;
grant execute on function public.recap_available() to authenticated;
