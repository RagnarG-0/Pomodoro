-- Einmaliger Backfill: alle Nutzer, die bereits HEUTE einen Eintrag in
-- study_days haben, bekommen ebenfalls sofort ein zufälliges Rennauto —
-- nicht nur Nutzer, die sich NACH diesem Feature neu einloggen/laden.
UPDATE public.profiles p
SET race_car_id = 1 + floor(random() * 8)::smallint
WHERE p.race_car_id IS NULL
  AND EXISTS (
    SELECT 1 FROM public.study_days sd
    WHERE sd.user_id = p.id
      AND sd.date = ((now() AT TIME ZONE 'Europe/Berlin') - interval '4 hours')::date
      AND sd.minutes > 0
  );
