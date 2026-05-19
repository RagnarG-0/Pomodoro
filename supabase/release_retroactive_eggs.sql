-- Einmaliges Release-Script: Retroaktive Ei-Vergabe
-- Ausführen im Supabase SQL Editor — NUR EINMAL nach Phase-3-Deployment.
--
-- Formel: (aktuelles_level - 1) Eier, da man mit Level 1 startet.
-- Level = Anzahl der Schwellwerte, die <= Gesamt-Fokusminuten des Nutzers sind.
-- Eier werden in die ersten freien Slots (= '0') geschrieben; volle Inventare bleiben unverändert.

DO $$
DECLARE
  v_user           RECORD;
  v_total          int;
  v_level          int;
  v_eggs_to_award  int;
  v_slots          text[];
  v_awarded        int;
  v_colors         text[]  := ARRAY['y','b','g','r'];
  v_thresholds     int[]   := ARRAY[0,300,600,900,1500,2100,3000,3900,4800,6000,
                                    7800,9600,12000,14400,17400,21000,25200,30000,
                                    35400,41400,45000,49200,54000,58800,63000];
  i                int;
BEGIN
  FOR v_user IN SELECT id, eggs FROM public.profiles LOOP

    SELECT COALESCE(SUM(minutes), 0)::int INTO v_total
    FROM public.study_days
    WHERE user_id = v_user.id;

    SELECT COUNT(*)::int INTO v_level
    FROM unnest(v_thresholds) AS t
    WHERE t <= v_total;

    v_eggs_to_award := GREATEST(v_level - 1, 0);
    IF v_eggs_to_award = 0 THEN CONTINUE; END IF;

    v_slots := string_to_array(COALESCE(v_user.eggs, '0-0-0-0-0-0-0-0-0-0'), '-');
    WHILE array_length(v_slots, 1) < 10 LOOP
      v_slots := v_slots || '0';
    END LOOP;

    v_awarded := 0;
    FOR i IN 1..10 LOOP
      EXIT WHEN v_awarded >= v_eggs_to_award;
      IF v_slots[i] = '0' THEN
        v_slots[i] := v_colors[1 + (floor(random() * 4))::int];
        v_awarded  := v_awarded + 1;
      END IF;
    END LOOP;

    UPDATE public.profiles
    SET    eggs = array_to_string(v_slots, '-')
    WHERE  id   = v_user.id;

    RAISE NOTICE 'User %: Level %, % Eier vergeben → %',
      v_user.id, v_level, v_awarded, array_to_string(v_slots, '-');

  END LOOP;
END;
$$;
