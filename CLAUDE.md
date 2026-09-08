# Pomodoro — Codebase Guide

## Architektur

Single-file [[PWA]]: `index.html` (~4500 Zeilen) + `sw.js` ([[Service Worker]]). Kein Build-System, kein Framework.
Backend: [[Supabase]] (Postgres + Auth + Storage).

**Kein Supabase JS SDK.** Alle API-Calls laufen über direktes `fetch` mit `getValidToken()` + `authHeaders(token)`. Niemals `supabase.rpc(...)` oder `supabase.from(...)` verwenden — diese Variablen existieren nicht.

Alles JS läuft in einer einzigen IIFE am Ende von `index.html`.

---

## Supabase

```
URL:  https://cmbyzzfjzrhdxylopqkt.supabase.co
Key:  sb_publishable_6nyRZ6qvp--XRZZH3t6L0Q_ofNkwTgj  (anon/public)
```

### Migrationen anwenden

Supabase CLI ist lokal installiert (Homebrew, `supabase/tap`) und mit diesem Projekt verlinkt (`supabase link`, Ref `cmbyzzfjzrhdxylopqkt`). Neue `.sql`-Dateien in `supabase/migrations/` werden direkt per `supabase db push` angewendet — kein manuelles Copy-Paste in den SQL-Editor mehr nötig (Stand 2026-07-29, davor wurden alle Migrationen manuell eingefügt). `supabase migration list` zeigt den Sync-Status (Local vs. Remote), `supabase db push --dry-run` previewt ohne Anwenden. Bei destruktiven/datenverändernden Migrationen (`DROP TABLE`/`DROP COLUMN`, Backfills auf bestehende Zeilen) vorher explizit gegenlesen lassen statt direkt zu pushen — additive Änderungen (neue Spalte/Funktion, Constraint-Fixes) können direkt gepusht werden. Reine Daten-Inserts außerhalb von `supabase/migrations/` (z. B. `supabase/add_cards_<datum>.sql`, siehe `add_new_card.md`) laufen genauso direkt selbst — per `supabase db query --linked -f <datei>` — kein manuelles Ausführen im SQL-Editor durch den Nutzer nötig.

### Datenbank-Größe / pg_cron-Housekeeping

Free-Tier-Limit: 0,5 GB Datenbankgröße. Stand 2026-09-01 (~121 Tage seit Start): ~49 MB Gesamtgröße, davon **`cron.job_run_details` allein ~32 MB (~65 %)** — das reine Ausführungs-Log von `pg_cron` (ein Eintrag pro Lauf von `reset-stale-work-sessions`/`daily-winners`, beide alle 5 Minuten), das die Extension nie automatisch aufräumt und das in keinerlei Verbindung zu App-Tabellen steht (keine FKs zu `pomodoro_sessions`/`study_days` o.ä.). Die eigentlichen App-Daten wuchsen zu diesem Zeitpunkt nur mit ~0,14 MB/Tag — bei linearer Fortschreibung würde allein `cron.job_run_details` das Limit-Wachstum dominieren, nicht die App-Nutzung.

**`prune-cron-job-run-details`** (Migration `20260901010000_prune_cron_job_run_details.sql`, `pg_cron`, täglich `30 3 * * *`): löscht `cron.job_run_details`-Zeilen älter als 7 Tage (reicht zum Nachvollziehen eines aktuellen Cron-Problems). Analoges, bereits länger bestehendes Muster: **`cleanup-study-log`** (nicht per Migrationsdatei im Repo dokumentiert, direkt in Supabase eingerichtet, stündlich `0 * * * *`) löscht `study_days_log`-Zeilen älter als 48h (das Audit-Log des `study_days_audit`-Triggers, siehe „Admin" → Lernzeit-Korrektur).

### Tabellen

| Tabelle | Inhalt |
|---|---|
| `profiles` | username, public, avatar_url, diamonds, eggs, clan_id, clan_role, focus_min, short_min, daily_focus_goal_min, display_unit, off_weekdays, sound, second_incubator_purchased, bento_layout, is_admin, library_checkin, library_checkin_date |
| `study_days` | user_id, date, minutes, off |
| `pomodoro_sessions` | user_id, date, label, duration_minutes |
| `timer_state` | user_id, end_at, total_sec, mode, paused_remaining, pomoday, limitless, started_at, credited_min, stash_total_sec, stash_paused_remaining, stash_limitless, stash_pomoday, stash_credited_min, unbroken_since |
| `incubator` | user_id + slot_index (PK, slot_index ∈ {1,2}), egg_color char(1), placed_at, focus_minutes_at_placement |
| `cards` | id int (PK), name, rarity |
| `user_cards` | id uuid (PK), user_id, card_id, obtained_at |
| `clans` | id, name, leader_id, min_focus_min, max_focus_min, level_config (JSONB), created_at |
| `clan_requests` | id, clan_id, user_id, status (`pending`/`accepted`/`rejected`), created_at |
| `weekly_challenges` | challenge_key (PK), tier, metric_type, param_n, param_h, reward_diamonds, pool_index, label, active |
| `weekly_challenge_claims` | id uuid (PK), user_id, week_start, challenge_key, reward_diamonds (Snapshot), claimed_at |
| `card_listings` | id uuid (PK), seller_id, user_card_id (verweist auf konkrete `user_cards`-Zeile), card_id, status (`active`/`traded`/`cancelled`), created_at, traded_at — kein Preis mehr, reines Tausch-Angebot |
| `card_trades` | id uuid (PK), listing_id, seller_id, buyer_id, card_id, user_card_id, trade_offer_id, traded_at — unveränderliches Audit-Log (kein UPDATE/DELETE auf die Zeile selbst), eine Zeile PRO bewegter Karte (seller/buyer = Abgeber/Empfänger dieser einen Karte). `user_card_id`/`listing_id`/`trade_offer_id` sind FKs mit `ON DELETE SET NULL` (seit `20260729000000`/`20260729000010`) — die referenzierte `user_cards`/`card_listings`/`trade_offers`-Zeile darf später gelöscht werden (z. B. `sell_card()`), ohne den Audit-Log-Eintrag zu blockieren oder zu löschen, siehe „Bekannte Designentscheidungen" |
| `trade_offers` | id uuid (PK), listing_id, offerer_id, status (`pending`/`accepted`/`rejected`), created_at, responded_at — ein Gegenangebot auf ein `card_listings`-Angebot |
| `trade_offer_cards` | trade_offer_id + user_card_id (PK), card_id — welche eigenen Karten Teil eines Gegenangebots sind |
| `pending_focus_sessions` | id uuid (PK), user_id, date, minutes, label, reason (`idle_3h`/`day_boundary`/`admin_stop`), created_at — zwischengespeicherte Limitless-Fokuszeit, wartet auf manuelle Bestätigung („Gutschreiben"), siehe „Vergessene Limitless-Timer" und „Admin" |
| `streak_milestones` | days (PK), reward_diamonds — öffentlicher, tunable Katalog (UPDATE ohne Migration), siehe „Zusätzliche Diamanten-Quellen" |
| `streak_milestone_claims` | user_id + days (PK), reward_diamonds (Snapshot), claimed_at |
| `perfect_week_claims` | user_id + week_start (PK), reward_diamonds, claimed_at |
| `perfect_week_config` | id (PK, Singleton = 1), reward_diamonds — öffentlicher, tunable Reward-Wert (UPDATE ohne Migration), siehe „Zusätzliche Diamanten-Quellen" |
| `set_bonus_claims` | user_id + rarity (PK), reward_diamonds, claimed_at |
| `tired_events` | id uuid (PK), user_id, date, created_at — append-only Log jedes „Tired"-Klicks (kein UPDATE/DELETE), siehe „Aufmerksamkeits-Tracking" |

`profiles.eggs` ist ein TEXT-String der Form `y-b-0-0-0-0-0-0-0-0` (10 Tokens, `-`-getrennt). Farb-IDs: `y/b/g/r`, `0` = leerer Slot.

`profiles.clan_role` ist `'leader'` | `'member'` | null.

`profiles.is_admin` (boolean, Default `false`) ist ein App-Owner-Flag, unabhängig von `clan_role` — siehe „Admin".

`incubator` hat max. 2 Zeilen pro Nutzer (`slot_index` 1/2, PK ist das Paar) — Slot 2 nur nutzbar nach Kauf (`profiles.second_incubator_purchased`, ab Level 15, siehe „Zweiter Brutkasten"). Brut-Fortschritt je Slot = `sum(study_days.minutes) − focus_minutes_at_placement`, Ziel = 600.

`clans.level_config` ist ein JSONB-Array mit 25 Einträgen `{ name, icon, minMinutes }`.

### RPCs

| Funktion | Zweck |
|---|---|
| `add_study_minutes(p_date, p_minutes)` | Addiert Delta auf study_days (nicht idempotent!) |
| `get_label_stats(p_user_id)` | Gibt je Label: today_minutes, week_minutes, month_minutes, alltime_minutes |
| `leaderboard_today()` | Rangliste für heute, inkl. `race_car_id` (Rennstrecken-Feature, siehe „Rennstrecke") |
| `leaderboard_aggregated(date_from)` | Rangliste ab Datum |
| `get_yesterday_winner()` | `TABLE(username text, minutes integer)` des gestrigen Tagesersten (clan-scoped über `my_clan_id()`) — seit `20260721000020_yesterday_winner_minutes.sql` inkl. Minuten, davor nur reiner Username-String |
| `draw_card(p_mystic boolean DEFAULT false)` | Würfelt Rarität (Default: 40/30/18/9/3 %; `p_mystic=true`: nur legendary/mystic, 30/70 %), wählt Karte, schreibt in `user_cards`, gibt `card_id int` zurück, siehe „Mystisches Ei" |
| `sell_card(p_card_id)` | Löscht älteste Kopie aus `user_cards`, schreibt Diamanten gut, gibt neuen Diamanten-Stand zurück. Wirft Fehler wenn < 2 Kopien vorhanden |
| `respond_to_clan_request(p_request_id, p_accept)` | Leader bestätigt/lehnt Beitrittsanfrage ab; updated `profiles` bei Accept |
| `remove_clan_member(p_user_id)` | Leader entfernt Mitglied (SECURITY DEFINER) |
| `submit_join_request()` | Neue Nutzer: findet Clan automatisch, legt pending Request an |
| `submit_join_request_to(p_clan_id)` | Anfrage an spezifischen Clan senden |
| `create_clan(p_name)` | Neuen Clan erstellen, Ersteller wird Leader (SECURITY DEFINER) |
| `get_clan_members()` | Gibt Mitglieder des eigenen Clans zurück (SECURITY DEFINER) |
| `my_clan_id()` | Hilfsfunktion für RLS-Policy (SECURITY DEFINER, kein direkter Aufruf) |
| `calc_week_streak(p_week_start, p_user_id)` | Streak innerhalb einer Kalenderwoche, wie `computeCurrentStreak()` (SECURITY DEFINER). Freie Tage zählen wie normale Tage — kein Off-Day-Skip, siehe „Freie Tage" unter Bekannte Designentscheidungen |
| `claim_weekly_challenge(p_challenge_key)` | Prüft Rotation/Schwellenwert serverseitig neu, schreibt Claim + Diamanten gut, gibt neuen Diamanten-Stand zurück |
| `create_listing(p_card_id)` | Wählt serverseitig die älteste noch nicht aktiv gelistete Kopie der Karte, legt `card_listings`-Zeile an, gibt `listing id uuid` zurück |
| `cancel_listing(p_listing_id)` | Claim-Mutex-Update `active→cancelled`, nur eigene Angebote; lehnt danach alle offenen Gegenangebote auf dieses Listing ab |
| `create_trade_offer(p_listing_id, p_offered_card_ids int[])` | Legt ein Gegenangebot an (ein oder mehrere eigene Karten, per `card_id` wie bei `create_listing`, Server wählt konkrete Kopien). Limit: max. 1 offenes (pending) Gegenangebot pro Nutzer und Listing gleichzeitig, unbegrenzt viele auf unterschiedliche Listings. Siehe „Tauschbörse" |
| `cancel_trade_offer(p_offer_id)` | Claim-Mutex-Update `pending→cancelled` auf ein eigenes Gegenangebot, Pendant zu `cancel_listing()`. Gibt das Listing für ein neues eigenes Gegenangebot frei. Siehe „Tauschbörse" |
| `respond_to_trade_offer(p_offer_id, p_accept)` | Nur der Angebotsersteller. Bei Annahme: atomarer Kartentausch (beide Richtungen) + Audit-Log + Cleanup-Kaskade (alle anderen Angebote/Gegenangebote mit denselben Karten werden verworfen). Siehe „Tauschbörse" |
| `get_incoming_trade_offers()` | Eigene offene eingehende Gegenangebote für die Kopf-Glocke (SECURITY DEFINER) |
| `calc_current_streak(p_user_id)` | Unbegrenzte (nicht wochenbegrenzte) Variante von `calc_week_streak()`, identische Semantik zu `computeCurrentStreak()`. Nur für `claim_streak_milestone()`, siehe „Zusätzliche Diamanten-Quellen" |
| `claim_streak_milestone(p_days)` | Prüft Streak-Länge serverseitig neu (`calc_current_streak`), schreibt Claim + Diamanten gut, gibt neuen Diamanten-Stand zurück |
| `claim_perfect_week()` | Prüft serverseitig, ob alle 7 Tage der aktuellen App-Woche `minutes >= 60` haben (Woche muss vorbei sein), schreibt Claim + Diamanten gut |
| `claim_set_bonus(p_rarity)` | Prüft serverseitig, ob alle Katalog-Karten einer Rarität besessen werden (`cards` vs. `user_cards`), schreibt Claim + Diamanten gut |
| `claim_race_checkpoint(p_checkpoint)` | Automatischer (kein Button) Diamanten-Claim fürs Flaggen-Feld/Ziellinie der Rennstrecke, `p_checkpoint ∈ {'flag','finish'}`, gibt `NULL` zurück wenn schon vergeben, sonst neuen Diamanten-Stand, siehe „Rennstrecke" |
| `credit_elapsed_timer_state(p_row, p_cutoff, p_reason)` | Interner Helper (kein Client-Aufruf): berechnet aus einer bereits per Claim-Mutex gelöschten `timer_state`-Zeile die fälligen Minuten und kreditiert sie (limitless → `pending_focus_sessions`, sonst direkt `study_days`/`pomodoro_sessions`); gemeinsam genutzt von `reset_stale_work_sessions()` und `admin_force_stop_timer()`, siehe „Admin" |
| `admin_list_running_timers()` | Nur für `profiles.is_admin=true`, liest sonst still leer: alle offenen `timer_state`-Zeilen (`mode ∈ {'work','short'}`) inkl. `username`, siehe „Admin" |
| `admin_force_stop_timer(p_user_id)` | Nur für Admins (sonst `RAISE EXCEPTION`): Claim-Mutex-`DELETE` auf die Ziel-Zeile, kreditiert bei `mode='work'` über `credit_elapsed_timer_state()` mit `reason='admin_stop'`, gibt `true`/`false` zurück, siehe „Admin" |
| `admin_lookup_user_day(p_username, p_date)` | Nur für Admins (sonst leer): `user_id` + aktuelle `study_days.minutes` eines Nutzers/Tages, für die Vorschau vor `admin_set_study_minutes()`, siehe „Admin" |
| `admin_set_study_minutes(p_user_id, p_date, p_minutes)` | Nur für Admins (sonst `RAISE EXCEPTION`): setzt `study_days.minutes` direkt auf `p_minutes` (SET, nicht ADD), `p_minutes ∈ [0,1440]`, siehe „Admin" |
| `get_library_checkins()` | Gibt alle heute an einer der drei Bibliotheken eingecheckten, öffentlichen Clan-Mitglieder zurück (`name`, `avatar_url`, `library`), gleiches Scoping wie `leaderboard_today()`, siehe „Bibliotheks-Check-in (Wild Cards)" |

---

## Wichtige globale Variablen

```js
days          // { 'YYYY-MM-DD': minutes } — lokale Kopie aus study_days
offDays       // { 'YYYY-MM-DD': true|false } — manuelle Heatmap-Overrides
offWeekdays   // [0..6] — global freie Wochentage (JS: 0=So)
displayUnit   // 'pomodoros' | 'time'
currentUser   // Supabase User-Objekt
userName      // Pseudonym
mode          // 'work' | 'short' | 'long'
running       // boolean
currentLabel  // aktuelles Session-Label
currentStatsPeriod  // 'today' | 'month' | 'alltime' — Label-Stats-Tab
userDiamonds  // number — aktueller Diamanten-Stand (aus profiles.diamonds)
userRaceCarId // number | null — profiles.race_car_id (1-8), dauerhaft, siehe „Rennstrecke"
userLibraryCheckin   // 'steintor' | 'neuwerk' | 'juri' | null — eigener Bibliotheks-Check-in von HEUTE, siehe „Bibliotheks-Check-in (Wild Cards)"
libraryCheckins      // Array — alle heutigen Check-ins im Clan (inkl. eigenem), aus get_library_checkins()
eggInventory  // Array[10] — null | { id, color } — lokale Kopie aus profiles.eggs
incubatorData // null | { color, focus_minutes_at_placement, bonusMin } — Slot 1, aus incubator-Tabelle
incubatorData2       // null | { color, focus_minutes_at_placement, bonusMin } — Slot 2 (nur ab Level 15 + Kauf nutzbar)
secondIncubatorUnlocked // boolean — aus profiles.second_incubator_purchased, permanent nach Kauf
eggHatchingSlot      // 1 | 2 — welcher Slot gerade im Hatch-Overlay gezeigt wird (für btnDeck-Handler)
eggDeck       // Array von { id, name, rarity, src, count } — aus user_cards
clanRole      // 'leader' | 'member' | null — aus profiles.clan_role
clanId        // uuid | null — aus profiles.clan_id
clanMaxFocus  // number — aus clans.max_focus_min (begrenzt +5min-Button)
limitlessSetting     // boolean — persistierte Checkbox-Präferenz „Unbegrenzt (Stoppuhr)"
limitless            // boolean — true, wenn die AKTUELLE Work-Session eine Stoppuhr ist
limitlessCreditedMin // number — bereits per Zwischenkredit gutgeschriebene Minuten der laufenden Limitless-Session
dailyFocusGoalMin    // number — Tagesziel in Minuten für den Limitless-Balken, aus profiles.daily_focus_goal_min (Default 240)
lastTimerInteractionAt // ms-Timestamp — für Idle-Suspend des 4-Uhr-Reset-Watchdogs (siehe „4-Uhr-Reset")
unbrokenSince        // ms-Timestamp | null — letzter manueller Play-Klick/Mode-Wechsel einer Limitless-Session, siehe „Vergessene Limitless-Timer"
idleConfirmShown     // boolean — verhindert ein zweites Unbroken-Bestätigungsbanner, während eines bereits offen ist
pendingFocusSessions // Array — eigene, noch nicht bestätigte/gelöschte Zeilen aus pending_focus_sessions
pendingFocusListOpen // boolean — Auf-/Zugeklappt-Zustand der Pending-Liste in der Timer-Card
challengesActiveTier // 'leicht' | 'mittel' | 'schwer' | 'meilensteine' — aktiver Tab in der Wochen-Challenges-Karte
claimedChallengeKeys // Set<string> — bereits eingelöste challenge_keys der aktuellen Woche
claimedMilestoneDays // Set<number> — bereits eingelöste Streak-Meilensteine (days), siehe „Zusätzliche Diamanten-Quellen"
perfectWeekClaimedThisWeek // boolean — „Perfekte Woche"-Bonus für die aktuelle App-Woche bereits eingelöst
claimedSetBonusRarities    // Set<string> — bereits eingelöste Set-Boni (rarity), siehe „Zusätzliche Diamanten-Quellen"
newDesignOn   // boolean — Settings-Opt-in „Neues Design" (Bento-Grid ab Desktop-Breite), Default aus, geräte-lokal
focusModeOn   // boolean — Fokus-Modus (blendet alle Karten außer Timer aus), manuell + automatisch bei mode==='work'
marketListings // Array — aktive Angebote aller Spieler, aus card_listings (Tab „Alle Angebote")
myListings     // Array — eigene aktive Angebote (Tab „Meine Angebote")
marketTab      // 'all' | 'mine' — aktiver Tab in der Tauschbörse
marketLoaded   // boolean — verhindert Doppel-Fetch beim ersten Aufklappen der Deck-Box
bellClanCount / bellTradeCount // number — gemergte Zähler für den Glocken-Badge (Clan-Anfragen + eingehende Gegenangebote)
tradeOfferListingId / tradeOfferSelected // uuid | null, Set<int> — Ziel-Listing bzw. gewählte eigene card_ids im Gegenangebot-Picker (#tradeOfferOverlay)
```

---

## Timer-Logik

- `tick()` läuft per `setInterval` (250ms), berechnet verbleibende Zeit aus `startedAt`
- `onTimerEnd()` — **async**, claimed die `timer_state`-Zeile via DELETE+`return=representation`
- Nur das Gerät, das die Zeile wirklich löscht (`deleted.length > 0`), ruft `completePomo()` auf → verhindert Doppel-Credits bei mehreren gleichzeitig offenen Tabs
- SW (`sw.js`) hält den Timer via `setTimeout` am Laufen wenn der Tab eingefroren ist, schickt `TIMER_DONE`-Message
- `elapsedSec()` / `hasProgress()` sind die zentralen Helper für „wie viel Zeit ist vergangen" bzw. „gibt es Fortschritt, der bei Reset/Moduswechsel verloren geht" — beide zweigen auf `limitless` ab (siehe unten), alle Stellen, die früher direkt `totalSec - remaining` bzw. `remaining < totalSec` verglichen haben, nutzen jetzt diese Funktionen


→ Details (Limitless-Modus, Automatische Pausen, 4-Uhr-Reset, 3h-Idle-Watchdog, Timer State Persistence, Bestätigungs-Dialoge): [[docs/timer-details.md]]

## Datenpfad bei Pomodoro-Abschluss

1. `completePomo()` schreibt `days[key] += mins` lokal
2. `addStudyMinutes(date, delta)` — RPC, addiert auf Supabase
3. `savePomoSession(date, mins, label)` — Insert in `pomodoro_sessions`
4. Caches für Label-Stats + Leaderboard werden **nicht** automatisch invalidiert — nur bei Force-Refresh oder TTL-Ablauf
5. Level-Up-Check: `getCurrentLevel()` vor/nach dem Eintrag vergleichen → `awardEgg()` bei Aufstieg
6. `renderIncubator()` — Brut-Fortschritt wird nach jedem Pomo neu berechnet (kein Timer)

---

## [[localStorage]] Keys

| Key | Inhalt | TTL |
|---|---|---|
| `pomo_heatmap_v3` | days, offDays, offWeekdays, totalPomodoros | — |
| `pomo_settings_v1` | work/short/long/longafter Minuten | — |
| `pomo_session` | Supabase Session (access+refresh token) | — |
| `pomo_labels_v1` | Letzte 40 verwendete Labels (Array) | — |
| `pomo_current_label_v1` | Zuletzt verwendetes Session-Label (Plain-String), geräte-lokal — übersteht Reload, `currentLabel`-Initialwert | — |
| `pomo_display_unit` | 'pomodoros' \| 'time' | — |
| `pomo_sound` | ausgewählter Sound-Key | — |
| `pomo_lb_cache_<period>` | Leaderboard-Liste ohne Winner | 2–10 min |
| `pomo_lb_winner` | Gestriger Tagessieger `{ name, minutes }` | 1h |
| `pomo_lb_ranks_<period>` | Rang-Snapshot nach letztem Server-Fetch (`{ name: rank }`) | — |
| `pomo_label_stats_<userId>` | Label-Stats-Array | 5 min |
| `pomo_egg_preview` | `'1'` wenn Clan-Leader den Placeholder deaktiviert hat | — |
| `pomo_limitless_v1` | `'1'`/`'0'` — Präferenz „Unbegrenzt (Stoppuhr)"-Modus, geräte-lokal | — |
| `pomo_new_design_v1` | `'1'`/`'0'` — Opt-in „Neues Design" (Bento-Grid ab Desktop-Breite), Default aus, geräte-lokal | — |
| `pomo_focus_mode_v1` | `'1'`/`'0'` — Fokus-Modus-Zustand, geräte-lokal | — |

---

## UI-Karten (von oben nach unten)

1. **Timer-Card** — Analog-Uhr SVG (im Limitless-Fokusmodus stattdessen der Zeitstrahl-Fortschrittsbalken, siehe „Limitless (Stoppuhr-)Fokus-Modus"), Modi (Fokus/Pause), Label-Input mit Dropdown, +5min, „✓ Jetzt"-Button (frühzeitiger Abschluss), Confetti bei Abschluss; darunter eine ausklappbare Liste zwischengespeicherter Fokus-Sessions (`#pending-focus-section`, nur sichtbar wenn nicht leer), siehe „Vergessene Limitless-Timer"
2. **Heatmap-Card** — 100-Tage-Grid, scrollbar, Klick = Off-Day togglen, DOW-Labels links
3. **Aufmerksamkeits-Card** (`#attention-card`) — nur sichtbar für eingeloggte Nutzer (kein Clan-/Public-Gating, analog Wochen-Challenges-Card); „Tired"-Button, darunter Tagesverlaufs-Balkendiagramm (feste 24h-Y-Skala 04:00–03:59, eine Spalte pro Tag, komplette Historie seit App-Start), siehe „Aufmerksamkeits-Tracking"
4. **Stats-Card** — Level (25 Stufen), Streak, Bester Tag, Wochenschnitt; „mehr Infos" öffnet Label-Stats-Overlay (inset, gleiche Card)
5. **Wochen-Challenges-Card** (`#challenges-card`) — nur sichtbar für eingeloggte Nutzer (kein Clan-/Public-Gating); Tabs Leicht/Mittel/Schwer, je 3 Progress-Bar-Zeilen mit Belohnungs-Label / „Einlösen"-Button / „✓ eingelöst"
6. **Ei-Box** (`#eggBox`) — Diamanten-Anzeige, Brutkasten (1 Slot), -1h/Skip-Buttons, aufklappbares 10-Slot-Inventar; hinter Placeholder versteckt (`#egg-placeholder-overlay`)
7. **Deck-Box** (`#deckBox`) — aufklappbares Karten-Grid, nach Rarität sortiert, Stapel-Optik bei Duplikaten; hinter demselben Placeholder. Kopfzeile zeigt `#deckCount` als `(besessen/gesamt)` — `eggDeck.length` (Anzahl unterschiedlicher besessener Karten, Duplikate zählen nicht mit) `/` `CARD_CATALOG.length` (aktuell 33, wächst automatisch mit neuen Katalog-Karten), gesetzt in `renderEggDeck()`
8. **Leaderboard-Card** — nur sichtbar wenn `userPublic === true && clanRole != null`; Tabs: Heute/Letzte Woche/Letzter Monat/All Time; Tagessieger-Highlight = goldener Border + Label „Tagessieger · &lt;Vortags-Minuten&gt;" (über `minutesToDisplay()`, respektiert Anzeigeeinheit; Minutenzahl ist unabhängig vom aktiven Tab immer die des Vortags, aus `yesterdayWinnerMinutes`/`get_yesterday_winner()`); Live-Timer-Dot (grün, `entry.timer_active` aus `leaderboard_today()`/`leaderboard_aggregated()`); Rang-Änderungs-Indikator (▲ grün / ▼ rot / ● hellblau für Neue) vor dem 🃏-Button, nur nach echtem Server-Fetch sichtbar; im Heute-Tab zusätzlich Mini-Auto-Icon neben jedem Namen, siehe „Rennstrecke"
9. **Rennstrecke-Card** (`#race-track-card`) — eigene Kachel direkt unterhalb der Leaderboard-Card, gleiche Sichtbarkeits-Bedingung (`setLeaderboardVisibility()`), zeigt immer live die heutigen Rennpositionen unabhängig vom aktiven Leaderboard-Tab, siehe „Rennstrecke"


### Eier & Kartensammlung — Schlüsseldetails

→ Details: [[docs/eggs.md]]

### Wochen-Challenges

→ Details: [[docs/challenges-rewards.md]]

### Zusätzliche Diamanten-Quellen (Streak-Meilensteine, Perfekte Woche, Set-Bonus)

→ Details: [[docs/challenges-rewards.md]]

### Bento-Grid-Layout (Desktop, Einstellungen-Opt-in)

→ Details (Datenmodell, In-Page-Editor, Kachel entfernen/wiederherstellen): [[docs/bento-layout.md]]

### Fokus-Modus (Header-Button, unabhängig vom Bento-Grid-Toggle)

→ Details (inkl. Fullscreen-Timer + Ring-Visualisierung): [[docs/focus-mode.md]]

## Clan-System

### Datenbank
- **`clans`**: id, name, leader_id, min_focus_min, max_focus_min, level_config (JSONB-Array mit 25 Stufen), created_at
- **`clan_requests`**: id, clan_id, user_id, status (`pending`/`accepted`/`rejected`), created_at
- **`profiles`** erweitert um `clan_id` und `clan_role` (`'leader'`|`'member'`|null)
- RLS: `profiles_read_own` (eigenes Profil) + `profiles_read_clan_peers` (via `my_clan_id()` SECURITY DEFINER)
- **Wichtig**: Subqueries in RLS-Policies auf `profiles` müssen SECURITY DEFINER-Funktionen nutzen — sonst rekursiver Loop → Profil nicht lesbar → Auto-Reset

### UI
- **Header**: Glocken-Icon (`#bell-wrap`, für **jeden eingeloggten Nutzer** sichtbar) mit Badge + Dropdown; Beitrittsanfragen-Sektion darin bleibt aber nur für Clan-Leader sichtbar. Zweite Sektion zeigt eingehende Tausch-Gegenangebote für alle Nutzer, siehe „Tauschbörse"
- **Header**: „Clan"-Button (Nutzer ohne Clan) mit zwei Tabs: „Clan suchen" und „Neuen Clan erstellen"
- **Clan suchen**: listet alle aktiven Clans, Anfrage geht an spezifischen Clan
- **Neuen Clan erstellen**: Namenseingabe, Ersteller wird automatisch Leader
- **Leader-Einstellungen**: Clan-Name, Min./Max. Fokuszeit, Level-Namen-Editor, Mitgliederliste mit Entfernen-Button
- **Timer**: `+5 min` wird auf `clanMaxFocus` geclampt
- **Neue Nutzer**: `submitJoinRequest()` wird automatisch nach Registrierung aufgerufen; Registrierungsflow bietet Clan gründen / beitreten / überspringen

### Registrierter Clan
- Clan „Schwitzende Verbindung Halle" — alle `public = true`-Profile als Member

---


## Admin

→ Details (inkl. Lernzeit-Korrektur): [[docs/admin.md]]

## Level-System

25 Stufen, konfiguriert in `clans.level_config`. Schwellen in Fokusminuten:

| Level | Name (Default)       | Icon | Ab (Min) |
| ----- | -------------------- | ---- | -------- |
| 1     | Erkaltete Tastatur   | 🧊   | 0        |
| 2     | Morgenmuffel         | 🧊   | 300      |
| 3     | Notizzettelsammler   | 🧊   | 600      |
| 4     | Koffeinabhängiger    | 🧊   | 900      |
| 5     | Halbherziger Held    | 🧊   | 1.500    |
| 6     | Sofagelehrter        | 🛋️  | 2.100    |
| 7     | Bücherstapelturmer   | 🛋️  | 3.000    |
| 8     | Pausensnacker        | 🛋️  | 3.900    |
| 9     | Gemütlicher Grübler  | 🛋️  | 4.800    |
| 10    | Pflichterfüller      | 🛋️  | 6.000    |
| 11    | Entflammter          | 🔥   | 7.800    |
| 12    | Nachtschwarmer       | 🔥   | 9.600    |
| 13    | Karteikartenkönig    | 🔥   | 12.000   |
| 14    | Zeitfresser          | 🔥   | 14.400   |
| 15    | Leuchtendes Beispiel | 🔥   | 17.400   |
| 16    | Schreibtischkämpfer  | 🦁   | 21.000   |
| 17    | Geduldiger Riese     | 🦁   | 25.200   |
| 18    | Stirnrunzler         | 🦁   | 30.000   |
| 19    | Schlafloser Denker   | 🦁   | 35.400   |
| 20    | Unaufhaltsamer       | 🦁   | 41.400   |
| 21    | Zeitsouverän         | 👑   | 45.000   |
| 22    | Chronos-Bezwinger    | 👑   | 49.200   |
| 23    | Erleuchteter         | 👑   | 54.000   |
| 24    | Pomodoro-Legende     | 👑   | 58.800   |
| 25    | Pomodoro-Gott        | 👑   | 63.000   |

Level-Up → `awardEgg()` (zufällige Farbe in ersten freien Slot; bei vollem Inventar wird ältestes Ei ersetzt).

### Level-15-Feier-Overlay

Beim erstmaligen Überschreiten der Level-15-Schwelle (`activeLevels[14]`, gleiche Schwelle wie „Zweiter Brutkasten") zeigt `celebrateLevel15()` (`#level15Overlay`) ein persönliches Feier-Bild als Full-Screen-Overlay: dreht sich ein (720°, Bounce-Scale), kommt zur Ruhe, danach Konfetti-Burst, bleibt stehen bis „Weiter" geklickt wird. Bild liegt relativ im Repo (`level15.jpg`, **nicht** über die `CDN`-jsDelivr-Konstante wie Eier/Karten — ein frisch gepushtes File auf `@main` kann dort bis zu 24h gecacht ausbleiben). Titel ist ein fest hinterlegter Text (kein `activeLevels[14].label`) — ein persönlicher Insider-Gag zu diesem einen Meilenstein, kein allgemeiner Level-Name.

- **Erkennung**: `crossedLevel15(lvlBefore, lvlAfter)` ist ein reiner Edge-Trigger, unabhängig vom generischen `awardEgg()`-Level-Up-Check daneben, aufgerufen an denselben 4 Level-Up-Stellen (`completePomo()`, `checkLimitlessCheckpoint()`, beide Zweige von `checkDayRollover()`). Da Fokusminuten nie sinken, feuert das garantiert nur einmal im Leben eines Accounts; bereits über Level 15 stehende Bestandsnutzer lösen es nie aus.
- **Animation**: Rotation (`.lvl15-frame-wrap`) und Scale-in-Bounce (`.lvl15-frame`) laufen bewusst als zwei getrennte CSS-Animationen auf zwei verschiedenen Elementen statt einem gemeinsamen Keyframe-Set für `rotate()+scale()` — Letzteres erzeugte einen sichtbaren Ruckler gegen Ende (die Easing-Kurve der Rotation kollidierte mit dem Scale-Bounce-Overshoot). Der Glow-Kreis dahinter ist radialsymmetrisch, seine Mitrotation fällt nicht auf.
- **Dismiss**: `cloneNode`/`replaceWith`-Muster (wie `showTimerConfirmBanner()`) verhindert Listener-Stacking.

---

## Karten-Katalog (42 Karten)

`CARD_CATALOG` hardcoded im JS. Bildpfad: `CDN/Karten/<rarity>/<name>.png`.

| ID | Name | Rarität |
|---|---|---|
| 1 | FSr-Mitglied | common |
| 2 | Glutenboykottierer | common |
| 3 | Histotutor | common |
| 4 | M1Schwitzer | common |
| 5 | Skillslabschauspieler | common |
| 6 | Soziologiestudent-in | common |
| 7 | Warmduscher | common |
| 8 | Anki-Controler-User | rare |
| 9 | Biochemietrader | rare |
| 10 | Mensafrau | rare |
| 11 | Schwesterrabiata | rare |
| 12 | gym10duscher | rare |
| 13 | Medienny | legendary |
| 14 | STHebungsüberseher | legendary |
| 15 | TomS | legendary |
| 16 | Bibliothek-Schläfer | epic |
| 17 | FreundausHarvard | epic |
| 19 | Mediraggy | epic |
| 20 | Neurotutor | epic |
| 21 | Penig-BG | mystic |
| 22 | Ersti | common |
| 23 | Bubbletrinker | rare |
| 24 | Juri-Gänger | rare |
| 25 | Party-Löwe | rare |
| 26 | Performative Male | rare |
| 27 | Sozialist | rare |
| 28 | Team-Leader | rare |
| 29 | urosono | epic |
| 30 | Adminpomodoro | mystic |
| 31 | Sono-Patient | rare |
| 32 | StravaGold | rare |
| 33 | Gilbert-Syndrom | rare |
| 34 | UKH-Transport | rare |
| 35 | Froschi | rare |
| 36 | OA-Hagel | rare |
| 37 | Rebecca-Kabel | epic |
| 38 | Flappe-Peng | common |
| 39 | Scheinfreier | epic |
| 40 | Richard-von-Volkmann | rare |
| 41 | James-Tanner | common |
| 42 | Hans-Curschmann | common |
| 43 | Steintor-Opa | epic |

Raritäten & Ziehwahrscheinlichkeiten: common 40 %, rare 30 %, epic 18 %, legendary 9 %, mystic 3 %.

---

## Eier-System

→ Details (Farben & Bilder, Brut-Stadien, Schlüpf-Animation, Diamanten-Kosten, Mystisches Ei, Ei-Shop, Zweiter Brutkasten, Supabase-Schreibpfade): [[docs/eggs.md]]

## Tauschbörse (Karten-Marktplatz)

→ Details (Angebot erstellen/zurückziehen, Gegenangebot, Sichtbarkeitsregeln, Glocke): [[docs/trading.md]]

## Rennstrecke (eigene Bento-Kachel `#race-track-card`)

→ Details (Diamanten-Checkpoints, Bibliotheks-Check-in): [[docs/racetrack.md]]

## Aufmerksamkeits-Tracking (eigene Bento-Kachel `#attention-card`)

→ Details (inkl. Risiko-Analyse KDE + DBSCAN): [[docs/attention-tracking.md]]

## Label-Stats Overlay

- Tabs: **Heute** (`today_minutes`) / **Monat** (`month_minutes`) / **Gesamt** (`alltime_minutes`)
- 2-Spalten-Tabelle + SVG-Pie-Chart
- Inline-Rename: PATCH auf `pomodoro_sessions` — wenn Ziel-Label bereits existiert → Merge-Dialog
- PIE_COLORS: 20 Grün-Töne (Array, Index = Rang)

---

## CSV-Export (Settings → „Datenexport")

- Nutzer wählt Zeitraum (`#export-from`/`#export-to`, Default = letzte 30 Tage bis heute via `todayKey()`), Klick auf `#export-csv-btn` → `exportSessionsCSV(from, to)`
- `fetchAllSessions()` lädt `pomodoro_sessions` (`select=date,label,duration_minutes`, Filter `date=gte/lte`) paginiert in 1000er-Schritten (`limit`/`offset`)
- `downloadCSV()` baut CSV (`Datum,Label,Minuten`, Felder mit `csvField()` escaped) und triggert Download via `Blob` + temporärem `<a download>`
- **Kein Rate-Limit** — der ursprüngliche 12h-Cooldown (`pomo_export_last_<userId>`) wurde entfernt, da Nutzung/Egress der Funktion vernachlässigbar sind; Export ist beliebig oft hintereinander möglich
- Fehlerfälle: kein Login → „Bitte anmelden.", ungültiger Zeitraum (`from > to`) → Validierungsfehler ohne Request

---

## Tagesgrenze

Neuer Tag beginnt um **04:00 Uhr Berliner Zeit** (`todayKey()`).

---

## Sound Engine

[[Web Audio API]], synthetisiert — kein externes Asset. Sounds: bell, ding, chime, soft, bowl, marimba, ping, harp, drum, none.

---

## Bekannte Designentscheidungen

- `add_study_minutes` ist nicht idempotent → nur über das Claim-Mutex in `clearTimerState` aufrufen
- Winner-Cache (`pomo_lb_winner`) ist bewusst vom Listen-Cache getrennt, damit ein fehlgeschlagener Winner-Fetch nicht die Liste blockiert
- `offWeekdays` speichert JS-Wochentagnummern (0=Sonntag), nicht ISO (1=Montag)
- **Freie Tage** wirken sich absichtlich **nur** auf den Wochendurchschnitt aus (`sumRange()`/`daysWithData()` in `renderStats()`, via `isOff()`) — sonst würde ein freier Tag mit 0 Minuten den Schnitt verfälschen. Überall sonst (`computeCurrentStreak()`, `computeLongestStreak()`, `computeWeekStreak()`, server-seitig `calc_week_streak()`) zählen freie Tage wie ganz normale Tage: ein freier Tag ohne Minuten bricht den Streak genauso wie ein normaler Tag. Grund: `offDays[key]` lässt sich per Heatmap-Klick rückwirkend für jeden beliebigen vergangenen Tag setzen — hätte ein freier Tag den Streak (client wie server) weiterhin gerettet, könnte man nachträglich einen vergessenen Tag freimarkieren und sich so einen Streak/eine Streak-Challenge erschleichen (`supabase/migrations/20260713000000_week_streak_ignores_off_days.sql`)
- `finishEarly()` überschreibt `totalSec` mit der verstrichenen Zeit **abgerundet auf volle Minuten** (`Math.floor(elapsedSec() / 60) * 60`), bevor `completePomo()` aufgerufen wird — so werden keine Sekunden in Supabase gespeichert. Im Limitless-Modus ist das nur der seit dem letzten Checkpoint noch offene Rest, nicht die gesamte Sessiondauer (siehe „Limitless (Stoppuhr-)Fokus-Modus")
- `showTimerConfirmBanner(msg, onYes)` ist ein wiederverwendbares Bestätigungs-Modal (`#timer-confirm-banner`); Buttons werden per `cloneNode` ausgetauscht, um Event-Listener-Leaks zu vermeiden

## Siehe auch

- [[Lernkalender/README|Lernkalender]] — liest `pomodoro_sessions` für sein Statistik-Overlay und erkennt die `pomo_session` wieder
- [[FocusFM/README|FocusFM]] — eigenständiges Projekt, nutzt ebenfalls die [[Web Audio API]] für synthetisierten Sound
- [[Dashboard/README|Dashboard]] — verlinkt auf die online gehostete Pomodoro-Seite (`ragnarg-0.github.io/Pomodoro`)

- [[docs/timer-details.md]], [[docs/bento-layout.md]], [[docs/focus-mode.md]], [[docs/challenges-rewards.md]], [[docs/admin.md]], [[docs/eggs.md]], [[docs/trading.md]], [[docs/racetrack.md]], [[docs/attention-tracking.md]] — ausgelagerte Feature-Details dieser Doku (siehe oben, aus `CLAUDE.md` gekürzt wegen 150k-Zeichen-Limit)
