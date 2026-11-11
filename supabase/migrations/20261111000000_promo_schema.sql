-- Promo-Modus (Doktorarbeit): komplett getrennte Datenwelt im eigenen Schema `promo`.
-- Generiert aus den Live-Definitionen von public (Stand 2026-11-11), siehe docs/promo.md.
-- Rein additiv: keine public-Tabelle/-Funktion wird verändert (einzige Ausnahme: ein
-- zusätzlicher AFTER-INSERT-Trigger auf public.profiles, der die Promo-Wallet anlegt).
--
-- Aufbau:
--   * Daten-Tabellen (Lernzeit, Sessions, Timer, Eier, Karten, Tauschbörse, Claims, …) als
--     echte, leere Kopien promo.<name>
--   * geteilte Tabellen (Clan, Kataloge, Mensa) als durchreichende Views promo.<name>
--   * promo.profiles = View public.profiles ⨝ promo.wallets (diamonds/eggs/
--     second_incubator_purchased kommen aus der Wallet), schreibbar per INSTEAD-OF-Trigger
--   * alle RPCs als Kopie in promo mit search_path = promo, public
-- Der Client wählt das Schema per PostgREST-Header Accept-Profile/Content-Profile.

CREATE SCHEMA IF NOT EXISTS promo;
GRANT USAGE ON SCHEMA promo TO anon, authenticated, service_role;

-- Unqualifizierte Namen in Signaturen/Policies (z. B. `p_row timer_state`) sollen beim
-- Anlegen auf promo auflösen; SQL-Funktionsrümpfe erst zur Laufzeit prüfen (Reihenfolge).
SET search_path = promo, public;
SET check_function_bodies = false;

-- ── Daten-Tabellen (leere Kopien) ──
CREATE TABLE promo.study_days (LIKE public.study_days INCLUDING DEFAULTS INCLUDING CONSTRAINTS INCLUDING INDEXES INCLUDING IDENTITY INCLUDING GENERATED);
CREATE TABLE promo.study_days_log (LIKE public.study_days_log INCLUDING DEFAULTS INCLUDING CONSTRAINTS INCLUDING INDEXES INCLUDING IDENTITY INCLUDING GENERATED);
CREATE TABLE promo.pomodoro_sessions (LIKE public.pomodoro_sessions INCLUDING DEFAULTS INCLUDING CONSTRAINTS INCLUDING INDEXES INCLUDING IDENTITY INCLUDING GENERATED);
CREATE TABLE promo.timer_state (LIKE public.timer_state INCLUDING DEFAULTS INCLUDING CONSTRAINTS INCLUDING INDEXES INCLUDING IDENTITY INCLUDING GENERATED);
CREATE TABLE promo.pending_focus_sessions (LIKE public.pending_focus_sessions INCLUDING DEFAULTS INCLUDING CONSTRAINTS INCLUDING INDEXES INCLUDING IDENTITY INCLUDING GENERATED);
CREATE TABLE promo.tired_events (LIKE public.tired_events INCLUDING DEFAULTS INCLUDING CONSTRAINTS INCLUDING INDEXES INCLUDING IDENTITY INCLUDING GENERATED);
CREATE TABLE promo.incubator (LIKE public.incubator INCLUDING DEFAULTS INCLUDING CONSTRAINTS INCLUDING INDEXES INCLUDING IDENTITY INCLUDING GENERATED);
CREATE TABLE promo.user_cards (LIKE public.user_cards INCLUDING DEFAULTS INCLUDING CONSTRAINTS INCLUDING INDEXES INCLUDING IDENTITY INCLUDING GENERATED);
CREATE TABLE promo.card_listings (LIKE public.card_listings INCLUDING DEFAULTS INCLUDING CONSTRAINTS INCLUDING INDEXES INCLUDING IDENTITY INCLUDING GENERATED);
CREATE TABLE promo.card_trades (LIKE public.card_trades INCLUDING DEFAULTS INCLUDING CONSTRAINTS INCLUDING INDEXES INCLUDING IDENTITY INCLUDING GENERATED);
CREATE TABLE promo.trade_offers (LIKE public.trade_offers INCLUDING DEFAULTS INCLUDING CONSTRAINTS INCLUDING INDEXES INCLUDING IDENTITY INCLUDING GENERATED);
CREATE TABLE promo.trade_offer_cards (LIKE public.trade_offer_cards INCLUDING DEFAULTS INCLUDING CONSTRAINTS INCLUDING INDEXES INCLUDING IDENTITY INCLUDING GENERATED);
CREATE TABLE promo.weekly_challenge_claims (LIKE public.weekly_challenge_claims INCLUDING DEFAULTS INCLUDING CONSTRAINTS INCLUDING INDEXES INCLUDING IDENTITY INCLUDING GENERATED);
CREATE TABLE promo.streak_milestone_claims (LIKE public.streak_milestone_claims INCLUDING DEFAULTS INCLUDING CONSTRAINTS INCLUDING INDEXES INCLUDING IDENTITY INCLUDING GENERATED);
CREATE TABLE promo.perfect_week_claims (LIKE public.perfect_week_claims INCLUDING DEFAULTS INCLUDING CONSTRAINTS INCLUDING INDEXES INCLUDING IDENTITY INCLUDING GENERATED);
CREATE TABLE promo.set_bonus_claims (LIKE public.set_bonus_claims INCLUDING DEFAULTS INCLUDING CONSTRAINTS INCLUDING INDEXES INCLUDING IDENTITY INCLUDING GENERATED);
CREATE TABLE promo.race_checkpoint_claims (LIKE public.race_checkpoint_claims INCLUDING DEFAULTS INCLUDING CONSTRAINTS INCLUDING INDEXES INCLUDING IDENTITY INCLUDING GENERATED);
CREATE TABLE promo.daily_winners (LIKE public.daily_winners INCLUDING DEFAULTS INCLUDING CONSTRAINTS INCLUDING INDEXES INCLUDING IDENTITY INCLUDING GENERATED);

-- Fremdschlüssel: Daten-Tabellen untereinander → promo, Identität/Kataloge → public
ALTER TABLE promo.card_listings ADD CONSTRAINT card_listings_card_id_fkey FOREIGN KEY (card_id) REFERENCES public.cards(id);
ALTER TABLE promo.card_listings ADD CONSTRAINT card_listings_user_card_id_fkey FOREIGN KEY (user_card_id) REFERENCES promo.user_cards(id) ON DELETE CASCADE;
ALTER TABLE promo.card_listings ADD CONSTRAINT card_listings_seller_id_fkey FOREIGN KEY (seller_id) REFERENCES public.profiles(id) ON DELETE CASCADE;
ALTER TABLE promo.card_trades ADD CONSTRAINT card_trades_buyer_id_fkey FOREIGN KEY (buyer_id) REFERENCES public.profiles(id);
ALTER TABLE promo.card_trades ADD CONSTRAINT card_trades_card_id_fkey FOREIGN KEY (card_id) REFERENCES public.cards(id);
ALTER TABLE promo.card_trades ADD CONSTRAINT card_trades_listing_id_fkey FOREIGN KEY (listing_id) REFERENCES promo.card_listings(id) ON DELETE SET NULL;
ALTER TABLE promo.card_trades ADD CONSTRAINT card_trades_user_card_id_fkey FOREIGN KEY (user_card_id) REFERENCES promo.user_cards(id) ON DELETE SET NULL;
ALTER TABLE promo.card_trades ADD CONSTRAINT card_trades_seller_id_fkey FOREIGN KEY (seller_id) REFERENCES public.profiles(id);
ALTER TABLE promo.card_trades ADD CONSTRAINT card_trades_trade_offer_id_fkey FOREIGN KEY (trade_offer_id) REFERENCES promo.trade_offers(id) ON DELETE SET NULL;
ALTER TABLE promo.daily_winners ADD CONSTRAINT daily_winners_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE SET NULL;
ALTER TABLE promo.incubator ADD CONSTRAINT incubator_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE;
ALTER TABLE promo.pending_focus_sessions ADD CONSTRAINT pending_focus_sessions_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;
ALTER TABLE promo.perfect_week_claims ADD CONSTRAINT perfect_week_claims_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE;
ALTER TABLE promo.pomodoro_sessions ADD CONSTRAINT pomodoro_sessions_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;
ALTER TABLE promo.race_checkpoint_claims ADD CONSTRAINT race_checkpoint_claims_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE;
ALTER TABLE promo.set_bonus_claims ADD CONSTRAINT set_bonus_claims_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE;
ALTER TABLE promo.streak_milestone_claims ADD CONSTRAINT streak_milestone_claims_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE;
ALTER TABLE promo.streak_milestone_claims ADD CONSTRAINT streak_milestone_claims_days_fkey FOREIGN KEY (days) REFERENCES public.streak_milestones(days);
ALTER TABLE promo.study_days ADD CONSTRAINT study_days_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;
ALTER TABLE promo.study_days_log ADD CONSTRAINT study_days_log_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE SET NULL;
ALTER TABLE promo.timer_state ADD CONSTRAINT timer_state_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;
ALTER TABLE promo.tired_events ADD CONSTRAINT tired_events_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;
ALTER TABLE promo.trade_offer_cards ADD CONSTRAINT trade_offer_cards_trade_offer_id_fkey FOREIGN KEY (trade_offer_id) REFERENCES promo.trade_offers(id) ON DELETE CASCADE;
ALTER TABLE promo.trade_offer_cards ADD CONSTRAINT trade_offer_cards_user_card_id_fkey FOREIGN KEY (user_card_id) REFERENCES promo.user_cards(id) ON DELETE CASCADE;
ALTER TABLE promo.trade_offer_cards ADD CONSTRAINT trade_offer_cards_card_id_fkey FOREIGN KEY (card_id) REFERENCES public.cards(id);
ALTER TABLE promo.trade_offers ADD CONSTRAINT trade_offers_offerer_id_fkey FOREIGN KEY (offerer_id) REFERENCES public.profiles(id) ON DELETE CASCADE;
ALTER TABLE promo.trade_offers ADD CONSTRAINT trade_offers_listing_id_fkey FOREIGN KEY (listing_id) REFERENCES promo.card_listings(id) ON DELETE CASCADE;
ALTER TABLE promo.user_cards ADD CONSTRAINT user_cards_card_id_fkey FOREIGN KEY (card_id) REFERENCES public.cards(id);
ALTER TABLE promo.user_cards ADD CONSTRAINT user_cards_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE;
ALTER TABLE promo.weekly_challenge_claims ADD CONSTRAINT weekly_challenge_claims_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE;
ALTER TABLE promo.weekly_challenge_claims ADD CONSTRAINT weekly_challenge_claims_challenge_key_fkey FOREIGN KEY (challenge_key) REFERENCES public.weekly_challenges(challenge_key);

-- ── Promo-Wallet: Spielwelt-Felder, die in M2 auf public.profiles liegen ──
CREATE TABLE promo.wallets (
  user_id uuid PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
  diamonds integer DEFAULT 0,
  eggs text DEFAULT '0-0-0-0-0-0-0-0-0-0'::text NOT NULL,
  second_incubator_purchased boolean DEFAULT false NOT NULL
);
ALTER TABLE promo.wallets ENABLE ROW LEVEL SECURITY;
-- Sichtbar, wenn das zugehörige Profil sichtbar ist (RLS von public.profiles greift, da Invoker)
CREATE POLICY wallets_select ON promo.wallets FOR SELECT
  USING (user_id = auth.uid() OR EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = wallets.user_id));
CREATE POLICY wallets_update_own ON promo.wallets FOR UPDATE USING (user_id = auth.uid());
GRANT SELECT, UPDATE ON TABLE promo.wallets TO anon, authenticated;
GRANT ALL ON TABLE promo.wallets TO service_role;

-- Jede (auch künftige) Profilzeile bekommt eine leere Promo-Wallet
INSERT INTO promo.wallets (user_id) SELECT id FROM public.profiles ON CONFLICT DO NOTHING;

CREATE FUNCTION promo.ensure_wallet_for_profile() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  INSERT INTO promo.wallets (user_id) VALUES (NEW.id) ON CONFLICT DO NOTHING;
  RETURN NEW;
END;
$$;
CREATE TRIGGER profiles_ensure_promo_wallet AFTER INSERT ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION promo.ensure_wallet_for_profile();

-- ── promo.profiles: geteiltes Profil + Promo-Wallet ──
CREATE VIEW promo.profiles WITH (security_invoker = true) AS
  SELECT p.id, p.username, p.public, p.focus_min, p.short_min, p.long_min, p.long_after, p.display_unit, p.sound, p.off_weekdays, p.created_at, p.avatar_url, w.diamonds, p.clan_id, p.clan_role, w.eggs, p.label_focus_mins, p.daily_focus_goal_min, w.second_incubator_purchased, p.bento_layout, p.race_car_id, p.is_admin, p.library_checkin, p.library_checkin_date, p.bento_layout_profiles, p.mensa_checkin, p.mensa_checkin_date, p.recap_test_early_access
  FROM public.profiles p JOIN promo.wallets w ON w.user_id = p.id;
ALTER VIEW promo.profiles ALTER COLUMN public SET DEFAULT true;
ALTER VIEW promo.profiles ALTER COLUMN focus_min SET DEFAULT 25;
ALTER VIEW promo.profiles ALTER COLUMN short_min SET DEFAULT 5;
ALTER VIEW promo.profiles ALTER COLUMN long_min SET DEFAULT 15;
ALTER VIEW promo.profiles ALTER COLUMN long_after SET DEFAULT 4;
ALTER VIEW promo.profiles ALTER COLUMN display_unit SET DEFAULT 'pomodoros'::text;
ALTER VIEW promo.profiles ALTER COLUMN sound SET DEFAULT 'bell'::text;
ALTER VIEW promo.profiles ALTER COLUMN off_weekdays SET DEFAULT '{}'::integer[];
ALTER VIEW promo.profiles ALTER COLUMN created_at SET DEFAULT now();
ALTER VIEW promo.profiles ALTER COLUMN diamonds SET DEFAULT 0;
ALTER VIEW promo.profiles ALTER COLUMN eggs SET DEFAULT '0-0-0-0-0-0-0-0-0-0'::text;
ALTER VIEW promo.profiles ALTER COLUMN label_focus_mins SET DEFAULT '{}'::jsonb;
ALTER VIEW promo.profiles ALTER COLUMN second_incubator_purchased SET DEFAULT false;
ALTER VIEW promo.profiles ALTER COLUMN is_admin SET DEFAULT false;
ALTER VIEW promo.profiles ALTER COLUMN recap_test_early_access SET DEFAULT false;

-- Security Invoker: Schreibrechte von public.profiles (nur eigenes Profil) gelten weiter;
-- aus SECURITY-DEFINER-RPCs heraus (claim_*, sell_card, …) läuft er als Owner.
CREATE FUNCTION promo.profiles_view_write() RETURNS trigger
  LANGUAGE plpgsql SET search_path = ''
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO public.profiles (id, username, public, focus_min, short_min, long_min, long_after, display_unit, sound, off_weekdays, created_at, avatar_url, clan_id, clan_role, label_focus_mins, daily_focus_goal_min, bento_layout, race_car_id, is_admin, library_checkin, library_checkin_date, bento_layout_profiles, mensa_checkin, mensa_checkin_date, recap_test_early_access)
    VALUES (NEW.id, NEW.username, NEW.public, NEW.focus_min, NEW.short_min, NEW.long_min, NEW.long_after, NEW.display_unit, NEW.sound, NEW.off_weekdays, NEW.created_at, NEW.avatar_url, NEW.clan_id, NEW.clan_role, NEW.label_focus_mins, NEW.daily_focus_goal_min, NEW.bento_layout, NEW.race_car_id, NEW.is_admin, NEW.library_checkin, NEW.library_checkin_date, NEW.bento_layout_profiles, NEW.mensa_checkin, NEW.mensa_checkin_date, NEW.recap_test_early_access);
    UPDATE promo.wallets SET diamonds = NEW.diamonds, eggs = NEW.eggs, second_incubator_purchased = NEW.second_incubator_purchased WHERE user_id = NEW.id;
  ELSIF TG_OP = 'UPDATE' THEN
    IF ROW(NEW.username, NEW.public, NEW.focus_min, NEW.short_min, NEW.long_min, NEW.long_after, NEW.display_unit, NEW.sound, NEW.off_weekdays, NEW.created_at, NEW.avatar_url, NEW.clan_id, NEW.clan_role, NEW.label_focus_mins, NEW.daily_focus_goal_min, NEW.bento_layout, NEW.race_car_id, NEW.is_admin, NEW.library_checkin, NEW.library_checkin_date, NEW.bento_layout_profiles, NEW.mensa_checkin, NEW.mensa_checkin_date, NEW.recap_test_early_access) IS DISTINCT FROM ROW(OLD.username, OLD.public, OLD.focus_min, OLD.short_min, OLD.long_min, OLD.long_after, OLD.display_unit, OLD.sound, OLD.off_weekdays, OLD.created_at, OLD.avatar_url, OLD.clan_id, OLD.clan_role, OLD.label_focus_mins, OLD.daily_focus_goal_min, OLD.bento_layout, OLD.race_car_id, OLD.is_admin, OLD.library_checkin, OLD.library_checkin_date, OLD.bento_layout_profiles, OLD.mensa_checkin, OLD.mensa_checkin_date, OLD.recap_test_early_access) THEN
      UPDATE public.profiles SET username = NEW.username, public = NEW.public, focus_min = NEW.focus_min, short_min = NEW.short_min, long_min = NEW.long_min, long_after = NEW.long_after, display_unit = NEW.display_unit, sound = NEW.sound, off_weekdays = NEW.off_weekdays, created_at = NEW.created_at, avatar_url = NEW.avatar_url, clan_id = NEW.clan_id, clan_role = NEW.clan_role, label_focus_mins = NEW.label_focus_mins, daily_focus_goal_min = NEW.daily_focus_goal_min, bento_layout = NEW.bento_layout, race_car_id = NEW.race_car_id, is_admin = NEW.is_admin, library_checkin = NEW.library_checkin, library_checkin_date = NEW.library_checkin_date, bento_layout_profiles = NEW.bento_layout_profiles, mensa_checkin = NEW.mensa_checkin, mensa_checkin_date = NEW.mensa_checkin_date, recap_test_early_access = NEW.recap_test_early_access WHERE id = OLD.id;
    END IF;
    IF ROW(NEW.diamonds, NEW.eggs, NEW.second_incubator_purchased) IS DISTINCT FROM ROW(OLD.diamonds, OLD.eggs, OLD.second_incubator_purchased) THEN
      UPDATE promo.wallets SET diamonds = COALESCE(promo.wallets.diamonds, 0) + (COALESCE(NEW.diamonds, 0) - COALESCE(OLD.diamonds, 0)), eggs = NEW.eggs, second_incubator_purchased = NEW.second_incubator_purchased WHERE user_id = OLD.id;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER profiles_view_write INSTEAD OF INSERT OR UPDATE ON promo.profiles
  FOR EACH ROW EXECUTE FUNCTION promo.profiles_view_write();
GRANT SELECT, INSERT, UPDATE ON TABLE promo.profiles TO anon, authenticated;
GRANT ALL ON TABLE promo.profiles TO service_role;

-- ── Geteilte Tabellen als durchreichende Views (RLS der public-Tabelle gilt) ──
CREATE VIEW promo.cards WITH (security_invoker = true) AS SELECT * FROM public.cards;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE promo.cards TO anon, authenticated;
GRANT ALL ON TABLE promo.cards TO service_role;
CREATE VIEW promo.clans WITH (security_invoker = true) AS SELECT * FROM public.clans;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE promo.clans TO anon, authenticated;
GRANT ALL ON TABLE promo.clans TO service_role;
CREATE VIEW promo.clan_requests WITH (security_invoker = true) AS SELECT * FROM public.clan_requests;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE promo.clan_requests TO anon, authenticated;
GRANT ALL ON TABLE promo.clan_requests TO service_role;
CREATE VIEW promo.weekly_challenges WITH (security_invoker = true) AS SELECT * FROM public.weekly_challenges;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE promo.weekly_challenges TO anon, authenticated;
GRANT ALL ON TABLE promo.weekly_challenges TO service_role;
CREATE VIEW promo.streak_milestones WITH (security_invoker = true) AS SELECT * FROM public.streak_milestones;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE promo.streak_milestones TO anon, authenticated;
GRANT ALL ON TABLE promo.streak_milestones TO service_role;
CREATE VIEW promo.perfect_week_config WITH (security_invoker = true) AS SELECT * FROM public.perfect_week_config;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE promo.perfect_week_config TO anon, authenticated;
GRANT ALL ON TABLE promo.perfect_week_config TO service_role;
CREATE VIEW promo.mensa_menu_items WITH (security_invoker = true) AS SELECT * FROM public.mensa_menu_items;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE promo.mensa_menu_items TO anon, authenticated;
GRANT ALL ON TABLE promo.mensa_menu_items TO service_role;

-- ── RPCs: Kopien der public-Fassungen, search_path = promo, public ──
CREATE OR REPLACE FUNCTION promo.add_study_minutes(p_date date, p_minutes integer)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'promo', 'public'
AS $function$
  INSERT INTO study_days (user_id, date, minutes)
  VALUES (auth.uid(), p_date, p_minutes)
  ON CONFLICT (user_id, date) DO UPDATE
    SET minutes = study_days.minutes + EXCLUDED.minutes;
$function$;

CREATE OR REPLACE FUNCTION promo.admin_force_stop_timer(p_user_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'promo', 'public'
AS $function$
DECLARE
  v_deleted timer_state%ROWTYPE;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND is_admin = true) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  DELETE FROM timer_state WHERE user_id = p_user_id AND mode IN ('work', 'short')
  RETURNING * INTO v_deleted;
  IF NOT FOUND THEN RETURN false; END IF;

  IF v_deleted.mode = 'work' THEN
    PERFORM promo.credit_elapsed_timer_state(v_deleted, now(), 'admin_stop');
  END IF;

  RETURN true;
END;
$function$;

CREATE OR REPLACE FUNCTION promo.admin_list_running_timers()
 RETURNS TABLE(user_id uuid, username text, mode text, limitless boolean, started_at timestamp with time zone, end_at timestamp with time zone, total_sec integer, paused_remaining integer, credited_min integer, pomoday date, updated_at timestamp with time zone)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'promo', 'public'
AS $function$
  SELECT ts.user_id, p.username, ts.mode, ts.limitless, ts.started_at, ts.end_at,
         ts.total_sec, ts.paused_remaining, ts.credited_min, ts.pomoday, ts.updated_at
  FROM timer_state ts
  JOIN profiles p ON p.id = ts.user_id
  WHERE ts.mode IN ('work', 'short')
    AND EXISTS (SELECT 1 FROM profiles me WHERE me.id = auth.uid() AND me.is_admin = true)
  ORDER BY ts.started_at NULLS LAST, ts.updated_at DESC;
$function$;

CREATE OR REPLACE FUNCTION promo.admin_lookup_user_day(p_username text, p_date date)
 RETURNS TABLE(user_id uuid, minutes integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'promo', 'public'
AS $function$
  SELECT p.id, COALESCE(sd.minutes, 0)
  FROM profiles p
  LEFT JOIN study_days sd ON sd.user_id = p.id AND sd.date = p_date
  WHERE p.username = p_username
    AND EXISTS (SELECT 1 FROM profiles me WHERE me.id = auth.uid() AND me.is_admin = true);
$function$;

CREATE OR REPLACE FUNCTION promo.admin_set_study_minutes(p_user_id uuid, p_date date, p_minutes integer)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'promo', 'public'
AS $function$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND is_admin = true) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF p_minutes < 0 OR p_minutes > 1440 THEN
    RAISE EXCEPTION 'Invalid minutes';
  END IF;

  INSERT INTO study_days (user_id, date, minutes)
  VALUES (p_user_id, p_date, p_minutes)
  ON CONFLICT (user_id, date) DO UPDATE SET minutes = p_minutes, updated_at = now();

  RETURN p_minutes;
END;
$function$;

CREATE OR REPLACE FUNCTION promo.calc_current_streak(p_user_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'promo', 'public'
AS $function$
DECLARE
  v_today   date;
  v_day     date;
  v_streak  int := 0;
  v_minutes int;
BEGIN
  v_today := ((now() AT TIME ZONE 'Europe/Berlin') - interval '4 hours')::date;
  v_day   := v_today;

  LOOP
    v_minutes := NULL;
    SELECT minutes INTO v_minutes FROM study_days WHERE user_id = p_user_id AND date = v_day;

    IF COALESCE(v_minutes, 0) > 0 THEN
      v_streak := v_streak + 1;
    ELSIF v_day = v_today THEN
      NULL; -- heute noch leer, aber Tag ist noch nicht vorbei -> nicht abbrechen
    ELSE
      EXIT;
    END IF;

    v_day := v_day - 1;
  END LOOP;

  RETURN v_streak;
END;
$function$;

CREATE OR REPLACE FUNCTION promo.calc_week_streak(p_week_start date, p_user_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'promo', 'public'
AS $function$
DECLARE
  v_today      date;
  v_scan_start date;
  v_day        date;
  v_streak     int := 0;
  v_minutes    int;
BEGIN
  v_today := ((now() AT TIME ZONE 'Europe/Berlin') - interval '4 hours')::date;
  v_scan_start := LEAST(v_today, p_week_start + 6);

  v_day := v_scan_start;
  WHILE v_day >= p_week_start LOOP
    v_minutes := NULL;
    SELECT minutes INTO v_minutes FROM study_days WHERE user_id = p_user_id AND date = v_day;

    IF COALESCE(v_minutes, 0) > 0 THEN
      v_streak := v_streak + 1;
    ELSIF v_day = v_today THEN
      NULL; -- heute noch leer, aber Tag ist noch nicht vorbei -> nicht abbrechen
    ELSE
      EXIT;
    END IF;

    v_day := v_day - 1;
  END LOOP;

  RETURN v_streak;
END;
$function$;

CREATE OR REPLACE FUNCTION promo.can_view_trade_offer(p_trade_offer_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'promo', 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM trade_offers o
    WHERE o.id = p_trade_offer_id
      AND (o.offerer_id = auth.uid() OR promo.owns_listing(o.listing_id))
  );
$function$;

CREATE OR REPLACE FUNCTION promo.cancel_listing(p_listing_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'promo', 'public'
AS $function$
BEGIN
  UPDATE card_listings
     SET status = 'cancelled'
   WHERE id = p_listing_id
     AND seller_id = auth.uid()
     AND status = 'active';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'listing_not_cancellable';
  END IF;

  -- Gegenangebote auf ein zurückgezogenes Angebot sind gegenstandslos.
  UPDATE trade_offers
     SET status = 'rejected', responded_at = now()
   WHERE listing_id = p_listing_id AND status = 'pending';
END;
$function$;

CREATE OR REPLACE FUNCTION promo.cancel_trade_offer(p_offer_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'promo', 'public'
AS $function$
BEGIN
  UPDATE trade_offers
     SET status = 'cancelled', responded_at = now()
   WHERE id = p_offer_id
     AND offerer_id = auth.uid()
     AND status = 'pending';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'offer_not_cancellable';
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION promo.claim_perfect_week()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'promo', 'public'
AS $function$
DECLARE
  v_today        date;
  v_week_start   date;
  v_reward       int;
  v_full_days    int;
  v_new_diamonds int;
BEGIN
  v_today      := ((now() AT TIME ZONE 'Europe/Berlin') - interval '4 hours')::date;
  v_week_start := date_trunc('week', (now() AT TIME ZONE 'Europe/Berlin') - interval '4 hours')::date;

  -- Verteidigung in der Tiefe: study_days-Schreibpfade validieren das Datum
  -- nicht gegen "heute" (siehe add_study_minutes-Vertrauensmodell in
  -- CLAUDE.md), daher zusätzlich verlangen, dass die Woche tatsächlich
  -- vorbei ist, bevor "alle 7 Tage" überhaupt geprüft wird.
  IF v_today < v_week_start + 6 THEN
    RAISE EXCEPTION 'week_not_over';
  END IF;

  IF EXISTS (
    SELECT 1 FROM perfect_week_claims WHERE user_id = auth.uid() AND week_start = v_week_start
  ) THEN
    RAISE EXCEPTION 'already_claimed';
  END IF;

  SELECT COUNT(*) INTO v_full_days
  FROM study_days
  WHERE user_id = auth.uid()
    AND date BETWEEN v_week_start AND v_week_start + 6
    AND minutes >= 60;

  IF v_full_days < 7 THEN
    RAISE EXCEPTION 'week_not_perfect';
  END IF;

  SELECT reward_diamonds INTO v_reward FROM perfect_week_config WHERE id = 1;

  INSERT INTO perfect_week_claims (user_id, week_start, reward_diamonds)
  VALUES (auth.uid(), v_week_start, v_reward);

  UPDATE profiles SET diamonds = diamonds + v_reward
  WHERE id = auth.uid()
  RETURNING diamonds INTO v_new_diamonds;

  RETURN v_new_diamonds;
END;
$function$;

CREATE OR REPLACE FUNCTION promo.claim_race_checkpoint(p_checkpoint text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'promo', 'public'
AS $function$
DECLARE
  v_today        date;
  v_minutes      int;
  v_threshold    int;
  v_reward       int;
  v_claimed_id   uuid;
  v_new_diamonds int;
BEGIN
  v_today := ((now() AT TIME ZONE 'Europe/Berlin') - interval '4 hours')::date;

  IF p_checkpoint = 'checkpoint60' THEN
    v_threshold := 60; v_reward := 1;
  ELSIF p_checkpoint = 'checkpoint180' THEN
    v_threshold := 180; v_reward := 1;
  ELSIF p_checkpoint = 'flag' THEN
    v_threshold := 280; v_reward := 1;   -- Feld 14 (RACE_FLAG_MINUTES)
  ELSIF p_checkpoint = 'finish' THEN
    v_threshold := 700; v_reward := 5;   -- echte Ziellinie (RACE_FINISH_MINUTES)
  ELSE
    RAISE EXCEPTION 'invalid_checkpoint';
  END IF;

  SELECT minutes INTO v_minutes FROM study_days WHERE user_id = auth.uid() AND date = v_today;
  IF COALESCE(v_minutes, 0) < v_threshold THEN
    RAISE EXCEPTION 'threshold_not_met';
  END IF;

  INSERT INTO race_checkpoint_claims (date, checkpoint, user_id, reward_diamonds)
  VALUES (v_today, p_checkpoint, auth.uid(), v_reward)
  ON CONFLICT (date, checkpoint) DO NOTHING
  RETURNING id INTO v_claimed_id;

  IF v_claimed_id IS NULL THEN
    RETURN NULL; -- schon vergeben (an jemand anderen oder System-Platzhalter) — kein Fehler
  END IF;

  UPDATE profiles SET diamonds = diamonds + v_reward
  WHERE id = auth.uid()
  RETURNING diamonds INTO v_new_diamonds;

  RETURN v_new_diamonds;
END;
$function$;

CREATE OR REPLACE FUNCTION promo.claim_set_bonus(p_rarity text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'promo', 'public'
AS $function$
DECLARE
  v_reward       int;
  v_total        int;
  v_owned        int;
  v_new_diamonds int;
BEGIN
  -- Reward-Höhe folgt der tatsächlichen Set-Schwierigkeit (Coupon-Collector-
  -- Erwartungswert aus Katalog-Größe x Ziehquote), nicht der reinen
  -- Rarität-Bezeichnung — "rare" (17 Karten, 30%) ist trotz gemäßigter
  -- Ziehquote das schwerste Set, "legendary" (3 Karten, 9%) ist dagegen
  -- vergleichsweise leicht komplettierbar.
  v_reward := CASE p_rarity
    WHEN 'common'    THEN 15
    WHEN 'legendary' THEN 20
    WHEN 'epic'      THEN 25
    WHEN 'mystic'    THEN 35
    WHEN 'rare'      THEN 50
    ELSE NULL
  END;
  IF v_reward IS NULL THEN RAISE EXCEPTION 'invalid_rarity'; END IF;

  IF EXISTS (
    SELECT 1 FROM set_bonus_claims WHERE user_id = auth.uid() AND rarity = p_rarity
  ) THEN
    RAISE EXCEPTION 'already_claimed';
  END IF;

  SELECT COUNT(*) INTO v_total FROM cards WHERE rarity = p_rarity;

  SELECT COUNT(DISTINCT card_id) INTO v_owned
  FROM user_cards
  WHERE user_id = auth.uid()
    AND card_id IN (SELECT id FROM cards WHERE rarity = p_rarity);

  IF v_owned < v_total THEN
    RAISE EXCEPTION 'set_not_complete';
  END IF;

  INSERT INTO set_bonus_claims (user_id, rarity, reward_diamonds)
  VALUES (auth.uid(), p_rarity, v_reward);

  UPDATE profiles SET diamonds = diamonds + v_reward
  WHERE id = auth.uid()
  RETURNING diamonds INTO v_new_diamonds;

  RETURN v_new_diamonds;
END;
$function$;

CREATE OR REPLACE FUNCTION promo.claim_streak_milestone(p_days integer)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'promo', 'public'
AS $function$
DECLARE
  v_milestone    record;
  v_streak       int;
  v_new_diamonds int;
BEGIN
  SELECT * INTO v_milestone FROM streak_milestones WHERE days = p_days;
  IF NOT FOUND THEN RAISE EXCEPTION 'milestone_not_found'; END IF;

  IF EXISTS (
    SELECT 1 FROM streak_milestone_claims WHERE user_id = auth.uid() AND days = p_days
  ) THEN
    RAISE EXCEPTION 'already_claimed';
  END IF;

  v_streak := calc_current_streak(auth.uid());
  IF v_streak < p_days THEN
    RAISE EXCEPTION 'threshold_not_met';
  END IF;

  INSERT INTO streak_milestone_claims (user_id, days, reward_diamonds)
  VALUES (auth.uid(), p_days, v_milestone.reward_diamonds);

  UPDATE profiles SET diamonds = diamonds + v_milestone.reward_diamonds
  WHERE id = auth.uid()
  RETURNING diamonds INTO v_new_diamonds;

  RETURN v_new_diamonds;
END;
$function$;

CREATE OR REPLACE FUNCTION promo.claim_weekly_challenge(p_challenge_key text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'promo', 'public'
AS $function$
DECLARE
  v_challenge    record;
  v_week_start   date;
  v_week_index   int;
  v_tier_offset  int;
  v_offset       int;
  v_progress     numeric;
  v_new_diamonds int;
BEGIN
  SELECT * INTO v_challenge FROM weekly_challenges WHERE challenge_key = p_challenge_key AND active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'challenge_not_found'; END IF;

  v_week_start := date_trunc('week', (now() AT TIME ZONE 'Europe/Berlin') - interval '4 hours')::date;
  v_week_index := floor((v_week_start - date '2024-01-01') / 7)::int;

  v_tier_offset := CASE v_challenge.tier WHEN 'leicht' THEN 0 WHEN 'mittel' THEN 2 WHEN 'schwer' THEN 4 END;
  v_offset := ((v_week_index + v_tier_offset) % 6 + 6) % 6;

  IF v_challenge.pool_index NOT IN (v_offset, (v_offset + 1) % 6, (v_offset + 2) % 6) THEN
    RAISE EXCEPTION 'challenge_not_active_this_week';
  END IF;

  IF EXISTS (
    SELECT 1 FROM weekly_challenge_claims
    WHERE user_id = auth.uid() AND week_start = v_week_start AND challenge_key = p_challenge_key
  ) THEN
    RAISE EXCEPTION 'already_claimed';
  END IF;

  IF v_challenge.metric_type = 'total_minutes' THEN
    SELECT COALESCE(SUM(minutes), 0) INTO v_progress
    FROM study_days WHERE user_id = auth.uid() AND date BETWEEN v_week_start AND v_week_start + 6;
  ELSIF v_challenge.metric_type = 'weekend_minutes' THEN
    SELECT COALESCE(SUM(minutes), 0) INTO v_progress
    FROM study_days
    WHERE user_id = auth.uid() AND date BETWEEN v_week_start AND v_week_start + 6
      AND extract(isodow FROM date) IN (6, 7);
  ELSIF v_challenge.metric_type = 'streak_days' THEN
    v_progress := calc_week_streak(v_week_start, auth.uid());
  ELSIF v_challenge.metric_type = 'count_days_threshold' THEN
    SELECT COUNT(*) INTO v_progress
    FROM study_days
    WHERE user_id = auth.uid() AND date BETWEEN v_week_start AND v_week_start + 6
      AND minutes >= v_challenge.param_h;
  END IF;

  IF v_progress < v_challenge.param_n THEN
    RAISE EXCEPTION 'threshold_not_met';
  END IF;

  INSERT INTO weekly_challenge_claims (user_id, week_start, challenge_key, reward_diamonds)
  VALUES (auth.uid(), v_week_start, p_challenge_key, v_challenge.reward_diamonds);

  UPDATE profiles SET diamonds = diamonds + v_challenge.reward_diamonds
  WHERE id = auth.uid()
  RETURNING diamonds INTO v_new_diamonds;

  RETURN v_new_diamonds;
END;
$function$;

CREATE OR REPLACE FUNCTION promo.create_clan(p_name text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'promo', 'public'
AS $function$
DECLARE v_clan_id uuid;
BEGIN
  IF EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND clan_id IS NOT NULL) THEN
    RAISE EXCEPTION 'already_in_clan';
  END IF;
  INSERT INTO clans (name, leader_id) VALUES (p_name, auth.uid()) RETURNING id INTO v_clan_id;
  UPDATE profiles SET clan_id = v_clan_id, clan_role = 'leader' WHERE id = auth.uid();
  RETURN v_clan_id;
END;
$function$;

CREATE OR REPLACE FUNCTION promo.create_listing(p_card_id integer)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'promo', 'public'
AS $function$
DECLARE
  v_user_card_id uuid;
  v_listing_id   uuid;
BEGIN
  -- Älteste noch nicht aktiv gelistete Kopie dieser Karte finden.
  -- Keine Mindestbestand-Prüfung — auch die letzte Kopie ist listbar.
  SELECT id INTO v_user_card_id
  FROM user_cards
  WHERE user_id = auth.uid()
    AND card_id = p_card_id
    AND id NOT IN (SELECT user_card_id FROM card_listings WHERE status = 'active')
  ORDER BY obtained_at ASC
  LIMIT 1;

  IF v_user_card_id IS NULL THEN
    RAISE EXCEPTION 'no_available_copy';
  END IF;

  INSERT INTO card_listings (seller_id, user_card_id, card_id)
  VALUES (auth.uid(), v_user_card_id, p_card_id)
  RETURNING id INTO v_listing_id;

  RETURN v_listing_id;
END;
$function$;

CREATE OR REPLACE FUNCTION promo.create_trade_offer(p_listing_id uuid, p_offered_card_ids integer[])
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'promo', 'public'
AS $function$
DECLARE
  v_listing      card_listings%ROWTYPE;
  v_offer_id     uuid;
  v_card_id      int;
  v_user_card_id uuid;
BEGIN
  IF p_offered_card_ids IS NULL OR array_length(p_offered_card_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'no_cards_offered';
  END IF;

  SELECT * INTO v_listing FROM card_listings WHERE id = p_listing_id AND status = 'active';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'listing_not_available';
  END IF;

  IF v_listing.seller_id = auth.uid() THEN
    RAISE EXCEPTION 'cannot_offer_on_own_listing';
  END IF;

  IF EXISTS (
    SELECT 1 FROM trade_offers
    WHERE offerer_id = auth.uid() AND listing_id = p_listing_id AND status = 'pending'
  ) THEN
    RAISE EXCEPTION 'offer_already_pending';
  END IF;

  INSERT INTO trade_offers (listing_id, offerer_id)
  VALUES (p_listing_id, auth.uid())
  RETURNING id INTO v_offer_id;

  FOREACH v_card_id IN ARRAY p_offered_card_ids LOOP
    -- Älteste eigene Kopie dieser Karte, die weder aktiv gelistet noch
    -- Teil irgendeines *aktuell pending* Gegenangebots ist — verhindert,
    -- dieselbe physische Karte doppelt zu verplanen, ohne bereits
    -- abgeschlossene (angenommene/abgelehnte/zurückgezogene) Gegenangebote
    -- dauerhaft zu blockieren.
    SELECT id INTO v_user_card_id
    FROM user_cards
    WHERE user_id = auth.uid()
      AND card_id = v_card_id
      AND id NOT IN (SELECT user_card_id FROM card_listings WHERE status = 'active')
      AND id NOT IN (
        SELECT toc.user_card_id
        FROM trade_offer_cards toc
        JOIN trade_offers o ON o.id = toc.trade_offer_id
        WHERE o.status = 'pending'
      )
    ORDER BY obtained_at ASC
    LIMIT 1;

    IF v_user_card_id IS NULL THEN
      RAISE EXCEPTION 'card_not_available';
    END IF;

    INSERT INTO trade_offer_cards (trade_offer_id, user_card_id, card_id)
    VALUES (v_offer_id, v_user_card_id, v_card_id);
  END LOOP;

  RETURN v_offer_id;
END;
$function$;

CREATE OR REPLACE FUNCTION promo.credit_elapsed_timer_state(p_row timer_state, p_cutoff timestamp with time zone, p_reason text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'promo', 'public'
AS $function$
DECLARE
  v_session_start timestamptz;
  v_elapsed_sec   numeric;
  v_credit_min    integer;
BEGIN
  IF p_row.pomoday IS NULL THEN RETURN; END IF;

  IF p_row.limitless THEN
    IF p_row.started_at IS NOT NULL THEN
      v_elapsed_sec := extract(epoch FROM (p_cutoff - p_row.started_at));
      v_credit_min := greatest(0, floor(v_elapsed_sec / 60)::int - coalesce(p_row.credited_min, 0));
    ELSE
      -- pausierte Stoppuhr: paused_remaining hält bereits verstrichene Sekunden
      v_credit_min := greatest(0, floor(coalesce(p_row.paused_remaining, 0) / 60)::int - coalesce(p_row.credited_min, 0));
    END IF;
  ELSE
    IF p_row.end_at IS NOT NULL THEN
      v_session_start := p_row.end_at - make_interval(secs => p_row.total_sec);
      v_elapsed_sec := extract(epoch FROM (p_cutoff - v_session_start));
      v_credit_min := floor(least(v_elapsed_sec, p_row.total_sec) / 60)::int;
    ELSE
      -- pausierter Countdown
      v_credit_min := floor((p_row.total_sec - coalesce(p_row.paused_remaining, 0)) / 60)::int;
    END IF;
  END IF;

  IF v_credit_min > 0 THEN
    IF p_row.limitless THEN
      INSERT INTO pending_focus_sessions (user_id, date, minutes, label, reason)
      VALUES (p_row.user_id, p_row.pomoday, v_credit_min, 'not specified', p_reason);
    ELSE
      INSERT INTO study_days (user_id, date, minutes)
      VALUES (p_row.user_id, p_row.pomoday, v_credit_min)
      ON CONFLICT (user_id, date) DO UPDATE SET minutes = study_days.minutes + v_credit_min;

      INSERT INTO pomodoro_sessions (user_id, date, label, duration_minutes)
      VALUES (p_row.user_id, p_row.pomoday, 'not specified', v_credit_min);
    END IF;
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION promo.draw_card(p_mystic boolean DEFAULT false)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'promo', 'public'
AS $function$
DECLARE
  v_roll    float;
  v_rarity  text;
  v_card_id int;
BEGIN
  v_roll := random();

  IF p_mystic THEN
    -- Mystisches Ei: nur legendary (30%) / mystic (70%)
    IF v_roll < 0.30 THEN v_rarity := 'legendary';
    ELSE                   v_rarity := 'mystic';
    END IF;
  ELSE
    -- Normales Ei: unveränderte Verteilung
    IF    v_roll < 0.40 THEN v_rarity := 'common';
    ELSIF v_roll < 0.70 THEN v_rarity := 'rare';
    ELSIF v_roll < 0.88 THEN v_rarity := 'epic';
    ELSIF v_roll < 0.97 THEN v_rarity := 'legendary';
    ELSE                      v_rarity := 'mystic';
    END IF;
  END IF;

  SELECT id INTO v_card_id
  FROM cards
  WHERE rarity = v_rarity
  ORDER BY random()
  LIMIT 1;

  INSERT INTO user_cards (user_id, card_id)
  VALUES (auth.uid(), v_card_id);

  RETURN v_card_id;
END;
$function$;

CREATE OR REPLACE FUNCTION promo.get_clan_members()
 RETURNS TABLE(id uuid, username text, clan_role text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'promo', 'public'
AS $function$
  DECLARE v_clan_id uuid;
  BEGIN
    SELECT clan_id INTO v_clan_id FROM profiles WHERE id = auth.uid();
    IF v_clan_id IS NULL THEN RETURN; END IF;
    RETURN QUERY
      SELECT p.id, p.username, p.clan_role
      FROM profiles p
      WHERE p.clan_id = v_clan_id
      ORDER BY p.username;
  END; $function$;

CREATE OR REPLACE FUNCTION promo.get_incoming_trade_offers()
 RETURNS TABLE(offer_id uuid, listing_id uuid, card_id integer, offerer_username text, created_at timestamp with time zone)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'promo', 'public'
AS $function$
  SELECT o.id, o.listing_id, l.card_id, p.username, o.created_at
  FROM trade_offers o
  JOIN card_listings l ON l.id = o.listing_id
  JOIN profiles p ON p.id = o.offerer_id
  WHERE l.seller_id = auth.uid() AND o.status = 'pending'
  ORDER BY o.created_at DESC;
$function$;

CREATE OR REPLACE FUNCTION promo.get_label_stats(p_user_id uuid)
 RETURNS TABLE(label text, today_minutes bigint, week_minutes bigint, month_minutes bigint, alltime_minutes bigint)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'promo', 'public'
AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION promo.get_library_checkins()
 RETURNS TABLE(name text, avatar_url text, library text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'promo', 'public'
AS $function$
  SELECT p.username, p.avatar_url, p.library_checkin
  FROM profiles p
  WHERE p.public = true
    AND p.clan_id = my_clan_id()
    AND p.library_checkin IS NOT NULL
    AND p.library_checkin_date = ((now() AT TIME ZONE 'Europe/Berlin') - interval '4 hours')::date;
$function$;

CREATE OR REPLACE FUNCTION promo.get_member_cards(p_username text)
 RETURNS TABLE(card_id integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'promo', 'public'
AS $function$
  SELECT uc.card_id
  FROM user_cards uc
  JOIN profiles p ON p.id = uc.user_id
  WHERE p.username  = p_username
    AND p.public    = true
    AND p.clan_id   = my_clan_id()
  ORDER BY uc.obtained_at;
$function$;

CREATE OR REPLACE FUNCTION promo.get_mensa_checkins()
 RETURNS TABLE(name text, avatar_url text, mensa text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'promo', 'public'
AS $function$
  SELECT p.username, p.avatar_url, p.mensa_checkin
  FROM profiles p
  WHERE p.public = true
    AND p.clan_id = my_clan_id()
    AND p.mensa_checkin IS NOT NULL
    AND p.mensa_checkin_date = ((now() AT TIME ZONE 'Europe/Berlin') - interval '4 hours')::date;
$function$;

CREATE OR REPLACE FUNCTION promo.get_yesterday_winner()
 RETURNS TABLE(username text, minutes integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'promo', 'public'
AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION promo.has_active_listing(p_user_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'promo', 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM card_listings WHERE seller_id = p_user_id AND status = 'active'
  );
$function$;

CREATE OR REPLACE FUNCTION promo.leaderboard_aggregated(date_from date)
 RETURNS TABLE(name text, minutes bigint, alltime_minutes bigint, diamonds integer, avatar_url text, timer_active boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'promo', 'public'
AS $function$
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
    p.avatar_url,
    COALESCE((
      SELECT ts.mode = 'work' AND (
        (ts.end_at IS NOT NULL AND ts.end_at > now())
        OR (ts.limitless AND ts.started_at IS NOT NULL)
      )
      FROM timer_state ts WHERE ts.user_id = p.id LIMIT 1
    ), false)                                              AS timer_active
  FROM profiles p
  WHERE p.public = true
    AND p.clan_id = my_clan_id()
  ORDER BY minutes DESC, alltime_minutes DESC;
$function$;

CREATE OR REPLACE FUNCTION promo.leaderboard_today()
 RETURNS TABLE(name text, minutes integer, alltime_minutes bigint, diamonds integer, avatar_url text, timer_active boolean, race_car_id smallint)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'promo', 'public'
AS $function$
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
    p.avatar_url,
    COALESCE((
      SELECT ts.mode = 'work' AND (
        (ts.end_at IS NOT NULL AND ts.end_at > now())
        OR (ts.limitless AND ts.started_at IS NOT NULL)
      )
      FROM timer_state ts WHERE ts.user_id = p.id LIMIT 1
    ), false)                                              AS timer_active,
    p.race_car_id
  FROM profiles p
  CROSS JOIN today
  JOIN study_days sd_today
    ON sd_today.user_id = p.id AND sd_today.date = today.d AND sd_today.minutes > 0
  WHERE p.public = true
    AND p.clan_id = my_clan_id()
  ORDER BY minutes DESC, alltime_minutes DESC;
$function$;

CREATE OR REPLACE FUNCTION promo.leaderboard_wins()
 RETURNS TABLE(name text, gold integer, silver integer, bronze integer, total integer, alltime_minutes bigint, avatar_url text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'promo', 'public'
AS $function$
  WITH ref AS (
    SELECT
      '2026-05-04'::date AS start_date,
      ((now() AT TIME ZONE 'Europe/Berlin') - interval '4 hours')::date AS today
  ),
  daily_ranks AS (
    SELECT
      sd.user_id,
      DENSE_RANK() OVER (PARTITION BY sd.date ORDER BY sd.minutes DESC) AS day_rank
    FROM study_days sd
    JOIN profiles p ON p.id = sd.user_id
    CROSS JOIN ref
    WHERE sd.date   >= ref.start_date
      AND sd.date    < ref.today
      AND sd.minutes > 0
      AND p.public   = true
      AND p.clan_id  = my_clan_id()
  ),
  medals AS (
    SELECT
      user_id,
      COUNT(*) FILTER (WHERE day_rank = 1)::int AS gold,
      COUNT(*) FILTER (WHERE day_rank = 2)::int AS silver,
      COUNT(*) FILTER (WHERE day_rank = 3)::int AS bronze
    FROM daily_ranks
    GROUP BY user_id
  )
  SELECT
    p.username                                                              AS name,
    m.gold,
    m.silver,
    m.bronze,
    (m.gold + m.silver + m.bronze)::int                                    AS total,
    COALESCE((
      SELECT SUM(sd2.minutes) FROM study_days sd2 WHERE sd2.user_id = p.id
    ), 0)::bigint                                                           AS alltime_minutes,
    p.avatar_url
  FROM medals m
  JOIN profiles p ON p.id = m.user_id
  WHERE m.gold + m.silver + m.bronze > 0
  ORDER BY m.gold DESC, m.silver DESC, m.bronze DESC, alltime_minutes DESC;
$function$;

CREATE OR REPLACE FUNCTION promo.log_study_days_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'promo', 'public'
AS $function$
DECLARE
  uname text;
BEGIN
  SELECT username INTO uname FROM profiles WHERE id = NEW.user_id;

  IF TG_OP = 'INSERT' THEN
    INSERT INTO study_days_log (user_id, username, date, minutes_before, minutes_after, minutes_delta, action)
    VALUES (NEW.user_id, uname, NEW.date, 0, NEW.minutes, NEW.minutes, 'insert');
  ELSIF TG_OP = 'UPDATE' THEN
    INSERT INTO study_days_log (user_id, username, date, minutes_before, minutes_after, minutes_delta, action)
    VALUES (NEW.user_id, uname, NEW.date, OLD.minutes, NEW.minutes, NEW.minutes - OLD.minutes, 'update');
  END IF;

  DELETE FROM study_days_log WHERE logged_at < now() - interval '48 hours';

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION promo.my_clan_id()
 RETURNS uuid
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'promo', 'public'
AS $function$
    SELECT clan_id FROM profiles WHERE id = auth.uid();
  $function$;

CREATE OR REPLACE FUNCTION promo.owns_listing(p_listing_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'promo', 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM card_listings WHERE id = p_listing_id AND seller_id = auth.uid()
  );
$function$;

CREATE OR REPLACE FUNCTION promo.recap_available()
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'promo', 'public'
AS $function$
  select ((now() at time zone 'Europe/Berlin') - interval '4 hours')::date >= date '2026-10-04'
     or exists (
       select 1 from promo.profiles
       where id = auth.uid() and recap_test_early_access = true
     );
$function$;

CREATE OR REPLACE FUNCTION promo.remove_clan_member(p_user_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'promo', 'public'
AS $function$
DECLARE v_clan_id uuid;
BEGIN
  SELECT clan_id INTO v_clan_id FROM profiles WHERE id = auth.uid();
  IF NOT EXISTS (SELECT 1 FROM clans WHERE id = v_clan_id AND leader_id = auth.uid()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF p_user_id = auth.uid() THEN RAISE EXCEPTION 'Cannot remove yourself'; END IF;
  UPDATE profiles SET clan_id = NULL, clan_role = NULL
    WHERE id = p_user_id AND clan_id = v_clan_id;
END; $function$;

CREATE OR REPLACE FUNCTION promo.reset_stale_work_sessions()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'promo', 'public'
AS $function$
DECLARE
  r record;
  v_deleted timer_state%ROWTYPE;
  v_boundary timestamptz;
  v_cap timestamptz;
  v_trigger_boundary boolean;
  v_trigger_idle boolean;
  v_reason text;
BEGIN
  FOR r IN
    SELECT * FROM timer_state
    WHERE mode = 'work' AND pomoday IS NOT NULL
      AND (end_at IS NOT NULL OR started_at IS NOT NULL OR paused_remaining IS NOT NULL)
  LOOP
    -- 4:00 Berlin am Tag nach pomoday, DST-sicher via AT TIME ZONE
    v_boundary := (r.pomoday + 1) + time '04:00' AT TIME ZONE 'Europe/Berlin';
    v_trigger_boundary := now() >= v_boundary;

    IF v_trigger_boundary AND NOT r.limitless AND r.end_at IS NOT NULL AND r.end_at <= v_boundary THEN
      CONTINUE; -- wäre vor 4 Uhr regulär fertig geworden, nicht unser Fall
    END IF;

    v_trigger_idle := r.limitless AND r.started_at IS NOT NULL AND r.unbroken_since IS NOT NULL
                       AND now() >= r.unbroken_since + interval '3h10min';

    IF NOT v_trigger_boundary AND NOT v_trigger_idle THEN CONTINUE; END IF;
    v_reason := CASE WHEN v_trigger_boundary THEN 'day_boundary' ELSE 'idle_3h' END;

    -- Claim-Mutex: nur weiterrechnen, wenn DIESER Aufruf die Zeile wirklich
    -- noch löscht — sonst hat der Client (oder ein paralleler Cron-Lauf)
    -- sie bereits beansprucht.
    DELETE FROM timer_state WHERE user_id = r.user_id
    RETURNING * INTO v_deleted;
    IF NOT FOUND THEN CONTINUE; END IF;

    v_cap := LEAST(now(), v_boundary);
    PERFORM promo.credit_elapsed_timer_state(v_deleted, v_cap, v_reason);
  END LOOP;
END;
$function$;

CREATE OR REPLACE FUNCTION promo.respond_to_clan_request(p_request_id uuid, p_accept boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'promo', 'public'
AS $function$
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
END; $function$;

CREATE OR REPLACE FUNCTION promo.respond_to_trade_offer(p_offer_id uuid, p_accept boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'promo', 'public'
AS $function$
DECLARE
  v_offer                 trade_offers%ROWTYPE;
  v_listing                card_listings%ROWTYPE;
  v_expected_offered_count int;
  v_moved_offered_count    int;
  v_moved_ids              uuid[];
BEGIN
  SELECT * INTO v_offer FROM trade_offers WHERE id = p_offer_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'offer_not_found';
  END IF;

  SELECT * INTO v_listing FROM card_listings WHERE id = v_offer.listing_id;
  IF NOT FOUND OR v_listing.seller_id <> auth.uid() THEN
    RAISE EXCEPTION 'not_listing_owner';
  END IF;

  -- Claim-Mutex: nur der erste Accept/Reject auf ein noch pending Angebot gewinnt.
  UPDATE trade_offers
     SET status = CASE WHEN p_accept THEN 'accepted' ELSE 'rejected' END,
         responded_at = now()
   WHERE id = p_offer_id AND status = 'pending'
  RETURNING * INTO v_offer;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'offer_not_pending';
  END IF;

  IF NOT p_accept THEN
    RETURN;
  END IF;

  -- Listing-Claim-Mutex active→traded (Verteidigung; kann durch obigen
  -- Offer-Mutex + Seller-Check eigentlich nur active sein).
  UPDATE card_listings
     SET status = 'traded', traded_at = now()
   WHERE id = v_listing.id AND status = 'active'
  RETURNING * INTO v_listing;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'listing_no_longer_active';
  END IF;

  -- Gelistete Karte → Offerer
  UPDATE user_cards
     SET user_id = v_offer.offerer_id, obtained_at = now()
   WHERE id = v_listing.user_card_id AND user_id = v_listing.seller_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'source_card_missing';
  END IF;

  -- Angebotene Karten → Seller (Guard: Offerer könnte eine der Karten
  -- inzwischen über einen anderen akzeptierten Tausch verloren haben —
  -- rollt in diesem Fall die gesamte Transaktion zurück).
  SELECT count(*) INTO v_expected_offered_count
  FROM trade_offer_cards WHERE trade_offer_id = v_offer.id;

  UPDATE user_cards uc
     SET user_id = v_listing.seller_id, obtained_at = now()
    FROM trade_offer_cards toc
   WHERE toc.trade_offer_id = v_offer.id
     AND uc.id = toc.user_card_id
     AND uc.user_id = v_offer.offerer_id;
  GET DIAGNOSTICS v_moved_offered_count = ROW_COUNT;

  IF v_moved_offered_count <> v_expected_offered_count THEN
    RAISE EXCEPTION 'offered_card_missing';
  END IF;

  -- Unveränderliches Audit-Log: eine Zeile pro bewegter Karte
  INSERT INTO card_trades (listing_id, seller_id, buyer_id, card_id, user_card_id, trade_offer_id)
  VALUES (v_listing.id, v_listing.seller_id, v_offer.offerer_id, v_listing.card_id, v_listing.user_card_id, v_offer.id);

  INSERT INTO card_trades (listing_id, seller_id, buyer_id, card_id, user_card_id, trade_offer_id)
  SELECT v_listing.id, v_offer.offerer_id, v_listing.seller_id, toc.card_id, toc.user_card_id, v_offer.id
  FROM trade_offer_cards toc
  WHERE toc.trade_offer_id = v_offer.id;

  -- Cleanup-Kaskade: alle Angebote/Gegenangebote, die mit den soeben
  -- bewegten physischen Karten zusammenhängen, sind gegenstandslos.
  SELECT array_agg(user_card_id) INTO v_moved_ids
  FROM (
    SELECT v_listing.user_card_id AS user_card_id
    UNION ALL
    SELECT user_card_id FROM trade_offer_cards WHERE trade_offer_id = v_offer.id
  ) moved;

  UPDATE card_listings
     SET status = 'cancelled'
   WHERE user_card_id = ANY(v_moved_ids) AND status = 'active';

  UPDATE trade_offers
     SET status = 'rejected', responded_at = now()
   WHERE status = 'pending'
     AND (
       listing_id = v_listing.id
       OR id IN (SELECT trade_offer_id FROM trade_offer_cards WHERE user_card_id = ANY(v_moved_ids))
     );
END;
$function$;

CREATE OR REPLACE FUNCTION promo.sell_card(p_card_id integer)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'promo', 'public'
AS $function$
DECLARE
  v_rarity text; v_reward int; v_row_id uuid; v_count int; v_new_diamonds int;
  v_cancelled_ids uuid[];
BEGIN
  SELECT rarity INTO v_rarity FROM cards WHERE id = p_card_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'card_not_found'; END IF;

  v_reward := CASE v_rarity
    WHEN 'common' THEN 4 WHEN 'rare' THEN 8 WHEN 'epic' THEN 12
    WHEN 'legendary' THEN 16 WHEN 'mystic' THEN 20 ELSE 0
  END;

  SELECT COUNT(*) INTO v_count FROM user_cards WHERE user_id = auth.uid() AND card_id = p_card_id;
  IF v_count < 2 THEN RAISE EXCEPTION 'not_enough_copies'; END IF;

  -- Eigene aktive Listings dieser Karte zurückziehen + offene
  -- Gegenangebote darauf ablehnen (identisches Muster wie cancel_listing()).
  WITH cancelled AS (
    UPDATE card_listings
       SET status = 'cancelled'
     WHERE seller_id = auth.uid() AND card_id = p_card_id AND status = 'active'
    RETURNING id
  )
  SELECT array_agg(id) INTO v_cancelled_ids FROM cancelled;

  IF v_cancelled_ids IS NOT NULL THEN
    UPDATE trade_offers
       SET status = 'rejected', responded_at = now()
     WHERE listing_id = ANY(v_cancelled_ids) AND status = 'pending';
  END IF;

  -- Keine aktive Listung dieser card_id existiert an dieser Stelle mehr
  -- (gerade oben zurückgezogen) — einfach die älteste Kopie wählen.
  SELECT id INTO v_row_id
  FROM user_cards
  WHERE user_id = auth.uid() AND card_id = p_card_id
  ORDER BY obtained_at ASC
  LIMIT 1;

  DELETE FROM user_cards WHERE id = v_row_id;
  UPDATE profiles SET diamonds = diamonds + v_reward WHERE id = auth.uid() RETURNING diamonds INTO v_new_diamonds;
  RETURN v_new_diamonds;
END;
$function$;

CREATE OR REPLACE FUNCTION promo.submit_join_request()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'promo', 'public'
AS $function$
  DECLARE v_clan_id uuid;
  BEGIN
    IF EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND clan_id IS NOT NULL) THEN
  RETURN; END IF;
    SELECT id INTO v_clan_id FROM clans LIMIT 1;
    IF NOT FOUND THEN RETURN; END IF;
    INSERT INTO clan_requests (clan_id, user_id)
      VALUES (v_clan_id, auth.uid())
      ON CONFLICT DO NOTHING;
  END; $function$;

CREATE OR REPLACE FUNCTION promo.submit_join_request_to(p_clan_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'promo', 'public'
AS $function$
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
$function$;

GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA promo TO anon, authenticated, service_role;

-- ── RLS wie in public ──
ALTER TABLE promo.study_days ENABLE ROW LEVEL SECURITY;
ALTER TABLE promo.study_days_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE promo.pomodoro_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE promo.timer_state ENABLE ROW LEVEL SECURITY;
ALTER TABLE promo.pending_focus_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE promo.tired_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE promo.incubator ENABLE ROW LEVEL SECURITY;
ALTER TABLE promo.user_cards ENABLE ROW LEVEL SECURITY;
ALTER TABLE promo.card_listings ENABLE ROW LEVEL SECURITY;
ALTER TABLE promo.card_trades ENABLE ROW LEVEL SECURITY;
ALTER TABLE promo.trade_offers ENABLE ROW LEVEL SECURITY;
ALTER TABLE promo.trade_offer_cards ENABLE ROW LEVEL SECURITY;
ALTER TABLE promo.weekly_challenge_claims ENABLE ROW LEVEL SECURITY;
ALTER TABLE promo.streak_milestone_claims ENABLE ROW LEVEL SECURITY;
ALTER TABLE promo.perfect_week_claims ENABLE ROW LEVEL SECURITY;
ALTER TABLE promo.set_bonus_claims ENABLE ROW LEVEL SECURITY;
ALTER TABLE promo.race_checkpoint_claims ENABLE ROW LEVEL SECURITY;
ALTER TABLE promo.daily_winners ENABLE ROW LEVEL SECURITY;
CREATE POLICY "card_listings_select" ON promo.card_listings AS PERMISSIVE FOR SELECT TO public USING (((status = 'active'::text) OR (seller_id = auth.uid())));
CREATE POLICY "card_trades_select_own" ON promo.card_trades AS PERMISSIVE FOR SELECT TO public USING (((seller_id = auth.uid()) OR (buyer_id = auth.uid())));
CREATE POLICY "Jeder kann lesen" ON promo.daily_winners AS PERMISSIVE FOR SELECT TO public USING (true);
CREATE POLICY "Service kann schreiben" ON promo.daily_winners AS PERMISSIVE FOR INSERT TO service_role WITH CHECK (true);
CREATE POLICY "incubator_own" ON promo.incubator AS PERMISSIVE FOR ALL TO public USING ((auth.uid() = user_id));
CREATE POLICY "pending_focus_sessions_insert" ON promo.pending_focus_sessions AS PERMISSIVE FOR INSERT TO public WITH CHECK ((auth.uid() = user_id));
CREATE POLICY "pending_focus_sessions_select" ON promo.pending_focus_sessions AS PERMISSIVE FOR SELECT TO public USING ((auth.uid() = user_id));
CREATE POLICY "pending_focus_sessions_delete" ON promo.pending_focus_sessions AS PERMISSIVE FOR DELETE TO public USING ((auth.uid() = user_id));
CREATE POLICY "perfect_week_claims_select_own" ON promo.perfect_week_claims AS PERMISSIVE FOR SELECT TO public USING ((auth.uid() = user_id));
CREATE POLICY "Users can insert own sessions" ON promo.pomodoro_sessions AS PERMISSIVE FOR INSERT TO public WITH CHECK ((auth.uid() = user_id));
CREATE POLICY "Users can update own sessions" ON promo.pomodoro_sessions AS PERMISSIVE FOR UPDATE TO public USING ((auth.uid() = user_id)) WITH CHECK ((auth.uid() = user_id));
CREATE POLICY "Users can view own sessions" ON promo.pomodoro_sessions AS PERMISSIVE FOR SELECT TO public USING ((auth.uid() = user_id));
CREATE POLICY "race_checkpoint_claims_select_all" ON promo.race_checkpoint_claims AS PERMISSIVE FOR SELECT TO public USING (true);
CREATE POLICY "set_bonus_claims_select_own" ON promo.set_bonus_claims AS PERMISSIVE FOR SELECT TO public USING ((auth.uid() = user_id));
CREATE POLICY "streak_milestone_claims_select_own" ON promo.streak_milestone_claims AS PERMISSIVE FOR SELECT TO public USING ((auth.uid() = user_id));
CREATE POLICY "Eigene Tage löschen" ON promo.study_days AS PERMISSIVE FOR DELETE TO public USING ((auth.uid() = user_id));
CREATE POLICY "Eigene Tage schreiben" ON promo.study_days AS PERMISSIVE FOR INSERT TO public WITH CHECK ((auth.uid() = user_id));
CREATE POLICY "Eigene Tage lesen" ON promo.study_days AS PERMISSIVE FOR SELECT TO public USING ((auth.uid() = user_id));
CREATE POLICY "Eigene Tage updaten" ON promo.study_days AS PERMISSIVE FOR UPDATE TO public USING ((auth.uid() = user_id));
CREATE POLICY "Eigener Timer" ON promo.timer_state AS PERMISSIVE FOR ALL TO public USING ((auth.uid() = user_id));
CREATE POLICY "tired_events_select" ON promo.tired_events AS PERMISSIVE FOR SELECT TO public USING ((auth.uid() = user_id));
CREATE POLICY "tired_events_insert" ON promo.tired_events AS PERMISSIVE FOR INSERT TO public WITH CHECK ((auth.uid() = user_id));
CREATE POLICY "trade_offer_cards_select" ON promo.trade_offer_cards AS PERMISSIVE FOR SELECT TO public USING (promo.can_view_trade_offer(trade_offer_id));
CREATE POLICY "trade_offers_select" ON promo.trade_offers AS PERMISSIVE FOR SELECT TO public USING (((offerer_id = auth.uid()) OR promo.owns_listing(listing_id)));
CREATE POLICY "user_cards_select_own" ON promo.user_cards AS PERMISSIVE FOR SELECT TO public USING ((auth.uid() = user_id));
CREATE POLICY "weekly_challenge_claims_select_own" ON promo.weekly_challenge_claims AS PERMISSIVE FOR SELECT TO public USING ((auth.uid() = user_id));
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE promo.study_days TO anon, authenticated;
GRANT ALL ON TABLE promo.study_days TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE promo.study_days_log TO anon, authenticated;
GRANT ALL ON TABLE promo.study_days_log TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE promo.pomodoro_sessions TO anon, authenticated;
GRANT ALL ON TABLE promo.pomodoro_sessions TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE promo.timer_state TO anon, authenticated;
GRANT ALL ON TABLE promo.timer_state TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE promo.pending_focus_sessions TO anon, authenticated;
GRANT ALL ON TABLE promo.pending_focus_sessions TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE promo.tired_events TO anon, authenticated;
GRANT ALL ON TABLE promo.tired_events TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE promo.incubator TO anon, authenticated;
GRANT ALL ON TABLE promo.incubator TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE promo.user_cards TO anon, authenticated;
GRANT ALL ON TABLE promo.user_cards TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE promo.card_listings TO anon, authenticated;
GRANT ALL ON TABLE promo.card_listings TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE promo.card_trades TO anon, authenticated;
GRANT ALL ON TABLE promo.card_trades TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE promo.trade_offers TO anon, authenticated;
GRANT ALL ON TABLE promo.trade_offers TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE promo.trade_offer_cards TO anon, authenticated;
GRANT ALL ON TABLE promo.trade_offer_cards TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE promo.weekly_challenge_claims TO anon, authenticated;
GRANT ALL ON TABLE promo.weekly_challenge_claims TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE promo.streak_milestone_claims TO anon, authenticated;
GRANT ALL ON TABLE promo.streak_milestone_claims TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE promo.perfect_week_claims TO anon, authenticated;
GRANT ALL ON TABLE promo.perfect_week_claims TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE promo.set_bonus_claims TO anon, authenticated;
GRANT ALL ON TABLE promo.set_bonus_claims TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE promo.race_checkpoint_claims TO anon, authenticated;
GRANT ALL ON TABLE promo.race_checkpoint_claims TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE promo.daily_winners TO anon, authenticated;
GRANT ALL ON TABLE promo.daily_winners TO service_role;

CREATE TRIGGER study_days_audit AFTER INSERT OR UPDATE ON promo.study_days
  FOR EACH ROW EXECUTE FUNCTION promo.log_study_days_change();

-- ── pg_cron: Promo-Gegenstücke ──
SELECT cron.schedule('promo-reset-stale-work-sessions', '*/5 * * * *',
  $cron$ SELECT promo.reset_stale_work_sessions(); $cron$);

SELECT cron.schedule('promo-cleanup-study-log', '0 * * * *',
  $cron$ delete from promo.study_days_log where logged_at < now() - interval '48 hours'; $cron$);

SELECT cron.schedule('promo-daily-winners', '2-59/5 * * * *', $cron$
    with today_de as (
      select (now() at time zone 'Europe/Berlin')::date - 1 as d
      where extract(hour from now() at time zone 'Europe/Berlin') >= 4
    ),
    ranked as (
      select
        p.id as user_id, p.username,
        sum(s.minutes)::integer as minutes,
        row_number() over (order by sum(s.minutes) desc, random()) as rn
      from promo.study_days s
      join public.profiles p on p.id = s.user_id
      cross join today_de
      where s.date = today_de.d
        and p.public is true
        and s.off is not true
        and s.minutes > 0
      group by p.id, p.username
    ),
    inserted as (
      insert into promo.daily_winners (date, rank, user_id, username, minutes)
      select (select d from today_de), rn, user_id, username, minutes
      from ranked where rn <= 3
      on conflict (date, rank) do nothing
      returning user_id, rank
    )
    update promo.wallets w set
      diamonds = w.diamonds + case i.rank when 1 then 3 when 2 then 2 when 3 then 1 end
    from inserted i
    where w.user_id = i.user_id;
$cron$);

RESET check_function_bodies;
RESET search_path;
NOTIFY pgrst, 'reload schema';
