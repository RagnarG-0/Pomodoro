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

Supabase CLI ist lokal installiert (Homebrew, `supabase/tap`) und mit diesem Projekt verlinkt (`supabase link`, Ref `cmbyzzfjzrhdxylopqkt`). Neue `.sql`-Dateien in `supabase/migrations/` werden direkt per `supabase db push` angewendet — kein manuelles Copy-Paste in den SQL-Editor mehr nötig (Stand 2026-07-29, davor wurden alle Migrationen manuell eingefügt). `supabase migration list` zeigt den Sync-Status (Local vs. Remote), `supabase db push --dry-run` previewt ohne Anwenden. Bei destruktiven/datenverändernden Migrationen (`DROP TABLE`/`DROP COLUMN`, Backfills auf bestehende Zeilen) vorher explizit gegenlesen lassen statt direkt zu pushen — additive Änderungen (neue Spalte/Funktion, Constraint-Fixes) können direkt gepusht werden.

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

### Limitless (Stoppuhr-)Fokus-Modus
- Über Settings-Checkbox „Unbegrenzt (Stoppuhr)" aktivierbar (`limitlessSetting`, `localStorage` Key `pomo_limitless_v1`, geräte-lokal, nicht mit `profiles` synchronisiert)
- Bei aktivem `limitless` zählt der Fokus-Timer ab `00:00:00` hoch (`remaining` = verstrichene Sekunden, `totalSec = 0`) statt von einer festen Dauer herunter; Anzeige über `fmtElapsed()` (hh:mm:ss)
- Beendet wird eine Limitless-Session ausschließlich manuell über „✓ Jetzt" (`finishEarly()`) — der reguläre Countdown-Abschluss (`onTimerEnd()`) greift hier nie
- Alle `LIMITLESS_CHECKPOINT_SEC` (20 min) wird der bisherige Fortschritt still (kein Sound/Konfetti/Toast) über `checkLimitlessCheckpoint()` kreditiert — analog `completePomo()`, nur ohne die Feier-Elemente; `limitlessCreditedMin` verhindert Doppelkredit, wird in `timer_state.credited_min` gespiegelt
- `finishEarly()` kreditiert bei Limitless-Sessions nur den seit dem letzten Checkpoint noch offenen Rest (`totalElapsedMin - limitlessCreditedMin`), nicht die gesamte Sessiondauer
- `+5 min`-Button ist im Limitless-Modus ausgeblendet (kein sinnvolles Ziel, gegen das addiert werden könnte)
- `updateWatch()` zeigt im Limitless-Modus den Fortschritt zum nächsten Checkpoint (nicht zur Gesamtdauer)
- **Eye-Break-Erinnerung**: alle `EYE_BREAK_INTERVAL_MS` (sw.js, 20 min, muss synchron zu `LIMITLESS_CHECKPOINT_SEC` bleiben) zeigt der SW eine Push-Notification („Kurz wegschauen"), unabhängig davon ob der Tab im Vordergrund ist. Client sendet `swSend({ type: 'EYE_BREAK_START', startedAt })` beim Start/Resume einer Limitless-Session (`start()`) und beim Fortsetzen nach Seiten-Reload (`restoreTimerState()`); SW berechnet die nächste 20-Min-Grenze aus `startedAt` per `setTimeout` und plant sich nach jedem Feuern selbst neu. `TIMER_PAUSE`/`TIMER_RESET`/`TIMER_SKIP` (bereits bestehende Messages) löschen den Schedule im SW mit — kein eigener Stop-Message-Typ nötig, da diese ohnehin bei jedem Pause/Reset/Abschluss gesendet werden. Rein clientseitig ausgelöste Reminder (ohne SW) würden im Hintergrund-Tab vom Browser gedrosselt/gefroren — deshalb SW-Scheduling wie bei `TIMER_DONE`, nicht `setInterval` in `index.html`
- **Rollout auf bereits laufende Sessions**: ein Deploy dieses Features erreicht Timer, die schon *vor* dem Deploy in einem offenen Tab liefen, nicht automatisch — der Tab hat den alten JS-Stand im Speicher (kennt den `EYE_BREAK_START`-Aufruf nicht) und der SW wird nicht mitten in der laufenden Session aktualisiert. Kein neuer Timer nötig, ein einfacher Seiten-Reload genügt: `restoreTimerState()` liest die laufende Limitless-Session dann mit dem neuen Code erneut ein und sendet `EYE_BREAK_START` nach
- **Timer-Card-Anzeige**: statt der analogen Uhr (`updateWatch()`) zeigt `updateLimitlessRing()` einen Doppel-Ring (`#limitless-ring-wrap`, Sibling von `.watch-wrap` in der Timer-Card, direkt über `#time-display`); `renderTimer()` togglet zwischen beiden über `showElapsed` (= `mode === 'work' && limitless`). Äußerer Ring (`#limitless-ring-outer-arc`, Radius 72, `var(--ring-outer)`, dunkleres Grün) = Tagesfortschritt zum Tagesziel (`dailyFocusGoalMin`), Fraktion `Math.min(1, liveMin/goalMin)` — bleibt bei 100 % geschlossen, kein Überlaufen wie beim früheren Balken. Innerer Ring (`#limitless-ring-inner-arc`, Radius 56, `var(--ring-inner)`, helleres Grün) = Fortschritt bis zur nächsten Pause, aus `currentProgressFrac()` (siehe unten) — füllt sich alle `LIMITLESS_CHECKPOINT_SEC` (20 min) neu, oder bis zum nächsten Auto-Break-Zeitpunkt bei aktiven Automatische Pausen, und beginnt danach jeweils wieder bei 0. Beide Arcs nutzen die klassische SVG-Ring-Technik (`stroke-dasharray` = volle Kreislänge, `stroke-dashoffset` animiert den sichtbaren Anteil), Konstanten `CIRC_RING`/`CIRC_RING_INNER`. `liveMin` = live „heute gelernte Minuten" (`(days[creditKey]||0) - limitlessCreditedMin + Math.floor(remaining/60)`, `creditKey = pomoDay || todayKey()`, Helper `dailyGoalMinLive()`), aktualisiert bei jedem Tick. Wird das Ziel erreicht/überschritten, bleibt der äußere Ring geschlossen und bekommt einen pulsierenden Glow (`.ring-over-goal`, `drop-shadow`-Keyframe) statt weiter zu wachsen. `--ring-outer`/`--ring-inner` sind bewusst fixe, nicht theme-abhängige Grüntöne (anders als `--accent-dark`, das zwischen Hell/Dunkel invertiert) — siehe `:root`. Keine Checkpoint-Tickmarken mehr (ersatzlos entfernt: das Checkpoint-Konzept wird jetzt vollständig durch das Füllen/Zurücksetzen des inneren Rings dargestellt). Die separate PR-Bruch-Push-Notification (siehe unten) ist davon unberührt und nutzt `computeBestDay()` weiterhin unabhängig
- **Tagesziel**: `dailyFocusGoalMin` (Minuten, 30–720, 5er-Schritte) bestimmt den äußeren Ring-Fortschritt (s.o.). Settings-Row `#daily-goal-row` sichtbar nur wenn Limitless aktiv (`syncAutoBreaksVisibility()`, analog `#focus-interval-row`). Persistiert in `profiles.daily_focus_goal_min` (cross-device, Default `null` → Client fällt auf 240 zurück) — anders als `limitlessSetting`/`autoBreaksSetting`/`focusIntervalMin`, die geräte-lokal in `localStorage` liegen. Wird wie `focus_min`/`short_min` erst beim Klick auf „Speichern" übernommen (kein Live-Apply beim Tippen im Eingabefeld), aktualisiert den sichtbaren Ring danach aber sofort auch während der Timer läuft
- **PR-Bruch-Notification**: wird der persönliche Rekord während einer laufenden Limitless-Session überschritten, feuert eine Push-Notification (Tag `pomodoro-pr-broken`, eigener Tag getrennt von `pomodoro-eye-break`/`pomodoro-timer`) — auch bei eingefrorenem Hintergrund-Tab, da SW-seitig vorausgeplant statt im Vordergrund-Tick geprüft. `schedulePRTargetIfPending(startedAtMs)` (index.html, nahe `swSend`) berechnet den exakten Zeitpunkt (`crossAtMs = startedAtMs + (prMin - baseline) * 60000`) und sendet `{ type: 'PR_TARGET_SCHEDULE', crossAtMs, prMinutes }`; der SW plant dafür per `setTimeout` (one-shot, kein Selbst-Reschedule wie beim Eye-Break) und cleart es bei `TIMER_PAUSE`/`TIMER_RESET`/`TIMER_SKIP` mit. Aufgerufen an denselben Stellen wie `EYE_BREAK_START` (`start()`, `restoreTimerState()`). Idempotent **ohne** localStorage-Flag: `baseline = days[creditKey] - limitlessCreditedMin` bewegt sich nie unabhängig von `limitlessCreditedMin` (beide wachsen in `checkLimitlessCheckpoint()` immer um dasselbe Delta) — ist der Rekord bereits gebrochen (frühere Session heute, oder vor einer Pause in der laufenden Session), gilt `baseline >= prMin` sofort und es wird nichts neu geplant
- **Stolperstein**: mehrere Stellen berechnen `totalSec`/`remaining` bei Idle-Zustand neu aus `getMin(mode) * 60` (Boot vor `initAuth()`, `save-settings-btn`, Logout, `loadClanSettings()`, Label speichern/auswählen) — jede davon muss zuerst auf `mode === 'work' && limitless` prüfen und in diesem Fall `0`/`0` setzen, sonst zeigt die Stoppuhr nach Neuladen/Speichern fälschlich die normale Fokusdauer (z. B. „01:00:00" bei 60-Min-Fokuseinstellung) statt „00:00:00"

### Automatische Pausen (Opt-in, nur Limitless)
- Neue Settings-Checkbox „Automatische Pausen" (`autoBreaksSetting`, `localStorage` Key `pomo_auto_breaks_v1`, geräte-lokal), nur sichtbar solange „Unbegrenzt (Stoppuhr)" aktiv ist (`syncAutoBreaksVisibility()`, beim Öffnen des Settings-Panels und beim Toggle der Limitless-Checkbox aufgerufen). **Default aus** — ohne diese Einstellung ist das Verhalten von Fokus/Pause-Moduswechseln exakt wie vor diesem Feature, keinerlei Änderung
- Bei aktiver Einstellung wechselt der Timer alle `LIMITLESS_CHECKPOINT_SEC` (20 min) automatisch in eine Pause (Dauer = normale „Pause"-Einstellung, `set-short`/`short_min`) und danach automatisch zurück in den Fokus — inkl. Push-Notification bei beiden Übergängen
- **Kernmechanik — Pause statt Stopp:** Grundvoraussetzung ist, dass ein unterbrochener Fokus-Timer nicht mehr verworfen, sondern pausiert und später an derselben Stelle fortgesetzt wird. Da `timer_state` nur eine Zeile pro Nutzer hat (`mode`-Spalte), kann sie nicht gleichzeitig „Pause läuft" und „Fokus pausiert bei X" abbilden — dafür gibt es `workStash` (client, `{totalSec, remaining, limitless, pomoDay, limitlessCreditedMin}` | `null`) plus die `stash_*`-Spalten in `timer_state` als serverseitiges Pendant (Migration `20260715000000_auto_breaks_work_stash.sql`). „Stash vorhanden" wird über `stash_paused_remaining IS NOT NULL` erkannt, analog zu `paused_remaining` beim aktiven Timer
- `interruptWorkForBreak(auto)` ist der **einzige** Ort, der `workStash` befüllt — aufgerufen aus dem Mode-Button-Handler (work→short mit `hasProgress()`) nur wenn `autoBreaksSetting` an ist, und aus `checkLimitlessCheckpoint()` bei jeder neu erreichten 20-Minuten-Schwelle (`auto=true`). Ohne `autoBreaksSetting` kann `workStash` nie entstehen — der Default-Nutzer ist davon also nie betroffen
- `switchTo()` prüft im `m === 'work'`-Zweig zuerst auf `workStash`: vorhanden → restaurieren (`totalSec`/`remaining`/`limitless`/`pomoDay`/`limitlessCreditedMin` aus dem Stash), sonst wie zuvor frischer Fokus-Start. Gibt `true` zurück, wenn ein Stash restauriert wurde — alle Aufrufer, die zu `work` wechseln (`onTimerEnd()`, der SW-`TIMER_DONE`-Handler, `skip()`, der Mode-Button-Klick), rufen danach `start()` auf, wenn `true` zurückkommt, damit der Fokus **automatisch weiterläuft** statt nur angezeigt zu werden. `swSend({type:'TIMER_RESET'})` sitzt jetzt zentral am Anfang von `switchTo()` statt bei jedem Aufrufer einzeln (im SW idempotent, harmlos redundant für Aufrufer, die es vorher schon selbst sendeten)
- Ob eine Pause automatisch startet, hängt nur davon ab, **wer** `interruptWorkForBreak()` aufruft: der manuelle Mode-Button-Klick lässt die Pause idle (Nutzer startet selbst, wie jeder andere Moduswechsel), der 20-Minuten-Trigger startet sie sofort (`if (auto) start();`). Das Fortsetzen des Fokus danach ist dagegen **immer** automatisch, unabhängig davon wie die Pause begann — sobald ein Stash existiert, läuft er beim Zurückwechseln zu `work` automatisch weiter
- Reset-Button und „✓ Jetzt" (`finishEarly()`) bleiben unverändert — beide sind bewusste, destruktive/abschließende Aktionen ohne Stash-Bezug
- **SW-Scheduling (`AUTO_BREAK_SCHEDULE`)**: mirrort Eye-Break (rekurrierend, gleiches 20-Min-Intervall, Selbst-Reschedule per `scheduleAutoBreak()`/`onAutoBreak()`), zeigt beim Feuern eine Notification und weckt offene Tabs per `postMessage({type:'AUTO_BREAK_TRIGGER'})`, die dann `checkLimitlessCheckpoint()` erneut aufrufen (idempotent — der bestehende `targetCredited <= limitlessCreditedMin`-Guard verhindert Doppelausführung, falls der Vordergrund-Tick die Schwelle längst selbst verarbeitet hat). **Ersetzt** `EYE_BREAK_START` beim Senden (in `start()` und `restoreTimerState()`, bedingt auf `autoBreaksSetting`) — eine echte 5-Minuten-Pause macht die 10-Sekunden-Wegschau-Erinnerung zum exakt gleichen Zeitpunkt überflüssig
- **Notification beim Pausen-Ende**: nutzt die bestehende `TIMER_START`→SW-`setTimeout`→`onTimerDone()`-Kette (Pausen sind normale Countdown-Timer) statt eines neuen Mechanismus. `swSend({type:'TIMER_START', ..., autoResume: !!workStash})` — `!!workStash` ist zum Sendezeitpunkt korrekt, weil der Stash für die gesamte Pausendauer gesetzt bleibt (erst `switchTo('work',...)` am Pausen-Ende konsumiert ihn). SW merkt sich `pendingAutoResume` neben `pendingMode`; `onTimerDone()` wählt bei `pendingAutoResume` den Text „Fokus läuft automatisch weiter" statt „Bereit für den nächsten Fokus?"
- **4-Uhr-Grenze während einer Pause**: `checkDayRollover()` prüft zusätzlich zum bestehenden `mode==='work'`-Pfad unabhängig davon, ob `workStash` einen veralteten `pomoDay` hat (kann nur passieren, wenn `mode==='short'` aktiv ist, sonst gäbe es keinen Stash) — kreditiert dessen Restzeit separat und leert nur die `stash_*`-Spalten server-seitig (`saveTimerState(stashPayload())`, kein `clearTimerState()`), ohne den aktiven Pausen-Timer anzutasten. Kein Claim-Mutex für diesen Pfad (anders als der Haupt-Rollover) — bei mehreren gleichzeitig offenen Geräten während exakt dieses seltenen Zeitfensters theoretisch doppelt kreditierbar, als bekannte Einschränkung akzeptiert

### 4-Uhr-Reset laufender/pausierter Fokus-Sessions
- Um 4 Uhr Berliner Zeit wird jede laufende oder pausierte Fokus-Session (Countdown **und** Limitless) automatisch wie ein „✓ Jetzt" beendet: nur die bis 4 Uhr tatsächlich verstrichene Zeit wird ermittelt, danach Leerlauf — kein automatisches Fortsetzen, kein Toast (still). **Für eine laufende/pausierte Limitless-Session (`mode==='work' && limitless`) wird diese Zeit seit „Vergessene Limitless-Timer" (siehe unten) nicht mehr direkt auf `pomoday` (Vortag) gutgeschrieben, sondern zur Bestätigung zwischengespeichert** — der Countdown-Fall (nicht limitless) bleibt unverändert eine direkte, stille Gutschrift, da dort kein „vergessen laufen gelassen"-Fairness-Problem existiert (feste, vom Nutzer selbst gewählte Dauer)
- **Client**: `checkDayRollover()` (index.html, neben `checkLimitlessCheckpoint()`) prüft `todayKey() !== pomoDay`; aufgerufen von `start()` (vor der eigentlichen Start/Pause-Logik, macht den Check unabhängig vom Watchdog-Zustand), den Mode-Button- und `btn-reset`-Klick-Handlern (sonst ginge der Fortschritt beim `reset()` verloren, ohne kreditiert zu werden), dem `visibilitychange`-Handler und einem 60s-Watchdog-`setInterval`
- Watchdog setzt sich nach 2h Inaktivität (`!running` und `lastTimerInteractionAt` >2h her) selbst aus; `markTimerActivity()` (in `start()`, `reset()`, `finishEarly()`, `skip()`) reaktiviert ihn beim nächsten Timer-Klick synchron innerhalb desselben Aufrufs — nicht erst beim nächsten Watchdog-Tick
- `clearTimerState()` dient als Claim-Mutex gegen den Server-Cron (siehe unten) — wer zuerst die `timer_state`-Zeile löscht, kreditiert; der andere setzt nur lokal in den Leerlauf zurück
- **Server**: `reset_stale_work_sessions()` (SECURITY DEFINER, `supabase/migrations/20260708000000_reset_stale_work_sessions.sql`), per `pg_cron` alle 5 Minuten. Grenzwertbasiert statt zeitpunktbasiert geprüft (`4:00 Berlin AT TIME ZONE`, DST-sicher) — läuft auch, wenn niemand die Seite offen hat (z.B. Limitless-Session über Nacht bei geschlossenem Tab). Rührt bereits vor 4 Uhr regulär abgelaufene Countdown-Sessions bewusst nicht an (bestehendes „nie zurückgekehrt"-Verhalten, kein Teil dieses Features)
- **Bugfix (`20260711000000_fix_reset_cron_double_credit.sql`)**: Der Cron kreditierte ursprünglich **vor** dem `DELETE FROM timer_state`, ohne zu prüfen, ob die Zeile zu dem Zeitpunkt überhaupt noch existierte — lief eine Session dem Client-seitigen `checkDayRollover()` im selben 5-Minuten-Fenster über den Weg, konnte dieselbe Restzeit doppelt kreditiert werden (sichtbar u.a. als überzählige Medaillen in `leaderboard_wins()`, die live aus `study_days` rechnet). Jetzt: `DELETE ... RETURNING *` zuerst, nur bei tatsächlich gelöschter Zeile wird mit den frisch gelöschten Werten kreditiert (Claim-Mutex jetzt symmetrisch zum Client)
- **Bugfix (`20260712000000_fix_daily_winners_timing.sql`)**: Der separate `daily-winners`-Cron (Diamanten-Auszahlung, globale Top-3 unabhängig vom Clan) lief fix um 01:59 UTC (~03:59 Berlin im Sommer, ~02:59 im Winter) — **vor** der echten 4-Uhr-Grenze. Bei kurzen Pomodoros fiel das nie auf, aber eine über Nacht laufende Session wird erst nach 4 Uhr durch `reset_stale_work_sessions()` final verbucht; lief `daily-winners` davor, fehlte genau dieser letzte Rest in `daily_winners` — und wegen `ON CONFLICT (date, rank) DO NOTHING` nie nachträglich korrigierbar. Jetzt: alle 5 Minuten geprüft, aber nur ausgewertet sobald `extract(hour from ... at time zone 'Europe/Berlin') >= 4` (davor liefert die CTE 0 Zeilen, reiner No-Op), zeitlich 2 Minuten nach `reset-stale-work-sessions` versetzt (`2-59/5 * * * *` vs. `*/5 * * * *`), damit übrig gebliebene Nacht-Sessions garantiert zuerst verbucht sind. **Wichtig**: `leaderboard_wins()`/`get_yesterday_winner()` (clan-scoped, live aus `study_days`) sind davon nicht betroffen und waren nie das Problem — `daily_winners` ist die **globale** Top-3-Rangliste (alle öffentlichen Nutzer, unabhängig vom Clan), nur für die Diamanten-Auszahlung; unterschiedliche Rangfolgen zwischen beiden sind normal und kein Fehler

### Vergessene Limitless-Timer: 3h-Watchdog + Pending-Focus-Stash

Der 4-Uhr-Reset (oben) fängt den Fall „Laptop zu/Tab eingefroren über Nacht" ab. Der verbleibende Fairness-Fall: eine Limitless-Session läuft in einem aktiven, nicht eingefrorenen Tab weiter, während der Nutzer schlicht nicht mehr am Platz ist — `checkLimitlessCheckpoint()` kreditiert dabei stundenlang echte, aber fiktive Fokuszeit. Migrationen `20260721000000_pending_focus_sessions.sql` / `20260721000010_reset_stale_work_sessions_pending.sql`.

- **Nur Limitless betroffen** (`mode==='work' && limitless`) — ein Countdown ist durch seine feste, selbst gewählte Dauer von sich aus begrenzt, kein Teil dieses Features.
- **Zwei unabhängige Auslöser**, die beide statt direkter Kreditierung eine **Bestätigung** verlangen:
  1. **3h-Idle**: keine **manuelle** Interaktion (Start-Klick, manueller Moduswechsel in die Pause) seit `unbrokenSince` (`UNBROKEN_THRESHOLD_MS`, 3h). Automatische Pausen-Zyklen (`interruptWorkForBreak(true)`, Auto-Resume via `workStash`) zählen **nicht** als Unterbrechung — bei „Automatische Pausen" ist das durchgehende Weiterlaufen über Checkpoints/Pausen hinweg ausdrücklich erwünschtes Verhalten, `unbrokenSince` bleibt dabei unverändert stehen.
  2. **4-Uhr-Grenze**: wie beim bestehenden `checkDayRollover()`-Boundary-Fall, aber für Limitless-Sessions jetzt ebenfalls über Bestätigung statt Direktkredit (siehe „4-Uhr-Reset" oben).
- **`unbrokenSince`** (Client-Variable, `timer_state.unbroken_since` als Server-Pendant): Zeitpunkt des letzten manuellen Play-Klicks/Mode-Wechsels. Gesetzt in genau 2 Stellen (`btn-start`-Click-Handler bei `!running`, `interruptWorkForBreak(auto)` nur im `!auto`-Zweig); zurückgesetzt auf `null` in `reset()`, `finishEarly()`, `switchTo()`s frischem Fokus-Start (kein Stash) und `stopAndStashUnbrokenSession()`. Lebt unabhängig von `workStash` — Auto-Resume nach einer automatischen Pause fasst `unbrokenSince` nicht an.
- **Client-Flow**: `checkUnbrokenThreshold()` (aus `tick()`, nach `checkLimitlessCheckpoint()`, nur wenn die Session danach noch läuft) → bei Schwellenüberschreitung `triggerUnbrokenConfirm()` → Banner `#idle-confirm-banner` (`showIdleConfirmBanner()`, 2-Minuten-Countdown, `UNBROKEN_CONFIRM_WINDOW_MS`). „Ich bin noch da" setzt `unbrokenSince` neu (Session läuft normal weiter); Timeout oder „Anhalten" ruft `stopAndStashUnbrokenSession('idle_3h')` — strukturell wie `finishEarly()`, aber ohne `completePomo()`: Claim-Mutex (`clearTimerState()`), dann `stashFocusSession()` statt Direktkredit.
- **`stashFocusSession(key, minutes, label, reason)`**: POST auf `pending_focus_sessions` über `tryPostPendingFocusSession()`. Nur anonyme Nutzer fallen auf `creditFocusMinutes()` (Direktkredit) zurück. **Bugfix**: ursprünglich fielen auch Netzwerk-/Token-Fehler auf Direktkredit zurück — das reproduzierte in der Praxis genau den Bug, den dieses Feature verhindern soll, da ein abgelaufener/nicht erneuerbarer Token bzw. ein kurzzeitig instabiles Netzwerk direkt beim Aufwachen aus dem Standby am wahrscheinlichsten sind (also exakt der Moment, in dem eine übernächtigte Session gestasht werden soll). Jetzt: bei eingeloggten Nutzern queued ein Fehlschlag stattdessen lokal (`queuePendingStash()`, `PENDING_STASH_KEY`, analog `PENDING_KEY`/`writeOrQueueCredit()`) und wird per `drainPendingStashQueue()` beim nächsten `online`-Event bzw. Login nachgeholt — kein Direkt-Credit-Fallback mehr für diesen Pfad.
- **`creditFocusMinutes(key, minutes, label)`**: gemeinsamer Kern von `completePomo()`/`checkLimitlessCheckpoint()`/`checkDayRollover()` — lokale Minuten-Gutschrift + Server-Write (nur wenn `minutes > 0`) + Level-Up/Ei/Brutkasten-Checks + Re-Renders, per Refactoring aus den vormals dreifach duplizierten Blöcken extrahiert.
- **Restore-Pfad** (`restoreTimerStateInner()`, Limitless-Zweig): liest `unbroken_since` (Fallback `startedAt` für Altzeilen von vor diesem Feature). Prüft zuerst die 4-Uhr-Grenze (`todayKey() !== pomoDay` → `checkDayRollover()`, gleiche Vorrangregel wie in `checkLimitlessCheckpoint()`), erst danach die Idle-Schwelle. Ist die Schwelle beim Wiederaufwachen bereits überschritten, **kein** stiller Checkpoint-Catchup mehr, sondern sofort `triggerUnbrokenConfirm()` — sonst wie zuvor `checkLimitlessCheckpoint()` + `scheduleUnbrokenTargetIfPending()`. **Bugfix**: die Idle-Schwelle wurde ursprünglich vor der 4-Uhr-Grenze geprüft — bei einer übernächtigten Session konnte das den Idle-Confirm-Banner gleichzeitig mit dem durch den bereits armierten `tick()` ausgelösten `checkDayRollover()` feuern lassen; bestätigte der Nutzer den Banner danach noch, schrieb der Resolve-Handler `unbroken_since` per Upsert in eine bereits von `checkDayRollover()` gelöschte `timer_state`-Zeile zurück (verwaiste Zeile, nur `unbroken_since` gesetzt).
- **SW-Scheduling**: `scheduleUnbrokenTargetIfPending()` (analog `schedulePRTargetIfPending()`) sendet `UNBROKEN_TARGET_SCHEDULE` an den SW, aufgerufen in `start()`s Limitless-Zweig (deckt manuellen Start **und** Auto-Resume ab) sowie in `restoreTimerStateInner()`, wenn die Schwelle noch nicht erreicht ist. SW (`sw.js`): `scheduleUnbrokenTarget()`/`onUnbrokenTarget()`, one-shot wie PR-Target, Notification-Tag `pomodoro-unbroken-check`, zeigt nur eine Notification (kein Client-Wake-Postmessage nötig — Klick fokussiert den Tab, `visibilitychange` löst `tick()`/`checkUnbrokenThreshold()` dann selbst aus). Wird wie Eye-Break/PR-Target/Auto-Break beim zentralen `TIMER_RESET` in `switchTo()` mitgelöscht.
- **Pending-Liste** (Timer-Card, ausklappbar wie die Deck-Box, nur sichtbar wenn nicht leer): `loadPendingFocusSessions()` (beim Login, neben `loadTradeNotifications()`) zeigt zusätzlich einen einmaligen `toast()` beim Login, falls nicht leer (sonst leicht übersehene, eingeklappte Liste), `renderPendingFocusList()`, „Gutschreiben" (`claimPendingFocusSession()`, Claim-Mutex `DELETE ... RETURNING *` wie überall sonst in dieser Codebase, danach `creditFocusMinutes()`) oder „Löschen" (`deletePendingFocusSession()`, reines DELETE, kein Kredit).
- **Server (`reset_stale_work_sessions()`, dritte Fassung)**: zwei unabhängige Trigger-Bedingungen (`v_trigger_boundary`, `v_trigger_idle`) statt nur einem; `v_trigger_idle` greift nur bei `limitless AND unbroken_since IS NOT NULL AND now() >= unbroken_since + 3h10min` — der 10-Minuten-Puffer gibt dem Client (3h + 2min Bestätigungsfenster) garantiert Vorrang, der Cron greift nur bei einem wirklich nicht mehr reagierenden Tab. Minuten weiterhin an `v_cap := LEAST(now(), v_boundary)` gedeckelt (auch im reinen Idle-Fall). Kreditierung geht für Limitless-Funde in `pending_focus_sessions`, für Countdown-Funde (nur über den Boundary-Trigger erreichbar) unverändert direkt in `study_days`/`pomodoro_sessions`. Claim-Mutex bleibt das bestehende `DELETE ... RETURNING *`-Pattern.
- **Nebenwirkung**: `daily-winners`, Wochen-Challenges und `leaderboard_wins()` lesen weiterhin live aus `study_days` — eine gestashte, noch nicht bestätigte Session fehlt dort, bis „Gutschreiben" geklickt wird. Da `daily_winners` `ON CONFLICT DO NOTHING` nutzt, kann ein spät bestätigter Tag einen bereits verteilten Tagessieg nicht mehr rückwirkend gewinnen — beabsichtigt (kein stiller Auto-Credit mehr), keine bekannte Korrektur nötig.
- **Race-Conditions**: Doppelklick „Gutschreiben" und Multi-Device sind über den Claim-Mutex abgesichert. Client-Live-Auflösung hat gegenüber dem Cron (10-Minuten-Puffer) definitiv Vorrang; friert der Tab exakt während der offenen Bestätigung ein, übernimmt ausschließlich der Cron. Migrations-Rollout: `timer_state`-Zeilen ohne `unbroken_since` (Altzeilen) lösen serverseitig nie den Idle-Pfad aus (`IS NOT NULL`-Bedingung), clientseitig fällt der Restore auf `startedAt` zurück.

### Timer State Persistence (Supabase)
- Laufender Countdown-Timer: `end_at` gesetzt, `limitless = false`
- Laufende Limitless-Session: `started_at` gesetzt (Pendant zu `end_at`), `end_at = null`, `limitless = true`, `credited_min` = zuletzt kreditierter Stand
- Pausierter Timer: `end_at = null` (bzw. `started_at = null` bei Limitless), `paused_remaining` gesetzt
- Bei Seitenaufruf: `restoreTimerState()` liest den State und setzt fort (Countdown oder Stoppuhr) oder krediert abgelaufene Pomodoros
- **Spalte heißt `pomoday` (Kleinschreibung)**, nicht `pomoDay` — ein früherer Bug las sie beim Restore fälschlich als `state.pomoDay` (immer `undefined`); beide Restore-Zweige lesen jetzt korrekt `state.pomoday`
- `start()` überschreibt `pomoDay` beim Fortsetzen nach Pause **nicht** mehr (nur `if (pomoDay == null)`) — verhindert, dass ein Pause-Resume kurz vor 4 Uhr den Kredit-Tag verschiebt
- **Bugfix (Zuverlässigkeit, kein neues Feature)**: `saveTimerState()` war fire-and-forget (kein `res.ok`-Check, keine Retry-Queue) — ein Netzwerkfehler/abgelaufener Token beim Pause-Klick ließ die Pause den Server nie erreichen, ein Reload dachte danach fälschlich, der Timer liefe noch weiter. Jetzt gemergter Pending-Blob (`PENDING_TIMER_KEY = 'pomo_pending_timer_state'`, analog `PENDING_KEY`, aber "letzter Schreibversuch pro Feld gewinnt" statt additive Queue, da `timer_state` nur eine Zeile pro Nutzer ist): jeder `saveTimerState()`-Aufruf mergt den übergebenen `state` **synchron vor jedem `await`** in den Blob, `fetch` bekommt zusätzlich `keepalive:true` + einen `res.ok`-Check, bei Erfolg wird der Blob gelöscht. `drainPendingTimerState()` (Muster wie `drainPendingCredits()`) versucht einen stehengebliebenen Blob erneut zu schreiben — aufgerufen im `online`-Listener, im `visibilitychange`-Handler und in `onLoginSuccess()`. `restoreTimerState()` mergt einen noch vorhandenen Blob **über** den vom Server geladenen State (Pending-Werte gewinnen, sie sind die zuletzt bekannte, nie angekommene Absicht), bevor `restoreTimerStateInner()` läuft — das ist der eigentliche Fix für das Reload-Symptom. Nebenbei: `state.paused_remaining` wird jetzt `!= null` statt truthy geprüft (ein bei exakt 0 pausierter Countdown wurde sonst beim Reload gar nicht restauriert), und die drei `saveTimerState(...)`-Aufrufe in `start()` sind jetzt `await`ed (verhindert ein Race bei schnellem Doppel-Klick).
- **Bugfix (Zuverlässigkeit)**: `sbAuth()` (Login/Register/Refresh-Token-Fetch) hatte kein try/catch — ein Netzwerkfehler warf durch `refreshSession()`/`getValidToken()` hindurch. Da `addStudyMinutes()`/`savePomoSession()` `await getValidToken()` **vor** ihrem eigenen `try` aufrufen, verließ die Exception die Funktion komplett statt `false` zu liefern — das ließ `Promise.all` in `writeOrQueueCredit()` rejecten, und weil der Aufruf in `creditFocusMinutes()` unawaited war, wurde `queuePendingCredit()` (das eigentlich für genau diesen Fall gebaute Sicherheitsnetz) nie erreicht. Ein Limitless-Checkpoint-Kredit ging dadurch beim nächsten Reload/Login (`loadStudyDays()` überschreibt `days` komplett vom Server) sichtbar verloren. Jetzt: `sbAuth()` fängt Fehler ab und gibt `{}` zurück (alle Aufrufer prüfen ohnehin schon `data.access_token`/`data.error_description` truthy), `creditFocusMinutes()` hat zusätzlich ein `.catch()` auf `writeOrQueueCredit()` als zweites Sicherheitsnetz. `drainPendingCredits(applyLocalDelta)`: `true` direkt nach Login/Reload (wo `days` gerade frisch vom Server kam und ein nachgelieferter Credit sonst erst nach einem weiteren kompletten Reload sichtbar würde), `false` (Default) im laufenden Betrieb (z.B. `online`-Listener), wo `days` den Bump aus `creditFocusMinutes()` schon im Speicher hat — ein erneuter Bump dort würde doppelt zählen.

---

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

- **Placeholder**: `#egg-placeholder-overlay` mit `backdrop-filter:blur(12px)` über `#egg-section-wrapper`. Clan-Leader kann via Settings-Toggle + `localStorage('pomo_egg_preview')` deaktivieren.
- **Bilder**: serviert via jsDelivr (`CDN`-Konstante). Eier: `CDN/Eier/<farbe>/Stadium_<1-4>.png`. Karten: `CDN/Karten/<rarität>/<name>.png`.
- **`draw_card()` RPC**: serverseitig, `SECURITY DEFINER`, schreibt in `user_cards` und gibt `card_id` zurück. Client schlägt Karte in `CARD_CATALOG` nach.
- **`bonusMin`**: lokales Offset auf `focus_minutes_at_placement` für optimistische -1h/Skip-Updates. Wird nach Supabase-Write auf 0 normalisiert.

### Wochen-Challenges

- Woche = Montag 4 Uhr Berlin bis Sonntag 4 Uhr Berlin (gleiche Grenze wie `todayKey()`), berechnet über `getWeekStartKey()`
- 3 Stufen (Leicht 1💎/Mittel 3💎/Schwer 5💎), je 3 aktive Challenges aus einem festen 6er-Pool pro Stufe — deterministische Rotation über `getWeekIndex()` + `CHALLENGE_TIER_OFFSET` (versetzt: leicht=0, mittel=2, schwer=4, damit nicht alle Stufen synchron rotieren), **kein Zufall, keine Server-Speicherung der „aktiven" Auswahl nötig** — `CHALLENGE_POOL` (Client) und die `weekly_challenges`-Tabelle (Server, `pool_index`) müssen synchron gehalten werden, exakt wie `CARD_CATALOG` zu `cards`
- Fortschritt wird rein aus `study_days` abgeleitet (`total_minutes`, `weekend_minutes` = Sa+So-Summe, `count_days_threshold` = Anzahl Tage mit ≥ `param_h` Minuten, `streak_days` via wochenbegrenzter Streak-Logik) — **"10 Pomodoros" ist ein Minuten-Schwellenwert (250 Min.)**, keine Zeilenanzahl aus `pomodoro_sessions` (die ist durch `+5min`/Limitless-Checkpoints/4-Uhr-Reset ohnehin nicht zuverlässig als "1 Zeile = 1 Pomodoro" auswertbar)
- **Claim**: manueller „Einlösen"-Button, `claim_weekly_challenge()` RPC berechnet Rotation + Fortschritt serverseitig neu (kein Vertrauen auf Client-Werte), `UNIQUE(user_id, week_start, challenge_key)` verhindert Doppel-Claims
- Client-Rendering (`renderChallengesCard()`) und Fortschrittsberechnung (`computeChallengeProgress()`) laufen rein lokal aus bereits geladenen `days`/`offDays`/`offWeekdays` — kein zusätzlicher Fetch pro Anzeige, nur `loadWeeklyClaims()` einmal beim Login
- **Bugfix (`20260710000000_fix_calc_week_streak.sql`)**: `calc_week_streak()` ließ `v_off_override`/`v_minutes` bei Tagen ohne `study_days`-Zeile auf dem Wert der vorherigen Schleifen-Iteration stehen (PL/pgSQL `SELECT INTO` setzt Variablen bei 0 Treffern nicht auf `NULL` zurück) — konnte eine gültige Streak-Challenge fälschlich mit `threshold_not_met` ablehnen. Variablen werden jetzt vor jedem `SELECT INTO` explizit auf `NULL` zurückgesetzt.
- **Bugfix `getWeekIndex()`**: parste Datumsstrings ohne Zeitzonen-Suffix (`new Date(str + 'T00:00:00')`) — dadurch floss die lokale Browser-Zeitzone in die Millisekunden-Differenz zum Epoch-Datum ein. Liegen Epoch (Winter, UTC+1) und Zielwoche (Sommer, UTC+2) auf verschiedenen Seiten einer Sommerzeit-Umstellung, verschiebt sich der Tagesabstand um 1h und `Math.floor(diff / 7 Tage)` kann in genau den betroffenen Wochen um 1 zu niedrig ausfallen — Client und Server (reine Kalender-Arithmetik `date - date`, DST-immun) laufen dann bei der Rotation auseinander (`challenge_not_active_this_week` trotz im Frontend als aktiv angezeigter Challenge). Fix: `'T00:00:00Z'`-Suffix erzwingt UTC-Parsing auf beiden Seiten.

### Zusätzliche Diamanten-Quellen (Streak-Meilensteine, Perfekte Woche, Set-Bonus)

Drei weitere, voneinander unabhängige Diamanten-Einnahmequellen neben Tagessiegen und Wochen-Challenges. Alle drei folgen demselben Grundmuster wie `claim_weekly_challenge()`: eine Tabelle `<feature>_claims` (Claim-Mutex via `PRIMARY KEY(user_id, ...)`, `INSERT` läuft vor der `UPDATE profiles`-Gutschrift — ein `UNIQUE`-Violation bricht die Funktion vor der doppelten Gutschrift ab) + eine `SECURITY DEFINER`-RPC `claim_<feature>(...)`, die den Anspruch **serverseitig aus `study_days`/`user_cards` neu berechnet**, nie dem Client vertrauend (Migrationen `20260724000000_streak_milestones.sql`, `20260724000001_perfect_week.sql`, `20260724000002_set_bonus.sql`). Client lädt den Claim-Status beim Login (`loadStreakMilestoneClaims()`/`loadPerfectWeekClaim()`/`loadSetBonusClaims()`, analog `loadWeeklyClaims()`), Fortschrittsanzeige läuft überall rein lokal aus bereits geladenen Daten (kein Extra-Fetch), nur der Claim selbst geht über die RPC.

- **Streak-Meilensteine**: einmaliger Bonus bei 7/14/30/60/100/200/365 Tagen Streak. `streakMilestones` (Client) wird per `loadStreakMilestones()` live aus der `streak_milestones`-Tabelle geladen (`select=days,reward_diamonds`, öffentlich lesbar via RLS, kein Login nötig) — die Tabelle ist Single Source of Truth für **sowohl** Anzeige **als auch** Claim (`claim_streak_milestone()` liest `reward_diamonds` ohnehin schon serverseitig live). Ändert man Werte/Zeilen in `streak_milestones` direkt in Supabase, wirkt sich das ohne Code-Änderung auf der Seite aus. **Anders als** `CHALLENGE_POOL`/`weekly_challenges` und `CARD_CATALOG`/`cards`, die weiterhin hardcodiert und manuell synchron gehalten werden müssen. Eigener 4. Tab „Meilensteine" in `#challenges-card` (`renderMilestonesList()`, Progress via `computeCurrentStreak()`). Serverseitige Neuberechnung über `calc_current_streak()` — eine unbegrenzte Variante von `calc_week_streak()` mit identischer Semantik zu `computeCurrentStreak()` (kein Off-Day-Skip, heutiger leerer Tag bricht nicht ab).
- **Perfekte Woche**: Bonus, wenn alle 7 Tage der aktuellen App-Woche `minutes >= 60` (mind. 1 Stunde) in `study_days` haben — freie Tage retten nicht (gleiche Designentscheidung wie bei Streaks). Reward-Höhe kommt aus der Singleton-Tabelle `perfect_week_config` (id=1, Default 15 💎) — analog `streak_milestones` per Supabase direkt editierbar, ohne Code-Änderung. Client lädt den Wert per `loadPerfectWeekConfig()` (`perfectWeekReward`, im Login-Flow neben `loadPerfectWeekClaim`) für die Anzeige; `claim_perfect_week()` liest denselben Wert serverseitig live beim Claim (`20260725000010_perfect_week_config.sql`). Immer sichtbare Zeile `#perfect-week-row` oberhalb der Tier-Tabs in `#challenges-card` (`renderPerfectWeekRow()`, tier-unabhängig), wird zusätzlich aus `creditFocusMinutes()` neu gerendert (kein Fetch), damit der Fortschritt sofort nach jeder Session aktuell ist. `claim_perfect_week()` verlangt serverseitig zusätzlich `today >= week_start + 6` (Woche muss vorbei sein) als Verteidigung in der Tiefe, da `study_days`-Schreibpfade das Datum nicht gegen „heute" validieren (siehe `add_study_minutes` unten). Die 60-Minuten-Schwelle selbst ist weiterhin serverseitig hardcodiert (`20260725000000_perfect_week_min_60min.sql`), nur die Reward-Höhe ist tunable.
- **Set-Bonus**: einmaliger Bonus pro Rarität für „mind. 1 Kopie jeder Katalog-Karte dieser Rarität besitzen" (`SET_BONUS_REWARD`, muss synchron zu den `CASE`-Werten in `claim_set_bonus()` gehalten werden). Reward-Höhe folgt der tatsächlichen Set-Schwierigkeit (Coupon-Collector-Erwartungswert aus Katalog-Größe × Ziehquote), nicht der reinen Rarität-Bezeichnung: common 15💎, legendary 20💎, epic 25💎, mystic 35💎, **rare 50💎** — „rare" (17 Katalog-Karten) ist trotz gemäßigter Ziehquote (30 %) das mit Abstand schwerste Set zu komplettieren, schwerer noch als „mystic" (2 Karten, aber nur 3 % Ziehquote). Neue Sektion `#setBonusList` in der Deck-Box (`renderSetBonusSection()`, Fortschritt aus `eggDeck` vs. `CARD_CATALOG`, gruppiert nach `rarity.folder`), gerendert am Ende von `renderEggDeck()` — bleibt dadurch automatisch synchron mit Schlüpfen/Trade-Annahme/Login, ohne separate Call-Sites pflegen zu müssen.
- **Bekannte Schwäche (geteilt, kein neues Risiko)**: `add_study_minutes`/direktes PATCH auf `study_days` validieren das Datum nicht gegen „heute" (siehe `add_study_minutes` in „Bekannte Designentscheidungen") — theoretisch könnte ein manipulierter Client zukünftige Tage der laufenden Woche vorab beschreiben. Bestehende Schwäche, die auch die Wochen-Challenges schon haben; „Perfekte Woche" mildert sie zusätzlich über die `week_not_over`-Prüfung, schließt sie aber nicht vollständig.

### Bento-Grid-Layout (Desktop, Einstellungen-Opt-in)

Ab `min-width:1024px` können die 7 Karten statt im reinen vertikalen Stack in einem Bento-Grid angeordnet werden: Timer volle Breite oben, darunter Heatmap+Aufmerksamkeit+Stats zu je einem Drittel, darunter Wochen-Challenges (~40%) + Ei/Deck (~60%), darunter Leaderboard als eigene volle Reihe. Zentriert auf `max-width:900px`.

- **Opt-in, Default aus**: neue Settings-Checkbox „Neues Design (Beta)" (Sektion „Layout", zwischen „Anzeigeeinheit" und „Freie Wochentage"), `localStorage` Key `pomo_new_design_v1`, geräte-lokal. `newDesignOn`-Variable, `initNewDesignSetting()` (Muster wie `initLimitlessSetting()`) togglet `body.new-design`. Ohne diese Einstellung ist das Layout auch ab Desktop-Breite exakt wie vor diesem Feature — jederzeit über die Checkbox rückgängig machbar, falls das neue Layout Probleme macht. Wird die Checkbox während eines aktiven Bento-Edit-Modus (siehe unten) ausgeschaltet, beendet das den Editor zwangsweise mit.
- **DOM**: `#timer-card` steht immer außerhalb/oberhalb jeder `.bento-row`, volle Breite, nie Teil des Grids. Die restlichen 7 Kacheln (`#heatmap-card`, `#attention-card`, `#stats-card`, `#challenges-card`, `#egg-section-wrapper`, `#leaderboard-card`, `#race-track-card`) sind reale, dauerhafte DOM-Knoten — es gibt nur eine generische `.bento-row`-Klasse, keine `-main`/`-secondary`/`-leaderboard`-Varianten. Welche Kachel in welcher Zeile mit welcher Breite/Höhe steht, ist zur Laufzeit vollständig datengetrieben (siehe „Layout-Datenmodell" unten) — `applyBentoState(state)` (Orchestrator) parkt zuerst jede nicht-platzierte Kachel im permanenten Halte-Container `#bento-removed-pool` (siehe „Kachel entfernen/wiederherstellen" unten), dann reißt `applyCustomBentoLayout(rows)` bei jedem Aufruf alle vorhandenen `.bento-row`-Wrapper ab und baut sie aus dem `rows`-Array neu auf, wobei die echten Kachel-Elemente per `appendChild` umgehängt werden (kein Klonen, keine Listener-/Inhalts-Verluste). `applyCustomBentoLayout(rows)` selbst wird nie mehr direkt von außen aufgerufen, nur noch von `applyBentoState`.
- **CSS**: `.bento-row { display:contents; }` als Default (mobil/Toggle-aus: pixelgleich zu vorher, kein eigener Layout-Effekt). Nur wenn **beides** zutrifft — `body.new-design` UND `@media(min-width:1024px)` — wird `.bento-row` zu `display:flex; width:100%; gap:1.25rem;`. `width:100%` ist hier nötig (wie bei `.header`/`.card`/`#egg-section-wrapper`), sonst gerät der Flex-Container ohne eigene Breite mit seinem `width:100%`-Kind in einen Shrink-to-fit-Zirkelbezug und wird zu schmal (`body`s `align-items:center` stretcht Top-Level-Kinder nicht). Ausgeblendete Kacheln (z. B. Challenges vor Login, Leaderboard ohne Public-Clan) erzeugen kein Flex-Item (`display:none`) — das verbleibende Geschwister füllt die Lücke automatisch, Leaderboard-Reihe kollabiert auf Höhe 0.
- Fokus-Intervall/Zoom-Details (Hero-Vergrößerung `#time-display`/`#watch-svg`) ebenfalls nur unter `body.new-design`.

#### Layout-Datenmodell & In-Page-Editor

Der vollständige Zustand ist `state: { rows: Array<Array<{ id: TileKey, flex: number, height?: number|null }>>, removed: TileKey[] }` — `rows` wie zuvor (Array von Zeilen, jede Zeile ein Array von Kachel-Einträgen; `id` einer der 7 Schlüssel aus `BENTO_TILE_META`, `flex` steuert den Breitenanteil analog CSS `flex-grow`, `height` optional in px, fehlt/`null` = natürliche Höhe), `removed` ist neu (siehe „Kachel entfernen/wiederherstellen" unten) und enthält die IDs der vom Nutzer entfernten Kacheln. `bentoDefaultRows()` bildet weiterhin die ursprüngliche Zeilen-Aufteilung ab (Heatmap+Aufmerksamkeit+Stats je 1/3, Challenges 40%/Ei&Karten 60%, Rennstrecke allein, Leaderboard allein), `bentoDefaultState() = { rows: bentoDefaultRows(), removed: [] }`.

**Zwei-stufige Validierung**: `isValidBentoRows(rows)` prüft nur noch Form/Werte (`flex`/`height` positive Zahlen, keine Kachel doppelt platziert) — verlangt anders als früher **nicht** mehr, dass alle Kacheln vorkommen, da `rows` jetzt eine echte Teilmenge sein darf. `isValidBentoState(state)` prüft zusätzlich die vollständige, disjunkte Abdeckung: jede der 7 `BENTO_TILE_META`-IDs muss genau einmal vorkommen — entweder in `rows` oder in `removed`, nie beides, nie keins — und `removed` darf nie eine `BENTO_NON_REMOVABLE`-ID enthalten. Bei jeder Abweichung fällt `loadBentoState()`/`reconcileBentoState()` auf `bentoDefaultState()` zurück. **Rückwärtskompatibilität**: `normalizeBentoState(parsed)` hebt einen alten, bloßen `rows`-Array (Format vor der „Kachel entfernen"-Funktion, ebenso ein altes 5-/6-Tile-Layout vor Rennstrecke/Aufmerksamkeit) transparent zu `{ rows: parsed, removed: [] }` — fehlen dabei neu hinzugekommene Kacheln, greift danach ganz normal der `isValidBentoState`-Fallback auf `bentoDefaultState()` (identisches, bereits bekanntes Verhalten wie beim Rollout der Rennstrecken-/Aufmerksamkeits-Kachel: betroffene Nutzer bekommen ihr Custom-Layout beim nächsten Laden einmalig zurückgesetzt).

**Kein Overlay, keine Platzhalter** — der Editor manipuliert direkt die echten Kacheln auf der Seite:
- **Start**: Settings-Button `#bento-layout-editor-btn` („Layout bearbeiten", nur aktiv wenn `newDesignOn`) → `enterBentoEditMode()`. Schließt das Settings-Panel, beendet einen aktiven Fokus-Modus zwangsweise (der blendet genau die 7 Zielkacheln aus — sonst gäbe es nichts zu bearbeiten), bricht bei Viewport `<1024px` mit einem `toast()`-Hinweis ab (Bearbeitung ergibt im mobilen Stacked-Layout keinen Sinn), sonst `body.bento-edit-mode` setzen.
- **Chrome**: pro Kachel ein Verschiebe-Griff (`.bento-edit-grip`, oben links, `⠿`), ein Resize-Handle (`.bento-edit-resize-handle`, unten rechts) und — nur für nicht-`BENTO_NON_REMOVABLE`-Kacheln — ein Entfernen-Button (`.bento-edit-remove-btn`, oben rechts, `✕`) werden einmalig lazy injiziert (`ensureBentoEditChromeInjected()`, idempotent) und bleiben danach dauerhaft im DOM — nur ihre CSS-Sichtbarkeit hängt an `body.bento-edit-mode` (gleiches Muster wie `#focus-toggle-btn`/`body.focus-mode`, vermeidet Listener-Leaks durch wiederholtes Erzeugen/Entfernen). Zusätzlich pro Zeile eine gestrichelte Outline + ein dekoratives Drittel-Raster (`::before`) zur Orientierung — rein optisch, kein festes Snap-Grid, verschwindet beim Verlassen des Modus.
- **Verschieben**: Pointer-Events (kein natives HTML5-DnD, wie an anderer Stelle z. B. bei `bindIncubatorDragDrop` — hier bewusst wegen kontinuierlichem Hit-Testing/Touch-Unterstützung). `startBentoTileDrag`/`onBentoTileDragMove`/`onBentoTileDragEnd`: Hover über einen schmalen, nur im Edit-Modus vorhandenen `.bento-edit-gap`-Streifen zwischen/um echte `.bento-row`s → neue Zeile; Hover über eine bestehende Zeile → Insert-Index aus den Mittelpunkten der (sichtbaren) Geschwister-Kacheln. Ausgeblendete Kacheln (z. B. Leaderboard vor Login) werden aus dieser Mittelpunkt-Berechnung gefiltert (`offsetParent !== null`), da ihr `getBoundingClientRect()` sonst 0-groß wäre und den Index verfälschen würde. Beim Drop: sofortiger Live-Reflow (`applyBentoState` + `persistBentoState`), kein separater „Übernehmen"-Schritt — die Seite selbst *ist* der Editor. Die eigentliche Splice-Logik (Kachel-ID aus `rows` entfernen, leere Zeilen bereinigen) ist als `spliceOutOfBentoRows(rows, tileId)` extrahiert — gemeinsam genutzt von `onBentoTileDragEnd` und `removeBentoTile()`.
- **Größe ändern**: `startBentoTileResize`, Pointer-Capture auf dem Ecken-Handle. Breite wird nur verändert, wenn ein rechter Nachbar in derselben Zeile existiert (Flex-Redistribution zwischen beiden, `BENTO_MIN_FLEX = 0.3`) — bei einer alleinstehenden/letzten Kachel ist horizontales Ziehen ein No-Op, vertikal funktioniert der Handle immer. Höhe wird frei gesetzt (`BENTO_MIN_HEIGHT = 140`px, kein Maximum), angewendet über `style.height` + `overflow-y:auto` **auf der Kachel selbst** (`align-self:flex-start`, nicht `align-items` auf der ganzen Zeile — sonst würde das bestehende Stretch-Verhalten unresized Geschwister-Kacheln bei allen `new-design`-Nutzern optisch verändern). Während des Ziehens werden nur die drei Inline-Styles direkt gesetzt (kein voller Reflow pro `pointermove`-Tick), erst bei `pointerup` volle `applyBentoState` + Persistenz.
- **Ende**: schwebender Button `#bento-edit-done-btn` (`position:fixed`, wie `#focus-toggle-btn`) → `exitBentoEditMode()` — entfernt `body.bento-edit-mode`, räumt einen ggf. mitten im Drag/Resize hängenden `window`-Listener ab, entfernt die Gap-Streifen. Grid-Linien/Griffe/Handles/Entfernen-Buttons verschwinden dadurch automatisch (CSS-gesteuert), ebenso das „Entfernte Kacheln"-Panel. Verkleinert sich das Fenster während des Editierens unter 1024px, verschwindet die komplette Edit-Chrome rein CSS-getrieben zusammen mit dem Grid-Layout selbst und kommt beim Vergrößern ohne erneuten Klick zurück.
- **Persistenz**: `persistBentoState(state)` schreibt immer nach `localStorage` (`pomo_bento_layout_v1`, hält jetzt `{ rows, removed }` statt bloß `rows`) und zusätzlich, falls eingeloggt, per `saveEggProfile({ bento_layout: state })` (bestehender generischer `profiles`-PATCH-Helper, trotz Egg-lastigem Namen bereits feldunabhängig) in dieselbe Spalte `profiles.bento_layout` (JSONB, nullable, Migration `20260719000000_bento_layout.sql`, unverändert — keine neue Migration nötig, da die Spalte serverseitig nie geschemat validiert wird). Beim Login (`onLoginSuccess()`, nach `renderChallengesCard()`) prüft `reconcileBentoState(profile)`: ist `profile.bento_layout` vorhanden und gültig und weicht es vom lokalen Stand ab (`bentoStateEqual`, vergleicht `rows` UND `removed`), **gewinnt der Server** — lokal wird überschrieben und neu gerendert (`applyBentoState`). Ist der Server-Wert `null` (nie gespeichert) oder ungültig, bleibt der lokale Stand unangetastet — kein Auto-Push beim bloßen Login. Stimmen Server und lokal bereits überein, passiert kein sichtbarer Reflow.

#### Kachel entfernen/wiederherstellen

Im Editor kann jede Kachel außer `eggdeck` (Ei-Box/Brutkasten) und `leaderboard` (Rangliste) komplett aus der Seite entfernt werden (`BENTO_NON_REMOVABLE = ['eggdeck', 'leaderboard']`, direkt unter `BENTO_TILE_META`) — der Fokustimer ist ohnehin nie Teil des Bento-Systems.

- **Reparenting statt Löschen**: `#bento-removed-pool` ist ein permanenter, unsichtbarer Halte-Container (`display:none`, statisch im HTML, außerhalb jeder `.bento-row`). `applyBentoState(state)` parkt jede Kachel, deren ID nicht in `state.rows` vorkommt, per `appendChild` dorthin, **bevor** `applyCustomBentoLayout(rows)` alle alten `.bento-row`-Wrapper abreißt — ohne dieses Parken würde eine entfernte Kachel dabei nicht nur unsichtbar, sondern komplett aus dem DOM gelöscht (Inhalt-/Listener-Verlust).
- **Überall verborgen**: `display:none` auf `#bento-removed-pool` wirkt unabhängig von `body.new-design`/`body.bento-edit-mode` — eine entfernte Kachel bleibt dadurch auch im klassischen mobilen Stack-Layout (Neues Design aus) und geräteübergreifend nach Server-Sync verborgen, nicht nur innerhalb des Bento-Grids. Der App-Start-Aufruf (`applyBentoState(loadBentoState())`, direkt nach `initNewDesignSetting()`) läuft dafür bewusst unabhängig von `newDesignOn`.
- **Editor-UI**: Klick auf `.bento-edit-remove-btn` einer Kachel → `removeBentoTile(tileId)` — entfernt die ID aus der Editor-Arbeitskopie `bentoEditRows` (via `spliceOutOfBentoRows`), fügt sie `bentoEditRemoved` hinzu, wendet sofort an + persistiert (kein Speichern-Button, gleiches Muster wie Drag/Resize). Schwebendes Panel `#bento-removed-panel`/`#bento-removed-list` (`position:fixed`, unten links, analog `#bento-edit-done-btn` unten rechts) zeigt die entfernten Kacheln als Liste im `.bell-request-row`/`.bell-req-accept`-Stil (wiederverwendet vom Bell-Dropdown, kein neues CSS für die Zeilen) mit „Zurückholen"-Button pro Eintrag (`restoreBentoTile(tileId)` — fügt die Kachel als eigene neue Zeile am Ende von `bentoEditRows` wieder ein). Panel ist **nur im Editor sichtbar** (`body.bento-edit-mode`) und kollabiert zusätzlich auf `display:none`, solange nichts entfernt ist (CSS-Klasse `.has-items`, per `renderBentoRemovedList()` getoggelt).
- **Working-Copy**: `bentoEditRemoved` (Arbeitskopie von `loadBentoState().removed`) ist die Schwester-Variable zum bestehenden `bentoEditRows`, beide geklont in `enterBentoEditMode()`, beide nur während `bento-edit-mode` gültig.

### Fokus-Modus (Header-Button, unabhängig vom Bento-Grid-Toggle)

Neuer Header-Button `#focus-toggle-btn` (`.icon-btn`, gleiche Klasse wie `#gear-btn`, zwischen `#bell-wrap` und `#gear-btn`) blendet alle Karten außer der Timer-Card aus — für ablenkungsfreies Lernen. **Nicht** an den Bento-Grid-Toggle gekoppelt, immer verfügbar, unabhängig davon ob „Neues Design" aktiv ist.

- **State/Persistenz**: `focusModeOn`, `localStorage` Key `pomo_focus_mode_v1`, geräte-lokal. `setFocusMode(on)` / `applyFocusModeUI()` / `initFocusMode()`.
- **Aktivierung**: manuell per Klick jederzeit, **plus** automatisch bei jedem Eintritt in `mode==='work'`, aber **nur** wenn sowohl `limitlessSetting` als auch `autoBreaksSetting` aktiv sind (Limitless-Modus mit „Automatische Pausen") — dort läuft der Fokus über Checkpoints/Pausen-Zyklen hinweg ohnehin unbeaufsichtigt weiter, daher sinnvoll automatisch fokussiert. Für normale Countdown-Sessions und reinen Limitless-Modus ohne Auto-Pausen bleibt die Aktivierung rein manuell (kein Verhaltenssprung beim bloßen Öffnen des Timers). Zwei Hook-Punkte: (1) `switchTo(m, autoStart)` als erste Zeile (`if (m==='work' && limitlessSetting && autoBreaksSetting) setFocusMode(true);`, deckt Mode-Button-Klick, Auto-Resume aus `workStash`, `skip()`, `onTimerEnd()`-Rücksprung ab), (2) `restoreTimerState()` — intern in `restoreTimerStateInner()` umbenannt, der äußere `restoreTimerState()`-Wrapper prüft in einem `finally`-Block nach dem `await` dieselbe Bedingung (deckt die 4 Stellen ab, an denen die Funktion `mode` direkt setzt, ohne über `switchTo()` zu laufen — Seiten-Reload/Login auf zweitem Gerät während laufender Session).
- **Ausschalten passiert ausschließlich über den Button-Klick** — kein Code-Pfad ruft `setFocusMode(false)` sonst auf; auch während einer Pause bleibt ein manuell aktivierter Fokus-Modus an.
- **CSS**: `body.focus-mode` blendet `#heatmap-card`, `#attention-card`, `#stats-card`, `#challenges-card`, `#egg-section-wrapper`, `#leaderboard-card`, `#race-track-card` per `!important` aus (überstimmt bestehende Ad-hoc-`style.display`-Zuweisungen an anderer Stelle im Code) und nullt `margin-bottom` der `.bento-row`-Wrapper. Gezielt die 7 Karten-IDs, nicht die Wrapper selbst — sonst würden auch darin verschachtelte Overlays (`#hatchOverlay` etc.) unterdrückt, falls während einer fokussierten Session ein Level-Up/Ei-Schlüpfen auftritt.

#### Fullscreen-Timer + Ring-Visualisierung

Im Fokus-Modus wird `#timer-card` zu einem echten Vollbild-Overlay (`position:fixed; inset:0`, `background:var(--bg)`, CSS-Grid mit `grid-template-areas`) — inkl. Header (Titel + alle Buttons außer `#focus-toggle-btn`, der per `position:fixed` oben rechts herausgelöst wird und der einzige Ausweg aus dem Vollbild bleibt). Funktioniert auf jeder Bildschirmgröße (`clamp()`/`vmin`-basierte Größen, kein separater Breakpoint), unabhängig vom Bento-Grid-Toggle — bei gleichzeitig aktivem `body.new-design` gewinnt die Fullscreen-Regel, weil sie im Stylesheet **nach** dem Bento-`@media`-Block steht (gleiche Spezifität, spätere Deklaration gewinnt).

- **Neuer Ring statt Analoguhr**: `#focus-ring-wrap`/`#focus-ring-svg`/`#focus-ring-arc` — ein 4. mutually-exclusive Visualisierungs-Element (analog zum bestehenden `watch-wrap`/`limitless-ring-wrap`-Muster), nur im Fokus-Modus sichtbar. Dicker Ring (Radius 72 vs. 68 bei der kleinen Uhr), bewusst **ohne** Ticks/Zeiger — die normale Analoguhr bleibt für alle Nicht-Fokus-Fälle unverändert. `renderTimer()` schaltet jetzt 3-fach um (`watch-wrap` / `limitless-ring-wrap` / `focus-ring-wrap`), gesteuert über `document.body.classList.contains('focus-mode')`.
- **Geteilte Fortschritts-Berechnung**: `currentProgressFrac()` (aus `updateWatch()` extrahiert) liefert den Bruch (0..1) für beide Timer-Untermodi (Countdown: `remaining/totalSec`; Limitless: Bruch zum nächsten Checkpoint/zur nächsten Pause, Zykluslänge `autoBreaksSetting ? focusIntervalMin : LIMITLESS_CHECKPOINT_SEC/60` — analog zu `checkLimitlessCheckpoint()`) und wird von `updateWatch()` UND `updateFocusRing()`/`updateDualRingArcs()` genutzt — nur die Bruch-*Berechnung* ist geteilt, die Zeiger-Winkel-Formeln der kleinen Uhr bleiben unverändert (bewusst nicht vereinheitlicht, da Countdown- und Limitless-Zweig unterschiedliche Winkel-Richtungssemantik haben). `CIRC_RING = 2*Math.PI*72` neben der bestehenden `CIRC`-Konstante, `CIRC_RING_INNER = 2*Math.PI*56` für den inneren Ring.
- **Doppel-Ring vereinheitlicht (v2)**: `#focus-ring-arc` bekommt bei Limitless-Sessions zusätzlich einen inneren Ring (`#focus-ring-inner-group`/`#focus-ring-inner-arc`, standardmäßig `display:none`) — exakt dieselbe Zwei-Ring-Darstellung wie `#limitless-ring-wrap` außerhalb des Fokus-Modus (Tagesziel außen, Pausen-Fortschritt innen, siehe „Limitless (Stoppuhr-)Fokus-Modus" oben). `updateFocusRing(showElapsed)` togglet die Gruppe und die `.dual-outer`-Klasse auf `#focus-ring-arc` (überschreibt Farbe/Opacity nur im Limitless-Fall) und ruft dann `updateDualRingArcs()` — dieselbe Funktion, die auch `updateLimitlessRing()` für die normale Timer-Karte nutzt, nur mit den Fokus-Modus-Element-IDs. Für normale Countdown-Sessions im Fokus-Modus bleibt `#focus-ring-arc` unverändert ein einzelner Ring (`var(--accent)`, `opacity:0.55`, kein innerer Ring).
- **Bugfix**: `setFocusMode(on)` ruft jetzt zusätzlich `renderTimer()` auf — ohne das blieb beim Umschalten während einer **pausierten** Session die alte Sichtbarkeits-Zuweisung (Inline-`style.display`) stehen, da die 3-Wege-Umschaltung in `renderTimer()` JS-gesteuert ist, nicht rein CSS-getrieben.

---

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

Minimales, rein additives App-Owner-Konzept — kein allgemeines Rollensystem, betrifft ausschließlich den App-Betreiber selbst. Zweck: einen vergessenen/endlos laufenden Timer eines anderen Nutzers (typischerweise eine Limitless-Session, die niemand mehr beobachtet) manuell stoppen können, ohne auf die automatischen Cron-Mechanismen (4-Uhr-Reset, 3h10min-Idle) warten zu müssen. Migration `20260819000000_admin_force_stop_timer.sql`.

- **`profiles.is_admin`** (boolean, Default `false`) — einziges Gating-Attribut, unabhängig von `clan_role`. Kein Code-Pfad setzt das Flag automatisch; wird einmalig manuell (SQL-Editor oder eigene, ungepushte Mini-Migration) auf dem Owner-Account gesetzt, bewusst **nicht** Teil der additiven Haupt-Migration (vermeidet einen hartkodierten Nutzernamen/UUID im Git-Verlauf).
- **`credit_elapsed_timer_state(p_row, p_cutoff, p_reason)`**: aus `reset_stale_work_sessions()` extrahierter gemeinsamer Kern (identische 4-Zweig-Logik: limitless laufend/pausiert, Countdown laufend/pausiert) — nimmt eine bereits per Claim-Mutex (`DELETE ... RETURNING`) entfernte `timer_state`-Zeile entgegen und kreditiert sie (limitless → `pending_focus_sessions`, sonst direkt `study_days`/`pomodoro_sessions`). `reset_stale_work_sessions()` selbst ruft diesen Helper jetzt nur noch auf, Verhalten unverändert zur Vorversion.
- **`admin_list_running_timers()`**: `SECURITY DEFINER`, liest alle offenen `timer_state`-Zeilen (`mode ∈ {'work','short'}`) inkl. `username`, gated über `EXISTS (... is_admin=true)` direkt in der `WHERE`-Klausel — bei Nicht-Admin stilles leeres Resultset statt Fehler (rein lesend, nicht sicherheitskritisch).
- **`admin_force_stop_timer(p_user_id)`**: `SECURITY DEFINER`, `RAISE EXCEPTION 'Not authorized'` bei fehlendem `is_admin` (Muster wie `remove_clan_member()`), Claim-Mutex-`DELETE` auf die Ziel-Zeile, kreditiert bei `mode='work'` über `credit_elapsed_timer_state(..., now(), 'admin_stop')` — ein `'short'`(Pause)-Fund wird nur gelöscht, keine Gutschrift nötig.
- **Kreditierungsziel bewusst identisch zu `idle_3h`/`day_boundary`**: ein admin-gestoppter Limitless-Timer landet in `pending_focus_sessions` (dritter `reason`-Wert `admin_stop`, `formatPendingFocusReason()` client-seitig um diesen Zweig ergänzt) — der betroffene Nutzer bestätigt („Gutschreiben") oder verwirft („Löschen") die Minuten selbst über die bereits bestehende Pending-Liste-UI. Kein stiller Fremd-Credit durch den Admin, keine neue UI auf Empfängerseite nötig.
- **Client**: `isAdmin` (aus `profile.is_admin`, `select=*` liefert die Spalte automatisch mit), `updateAdminUI()` togglet `#admin-section` im Settings-Panel (Muster `updateLeaderUI()`/`#clan-leader-section`). `loadRunningTimers()`/`renderRunningTimersList()`/`adminForceStopTimer()` sind 1:1 nach dem Clan-Mitgliederlisten-Muster (`loadClanMembers()`/`renderClanMemberList()`/`removeClanMember()`) gebaut — Bestätigung vor dem Stoppen über das bestehende `showTimerConfirmBanner()`. Liste lädt bei jedem Aufklappen neu (anders als die selten wechselnde Clan-Mitgliederliste), da Timer-Zustände hochfrequent sind.
- **RLS-Hinweis**: `timer_state` erlaubt sonst ausschließlich `auth.uid() = user_id` (keine Ausnahme für Admins) — beide neuen RPCs sind `SECURITY DEFINER` und umgehen RLS bewusst serverseitig, exakt wie `remove_clan_member()`/`reset_stale_work_sessions()`. `REVOKE ... FROM anon` ist wie an anderer Stelle im Projekt dokumentiert wirkungslos (PUBLIC-Default-Grant), aber funktional unkritisch, da `auth.uid()` für anon `NULL` ist und der `is_admin`-Check dadurch immer fehlschlägt.

### Lernzeit-Korrektur (Migration `20260819000010_admin_set_study_minutes.sql`)

Zweites Werkzeug im selben Admin-Panel: die Gesamt-Lernzeit eines Nutzers für einen Tag (Client nutzt immer `todayKey()`) direkt auf einen von Hand eingegebenen Minutenwert **setzen** statt addieren — für den Fall, dass jemand vergessen hat, seinen Timer zu pausieren, und dadurch zu viel Zeit für heute eingetragen bekommen hat.

- **Bewusst anders als der Timer-Stop oben**: das ist eine direkte Korrektur eines bereits falschen Werts, kein neuer Credit — läuft deshalb **nicht** über `pending_focus_sessions` (der Nutzer hätte keinen Grund, eine Abwärtskorrektur seiner eigenen Zeit selbst zu bestätigen). Stattdessen sofortiges Upsert auf `study_days.minutes`, analog zu `add_study_minutes()`, nur mit `p_user_id`-Parameter und SET- statt ADD-Semantik (`ON CONFLICT (user_id, date) DO UPDATE SET minutes = p_minutes`, nicht `minutes = study_days.minutes + ...`).
- **`admin_lookup_user_day(p_username, p_date)`**: `SECURITY DEFINER`, liefert `user_id` + aktuelle Tagesminuten (0 falls keine Zeile) für die Vorschau im Bestätigungsdialog — admin-gated statt privacy-gated, funktioniert also auch für Nutzer mit `public=false` (eine reine `profiles?username=eq.X`-REST-Suche würde dort laut RLS nichts liefern).
- **`admin_set_study_minutes(p_user_id, p_date, p_minutes)`**: `SECURITY DEFINER`, `RAISE EXCEPTION 'Not authorized'` bei fehlendem `is_admin`, `RAISE EXCEPTION 'Invalid minutes'` außerhalb `[0, 1440]` (leichte Sanity-Grenze gegen Vertipper — `study_days.minutes` selbst hat keinen CHECK-Constraint).
- **Client**: neues Formular in `#admin-section` (Benutzername + Minuten-Input + „Setzen") unterhalb der Timer-Liste. `adminFixTodayMinutes()` lädt erst per `admin_lookup_user_day()` den aktuellen Wert, zeigt ihn im bestehenden `showTimerConfirmBanner()` („von A auf B Minuten setzen?") und ruft erst nach Bestätigung `admin_set_study_minutes()` auf.
- **Bekannte, akzeptierte Einschränkung**: `pomodoro_sessions` (Label-Aufschlüsselung, CSV-Export) wird dabei **nicht** mitkorrigiert — für den betroffenen Tag können Label-Stats/Export danach von der (jetzt korrigierten) Tagessumme in `study_days` abweichen, welche einzelne Session-Zeile „falsch" war ist nicht eindeutig bestimmbar. Bereits vergebene Level-Ups/Eier/Diamanten/Streak-Meilensteine werden durch eine Abwärtskorrektur ebenfalls nicht rückwirkend zurückgenommen (kein Code-Pfad im Projekt tut das irgendwo). Audit-Trail kostenlos vorhanden: der bestehende `study_days_audit`-Trigger protokolliert jede Änderung inkl. Admin-Korrektur nach `study_days_log`.

---

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

## Karten-Katalog (38 Karten)

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

Raritäten & Ziehwahrscheinlichkeiten: common 40 %, rare 30 %, epic 18 %, legendary 9 %, mystic 3 %.

---

## Eier-System

### Farben & Bilder
4 Ei-Farben: `y` (gelb), `b` (blau), `g` (grün), `r` (rot). Bilder: `CDN/Eier/<farbe>/Stadium_<1-4>.png`. Dazu ein 5. Token `m` (Mystisches Ei, siehe „Mystisches Ei" unten), Bilder unter `CDN/Eier/mystic/Stadium_<1-4>.png`.

### Brut-Stadien (Ziel = 600 Fokusminuten)
| Fortschritt | Stadium | Bild |
|---|---|---|
| 0–209 min | 0 | Stadium_1 |
| 210–419 min | 1 | Stadium_2 |
| 420–599 min | 2 | Stadium_3 |
| 600+ min | Schlüpfbereit | pulsierender Glow |

Schwellen = `600 × [0.35, 0.70, 1.0]`.

### Schlüpf-Animation
- Ei wackelt (shake-Keyframe, 480 ms)
- 8–12 Schalensplitter fliegen mit zufälligem Winkel/Rotation heraus
- Zwei gezackte Hälften (clip-path Zickzack) fliegen nach links/rechts oben
- Nach 540 ms: `draw_card()` RPC → Karten-Overlay

### Diamanten-Kosten
| Aktion | Kosten |
|---|---|
| Neues Ei kaufen | 12 💎 |
| Mystisches Ei kaufen | 100 💎 |
| Brutzeit −1h | 1 💎 |
| Brutzeit überspringen | ⌈verbleibende Stunden⌉ 💎 |
| Zweiter Brutkasten (einmalig, ab Level 15) | 30 💎 |

Fehler-Banner bei zu wenig Diamanten: „Du bist wohl gesetzlich versichert. Verdiene mehr Diamanten und probiere es nochmal!"

### Mystisches Ei

Zweite, teurere Ei-Variante (100 💎 statt 12 💎) mit garantiert hochwertiger Ziehquote. Datenmodell: **kein separates Feld** — läuft als 5. Token-Wert `'m'` durch dasselbe Single-Char-Farbsystem wie `y/b/g/r` (`eggInventory`-Einträge, `profiles.eggs`-String, `incubator.egg_color`), dadurch keine Änderung an `eggsFromProfileString`/`eggsToProfileString`/`bindIncubatorDragDrop` nötig — nur `EGG_COLORS['m']`/`EGG_STAGES['m']` (Konstanten, index.html) und die `incubator_egg_color_check`-Constraint (`CHECK (egg_color IN ('y','b','g','r','m'))`) mussten erweitert werden.

- **Kauf**: `buyMysticEgg()` (analog `buyEgg()`, aber `color:'m'` statt zufällig aus `EGG_COLOR_IDS`). Beide werden seit dem Ei-Shop (siehe unten) nicht mehr aus dem Inventar heraus, sondern aus einer eigenen Shop-Kachel aufgerufen. `EGG_COLOR_IDS` bleibt bewusst bei 4 Einträgen — `awardEgg()` (Level-Up-Belohnung) darf niemals ein bezahltes Mystic-Ei ausschütten, Mystic-Eier sind ausschließlich käuflich.
- **Ziehquote**: `draw_card(p_mystic boolean DEFAULT false)` RPC — bei `p_mystic=true` nur `legendary` (30 %) / `mystic` (70 %), keine common/rare/epic (Migration `20260805000000_mystic_egg.sql`). Die alte 0-Parameter-Signatur wurde dabei per `DROP FUNCTION` entfernt statt überladen — zwei gleichzeitig existierende `draw_card`-Signaturen hätten PostgREST bei einem Aufruf mit leerem Body `{}` nicht mehr eindeutig auflösen lassen (`PGRST203`). Der bestehende Client-Call mit `{}` funktioniert dank Default-Parameter unverändert weiter.
- **Client**: `splitEgg()` leitet `isMystic` aus `incData(n).color === 'm'` ab, sendet `{ p_mystic: isMystic }` an `draw_card`. Der clientseitige Offline-Fallback (`rollEggRarity()`) hat ein Pendant `rollEggRarityMystic()` (30/70 nur legendary/mystic) — **beide** Fallback-Zweige in `splitEgg()` (unbekannte `cardId` UND Netzwerkfehler) müssen bei einem Mystic-Ei diese Variante nutzen, sonst könnte ein Fetch-Fehler trotzdem eine common-Karte liefern.
- `sell_card()` unverändert — behandelt Rarität bereits generisch, unabhängig von der Ei-Herkunft.

### Ei-Shop

Eigene Kachel `#eggShopBox` zwischen Brutkasten und „Meine Karten" (`renderEggShop()`, statischer Inhalt — Bild/Preis ändern sich nie zur Laufzeit, daher einmaliger Top-Level-Aufruf statt Re-Render bei jedem Login). Zeigt genau zwei Angebote (normales Ei 12💎 mit gelbem Stadium-1-Vorschaubild, mystisches Ei 100💎 mit `Eier/mystic/Stadium_1.png`, beide via `eggSprite()`), ganze Kachel ist jeweils der Kauf-Button — ruft unverändert `buyEgg()`/`buyMysticEgg()` auf.

- **Inventar-Slots haben seitdem keine Kauffunktion mehr** — `renderInventory()`s leerer-Slot-Zweig ist jetzt nur noch `slot.className = 'inv-slot';` (kein Klick-Handler, kein Preis-Icon). Die alten `.plus-slot`/`.plus-slot-dual`/`.plus-btn-*`-CSS-Klassen wurden entfernt.
- **„Kein Platz im Inventar"**: `showInventoryFullError()` (neben `showEggDiamondError()`, gleiches `#diamondBanner`-Element + `eggBannerTimer`-Debounce-Mechanismus, eigener Text) — `buyEgg()`/`buyMysticEgg()` prüfen `freeIdx === -1` weiterhin **vor** dem Diamanten-Check, rufen bei vollem Inventar diese Funktion statt eines stillen No-Ops auf.
- **Inventar-Größe 10 → 5** (`EGG_INVENTORY_SIZE`-Konstante, ersetzt alle vorher hartkodierten `10`er an den 5 betroffenen Stellen: State-Init ×2, `renderInventory()`-Schleife, `eggsFromProfileString()`-Padding/Truncate). CSS `.inv-slot` entsprechend von `width: calc(10% - 8px)` auf `calc(20% - 8px)` angepasst (5 statt 10 Spalten pro Zeile). `awardEgg()` und der Drag&Drop-Pfad (`bindIncubatorDragDrop`) brauchten keine Anpassung — beide arbeiten bereits generisch über `findIndex`/Ei-`id`, nicht über eine feste Array-Länge. Vor der Umstellung per SQL verifiziert, dass kein Bestandsnutzer einen Slot-Index ≥ 4 belegt hatte — kein Datenverlust durch die Reduktion.

### Zweiter Brutkasten

- Ab Level 15 (`hasReachedLevel15()`, index-basiert über `activeLevels[14].minMinutes` — robust gegen abweichend lange `clans.level_config`-Arrays) erscheint eine zweite Spalte (`#incubatorCol2`) neben dem bestehenden Brutkasten, per Kauf für 30 💎 dauerhaft freischaltbar (`buySecondIncubator()`, `profiles.second_incubator_purchased`). Bis Level 15 ist `#incubatorCol2` statisch `display:none` im Markup — keinerlei Layout-Unterschied für Nutzer unterhalb Level 15
- **Parametrisiert statt dupliziert**: `getEggProgress`, `renderIncubator`, `renderIncubatorButtons`, `startHatch`, `splitEgg` nehmen alle einen Slot-Parameter `n` (Default `1`, bestehende Aufrufe ohne Argument bleiben unverändert Slot 1). Der Zugriff auf den jeweiligen State läuft über `incData(n)` (`n===1 ? incubatorData : incubatorData2`). DOM-IDs sind für Slot 2 mit `2` suffixiert (`incubatorSlot2`, `btnMinus1h2`, `btnSkip2`, inkl. der dynamisch erzeugten `incEggWrap2` — wichtig, da zwei gleichzeitig schlüpfbereite Eier sonst um dieselbe ID kollidieren würden)
- **Bind-Funktionen statt Top-Level-Listener**: die −1h/Skip-Klick-Handler (`bindIncubatorButtons(n)`) und der Drag&Drop-Handler auf den Slot (`bindIncubatorDragDrop(n)`) werden je einmal für `n=1` und `n=2` aufgerufen. Alle Supabase-Schreibpfade auf `incubator` filtern zusätzlich auf `slot_index` (`&slot_index=eq.${n}` bei PATCH/DELETE, `slot_index: n` im Body + `?on_conflict=user_id,slot_index` beim Upsert) — sonst würden sich beide Slots gegenseitig überschreiben/löschen, da die PK jetzt `(user_id, slot_index)` ist
- **Gesperrter Zustand** (Level 15 erreicht, aber noch nicht gekauft): `.incubator-slot.locked` (opacity 0.42, kein Blur), großes 🔒 (34px) als eigene, nicht gedimmte Ebene zentriert über dem Slot (`.incubator-lock-layer`), keine −1h/Skip-Buttons (komplett ausgeblendet, nicht nur disabled), stattdessen eine schmale Pillen-Schaltfläche „+ 💎30" (`#btnUnlockIncubator2`). `updateSecondIncubatorVisibility()` steuert diesen Zustand (aufgerufen nach `loadEggData()` und an allen 4 Level-Up-Stellen, analog zu `if (incubatorData) renderIncubator();`)
- Nach dem Kauf verhält sich Slot 2 in jeder Hinsicht wie Slot 1 (Drag&Drop, −1h/Skip, Schlüpfen) — kein erneutes Level-Gating, `secondIncubatorUnlocked` ist permanent
- `eggHatchingSlot` merkt sich beim Schlüpfen, aus welchem Slot die gerade im Overlay gezeigte Karte stammt, damit der „In Deck legen"-Handler (`btnDeck`) die richtige `incubator`-Zeile löscht und den richtigen State (`incubatorData`/`incubatorData2`) leert

---

## Tauschbörse (Karten-Marktplatz)

Integriert in die bestehende Deck-Box (`#deckBox`, unterhalb des `#deckGrid`-Kartenrasters), keine eigene Karte. **Reiner Kartentausch, keine Diamanten** — Nutzer bieten Karten aus `user_cards` zum Tausch an (jede Karte, auch die letzte/einzige Kopie, keine Mindestbestand-Regel wie bei `sell_card()`), andere Spieler machen Gegenangebote aus einer oder mehreren eigenen Karten, der Angebotsersteller nimmt an oder lehnt ab. Ursprünglich ein Fixpreis-Marktplatz (Migration `20260718000000_card_marketplace.sql`), auf reinen Tausch umgestellt in `20260720000000_trade_marketplace.sql`.

### Angebot erstellen & zurückziehen
- **`create_listing(p_card_id)`**: wie zuvor — Server wählt serverseitig die älteste noch nicht aktiv gelistete Kopie, kein Preis-Parameter mehr.
- **Ein partieller Unique-Index** (`card_listings_one_active_per_card` auf `user_card_id WHERE status='active'`) garantiert weiterhin, dass eine physische Karten-Kopie nie zweimal gleichzeitig aktiv gelistet ist.
- **`cancel_listing(p_listing_id)`**: Claim-Mutex `active→cancelled` wie zuvor, lehnt zusätzlich alle noch offenen Gegenangebote auf dieses Listing ab (`trade_offers.status='pending'→'rejected'`) — ein zurückgezogenes Angebot lässt keine baumelnden Gegenangebote zurück.

### Gegenangebot machen & annehmen
- **`create_trade_offer(p_listing_id, p_offered_card_ids int[])`**: `p_offered_card_ids` referenziert Katalog-Karten (`cards.id`), nicht `user_cards.id` — wie bei `create_listing()` wählt der Server pro genannter `card_id` serverseitig die älteste verfügbare eigene Kopie (weder aktiv gelistet noch Teil irgendeines *aktuell pending* Gegenangebots — eine Kopie aus einem längst angenommenen/abgelehnten/zurückgezogenen Gegenangebot ist wieder frei verfügbar). Der Client (`eggDeck`) kennt ohnehin nur `card_id` + Stückzahl, nie einzelne `user_cards`-Zeilen-IDs. Mehrfachnennung derselben `card_id` ist erlaubt (mehrere eigene Kopien derselben Karte anbieten).
- **Limit: 1 pending Gegenangebot pro Listing** (`20260828000000_trade_offer_per_listing_limit.sql`, ersetzt ein früheres, global über alle Listings gezähltes 1-pro-App-Tag-Limit): ein Nutzer darf pro `card_listings`-Zeile höchstens ein offenes (`pending`) Gegenangebot haben — Fehler `offer_already_pending`. Auf beliebig viele verschiedene Listings gleichzeitig gibt es dagegen kein Limit. Zusätzlich zur `EXISTS`-Prüfung in der Funktion ein partieller Unique-Index (`trade_offers_one_pending_per_listing_offerer` auf `(listing_id, offerer_id) WHERE status='pending'`) als Race-Schutz, analog `card_listings_one_active_per_card`. Erst ein Zurückziehen (`cancel_trade_offer()`, s.u.) oder eine Antwort des Anbietenden (`respond_to_trade_offer()`) setzt das eigene Angebot von `pending` weg und erlaubt ein neues auf dasselbe Listing.
- **`cancel_trade_offer(p_offer_id)`**: Claim-Mutex-Update `pending→cancelled`, nur der Angebotssteller selbst (`offerer_id = auth.uid()`). `trade_offers.status`-CHECK ist dafür um den Wert `'cancelled'` erweitert. Client: `#tradeOfferActionWrap` in `showEggCardView()` lädt bei jedem Öffnen einer fremden Listing-Detailansicht asynchron (`renderTradeOfferAction()`, Muster wie `renderIncomingOffers()`) nach, ob bereits ein eigenes pending Gegenangebot existiert, und zeigt je nachdem „Gegenangebot machen" oder „Gegenangebot zurückziehen".
- **`respond_to_trade_offer(p_offer_id, p_accept)`**: nur der Angebotsersteller (`listing.seller_id`). Claim-Mutex auf `trade_offers` (`pending→accepted/rejected`) verhindert Doppel-Antworten. Bei Ablehnung: fertig, Listing bleibt aktiv für weitere Gegenangebote. Bei Annahme (eine Transaktion):
  1. Listing-Claim-Mutex `active→traded`.
  2. Gelistete Karte → Offerer, alle angebotenen Karten → Seller (`UPDATE user_cards SET user_id=...`); schlägt eine Übertragung fehl (Karte inzwischen anderweitig weggetauscht), rollt die **gesamte** Transaktion zurück (`source_card_missing`/`offered_card_missing`).
  3. Unveränderliches Audit-Log in `card_trades`: **eine Zeile pro bewegter Karte** (nicht mehr eine pro Trade wie beim alten Fixpreis-Modell), alle mit derselben `trade_offer_id` gruppiert.
  4. **Cleanup-Kaskade**: alle anderen Angebote/Gegenangebote, die mit den soeben bewegten physischen Karten zusammenhängen, werden verworfen — jede andere aktive `card_listings`-Zeile auf eine der bewegten Karten wird `cancelled`, jedes andere offene `trade_offers` auf dasselbe Listing ODER mit einer der bewegten Karten im eigenen `trade_offer_cards`-Set wird `rejected`.
- **`get_incoming_trade_offers()`** (SECURITY DEFINER): eigene offene eingehende Gegenangebote für die Kopf-Glocke, joint intern über `trade_offers`/`card_listings`/`profiles` — vermeidet fragile PostgREST-Embed-Filter-Syntax.
- **RLS-Rekursion vermieden**: `trade_offers`/`trade_offer_cards` referenzieren `card_listings` (und umgekehrt hätte `card_listings` theoretisch `trade_offers` referenzieren können) — direkte Cross-Table-Subqueries in beiden Policies gleichzeitig würden einen rekursiven RLS-Loop erzeugen (gleiches Risiko wie bei `profiles`/Clan, siehe „Clan-System"). Gelöst über SECURITY DEFINER-Helper (`owns_listing()`, `can_view_trade_offer()`), die intern RLS umgehen.

### Sichtbarkeitsregeln
- **Verschwommen nur in der großen Detailansicht, nie im kleinen Grid.** `showEggCardView({ id, src, rarity, count, market, readOnly })`: `market` ist `{ listingId, isMine }` (kein `mode`/`price`). `market.isMine === true` (egal ob über „Alle Angebote" oder „Meine Angebote" erreicht — dieselbe physische Karte) zeigt die Karte klar, mit „Angebot zurückziehen"-Button + eingehenden Gegenangeboten. `market.isMine === false` blurt das Kartenbild (`filter:blur(14px)` inline auf dem `<img>`) — **außer** der Nutzer besitzt diese Karte (per `id`/`card_id`) bereits selbst in `eggDeck` (`alreadyOwned = eggDeck.some(c => c.id === id)`), dann bleibt sie trotz fremdem Listing scharf, da der Kartenlook ohnehin schon bekannt ist. Der „Gegenangebot machen"-Button erscheint bei `market.isMine === false` **unabhängig davon, ob die Karte bereits besessen wird** — Gegenangebote auf bereits besessene Karten (z. B. um ein Duplikat zu sammeln) sind serverseitig immer schon uneingeschränkt möglich gewesen (`create_trade_offer()`/`respond_to_trade_offer()` prüfen nie den Vorbesitz, `user_cards` hat kein `UNIQUE(user_id, card_id)`), waren clientseitig aber bis zu einem Bugfix blockiert: Blur-Entscheidung (`isForeign`, weiterhin inkl. `!alreadyOwned`) und Button-Anzeige (`canOffer = !!market && !market.isMine`, **ohne** `alreadyOwned`) teilten sich vorher dieselbe Variable (`isForeign`) — dadurch verschwand bei bereits besessenen fremden Karten der Button komplett statt nur den Blur wegzulassen. Jetzt zwei getrennte Variablen. Die Grid-Vorschau in „Alle Angebote" (`renderMarketGrid()`) und die **eingehenden Gegenangebote** (`renderIncomingOffers()`, in der eigenen Listing-Detailansicht) sind dagegen **nie** verschwommen — Zensur passiert ausschließlich beim Öffnen der großen Ansicht.
- **Mitglieder-Deck nicht mehr anklickbar**: `renderMemberDeckGrid()` (über den Leaderboard-🃏-Button) rendert Karten nur noch mit `.deck-card-inert` (kein Klick-Handler, `cursor:default`) — fremde Decks sind nur noch anschaubar. Das früher genutzte `readOnly`-Flag von `showEggCardView()` wird dadurch faktisch nicht mehr erreicht, bleibt aber als Sicherheitsnetz im Code.
- **Gegenangebot-Karten-Picker** (`#tradeOfferOverlay`, `showTradeOfferPicker(listingId)`): zeigt das **eigene** `eggDeck` in voller Klarheit (eigene Karten), Klick auf eine Kachel togglet `.selected` (Mehrfachauswahl, `tradeOfferSelected`-Set), sendet beim Bestätigen die gewählten `card_id`s an `create_trade_offer()`.

### Glocke (Kopf-Header) jetzt für alle Nutzer
- `#bell-wrap` ist nicht mehr Leader-exklusiv — sichtbar für jeden eingeloggten Nutzer (`updateLeaderUI()`: `!!currentUser` statt `clanRole==='leader'`). Die Beitrittsanfragen-Sektion (`#bell-clan-section`) bleibt weiterhin nur für Leader sichtbar/gefüllt.
- Neue Sektion `#bell-trade-section`/`#bell-trade-list`: `loadTradeNotifications()` (ruft `get_incoming_trade_offers()`) + `renderBellTradeItems()`, analog zum bestehenden `loadPendingRequests()`/`renderBellRequests()`-Muster.
- Klick auf „Ansehen" bei einem Trade-Eintrag (`openMyListingFromBell()`): öffnet die Deck-Box, wechselt zu „Meine Angebote", lädt die Listings neu und öffnet direkt die passende `showEggCardView`-Detailansicht mit den eingehenden Gegenangeboten.
- **Indikator**: `#bell-badge` ist ein kleiner grüner Punkt (kein Zahlen-Badge mehr) — `updateBellBadge()` summiert `bellClanCount + bellTradeCount` und togglet nur die Sichtbarkeit; die Anzahl steht als `title`-Attribut auf `#bell-btn` (Hover-Tooltip statt Ziffer im Icon).
- **Polling statt Realtime**: kein Websocket/Supabase-Realtime im Projekt, daher lädt `loadTradeNotifications()` (+ `loadPendingRequests()` bei Leadern) sowohl direkt nach dem Login (unmittelbar nach `updateLeaderUI()`) als auch per `setInterval` alle 45s bei sichtbarem Tab neu — gleiches Muster wie das bestehende 60s-Leaderboard-Polling (`index.html:~4704`). Macht ein anderer Spieler ein Gegenangebot, aktualisiert sich der grüne Punkt beim betroffenen Anbieter spätestens nach diesem Intervall von selbst, auch ohne die Glocke zu öffnen.

### Sonstiges
- **`profiles_read_active_sellers`**-RLS-Policy (über `has_active_listing()`, SECURITY DEFINER) unverändert nötig, damit Angebotsersteller-Namen im Browse-Feed sichtbar bleiben, unabhängig von `public`/Clan-Status.
- **Client**: `fetchMarketListings()`/`fetchMyListings()` laden weiterhin lazy beim ersten Aufklappen der Deck-Box (`toggleEggDeck()`, `marketLoaded`-Guard), Cache über `cacheGet`/`cacheSet` mit `CACHE_TTL_MARKET` (30s). Tab-Umschaltung „Alle Angebote"/„Meine Angebote" unverändert über `.market-tab`.
- **`profiles(username)`-Embed ist mehrdeutig**: `card_listings` hatte zwei FKs auf `profiles` (`seller_id` + `buyer_id`); `buyer_id` ist mit dem Preis-Modell entfallen, `fetchMarketListings()` nutzt weiterhin `profiles!card_listings_seller_id_fkey(username)` zur Disambiguierung (schadet nicht, auch wenn es jetzt nur noch einen FK gibt).
- **`sell_card()` zieht eigene Listings derselben Karte automatisch zurück** (`20260828000010_sell_card_cancels_listing.sql`): vor der Kopie-Auswahl werden alle eigenen aktiven `card_listings`-Zeilen dieser `card_id` auf `cancelled` gesetzt und alle darauf noch offenen `trade_offers` auf `rejected` (identisches Muster wie `cancel_listing()`) — ein Duplikat-Verkauf ("ich brauche das nicht mehr") ist inkompatibel mit einem weiterhin aktiven Tauschangebot für dieselbe Karte. Vorher wählte `sell_card()` lediglich eine nicht aktiv gelistete Kopie zum Löschen aus und ließ eine bestehende Listung unangetastet stehen — sichtbar als weiterhin aktives Angebot in der Tauschbörse und als weiterhin sichtbares eingehendes Gegenangebot in der Kopf-Glocke, bis die Listung manuell zurückgezogen wurde. Client (`sellCard()`) synchronisiert `myListings`/`marketListings`/`pomo_market_cache` sowie `loadTradeNotifications()` (Glocke) direkt nach Erfolg nach, statt auf den nächsten 45s-Poll zu warten.

---

## Rennstrecke (eigene Bento-Kachel `#race-track-card`)

Eigenständige Kachel (6. Bento-Tile, `racetrack` in `BENTO_TILE_META`, siehe „Bento-Grid-Layout", standardmäßig **über** der Ranglisten-Kachel — sowohl im statischen HTML als auch in `bentoDefaultRows()`): eine Rennstrecke mit 35 nummerierten Feldern (`Rennstrecke/strecke.png`, 1536×1024), auf der jeder Teilnehmer mit seinem **Profilbild** an der Position steht, die seiner heutigen Lernzeit entspricht. **Zeigt immer die heutigen Positionen live**, unabhängig davon welchen Zeitraum-Tab die Ranglisten-Kachel (`#leaderboard-card`, separat) gerade anzeigt — beide Kacheln sind zwar visuell getrennt, aber immer gemeinsam ein-/ausgeblendet (`setLeaderboardVisibility(visible)`, zentralisiert alle Stellen, die früher direkt `#leaderboard-card`s `style.display` gesetzt haben).

- **Bugfix (leere Strecke vor dem ersten Eintrag)**: `renderRaceTrack(list)` versteckte die ganze Kachel (`#lb-racetrack`, `display:none`), solange `list` leer war — `list` kommt aus `leaderboard_today()`, das per `INNER JOIN study_days ... WHERE minutes > 0` nur Nutzer mit bereits heute gesammelter Fokuszeit liefert. Vor dem allerersten Eintrag des Tages (egal ob eigener oder fremder) war die Strecke dadurch komplett unsichtbar statt leer. Jetzt rendert `renderRaceTrack()` das Streckenbild + Checkpoint-Diamanten immer, unabhängig von `list` — nur die Avatare hängen weiterhin von den (ggf. leeren) Einträgen ab, exakt wie „Zeigt immer die heutigen Positionen live" es beschreibt.
- **Bento-Edit-Modus-Bugfix**: `#race-track-card` fehlte anfangs in der `body.bento-edit-mode ... { position: relative; }`-CSS-Liste (`index.html`, `@media (min-width:1024px)`-Block) — dadurch landeten Verschiebe-Griff/Resize-Handle der Kachel relativ zum `.bento-row`-Elternelement statt zur Kachel selbst und wirkten visuell "verrutscht"/kaputt. Jetzt in der Liste ergänzt. Es gibt **keine** Tile-spezifische Sonderbehandlung im Editor-Code (`enterBentoEditMode()`, `ensureBentoEditChromeInjected()`, `startBentoTileDrag`/`-Resize` sind vollständig generisch über `BENTO_TILE_META`) — jede neue Kachel muss lediglich in dieser CSS-Liste UND in der Fokus-Modus-Ausblendungsliste (s.o.) mit aufgeführt werden. Einzige Ausnahme: `BENTO_NON_REMOVABLE` (siehe „Kachel entfernen/wiederherstellen") — eine neue Kachel ist per Default entfernbar und muss nur dort ergänzt werden, falls sie analog zu `eggdeck`/`leaderboard` nie entfernbar sein soll.
- **Avatare statt Auto-Icons**: ursprünglich zeigte die Strecke eines von 8 zufällig zugewiesenen Auto-Designs (`profiles.race_car_id`) — bei vielen Nutzern nicht mehr eindeutig unterscheidbar. Seit 2026-08-05 zeigt `renderRaceTrack()` stattdessen `entry.avatar_url` (`.lb-race-avatar`, rund, `object-fit:cover`, mit Rahmen) bzw. bei fehlendem Profilbild einen 👤-Platzhalter (`.lb-race-avatar-placeholder`), identisches Muster wie der Ranglisten-Avatar (`safeAvatarUrl(url)`-Helper, dedupliziert die `https://`-Whitelist-Prüfung für beide Stellen). Das Auto-Mini-Icon neben dem Namen in der Ranglisten-Zeile wurde ersatzlos entfernt (der reguläre Avatar steht dort ohnehin schon). **Die Auto-Zuweisungs-Logik bleibt bewusst bestehen** (`profiles.race_car_id`-Spalte, Migrationen `20260805000010_race_track.sql`/`20260805000020_race_track_backfill.sql`, `userRaceCarId`, `ensureRaceCarAssigned()` beim Login, `RACE_CAR_COUNT`, `raceCarIconUrl(carId)` als aktuell unreferenzierte Funktion mit Erklärkommentar) — für eine mögliche spätere Einführung individualisierbarer Autos, ohne die Datenbasis neu aufbauen zu müssen.
- **`leaderboard_today()` RPC** liefert `race_car_id` (aktuell nur noch für die o.g. spätere Verwendung, nicht mehr fürs Rendering) und `avatar_url` (Migration `20260805000010_race_track.sql`). Da sich die `RETURNS TABLE`-Spaltenliste ändert, war `DROP FUNCTION` vor dem `CREATE` nötig (Postgres erlaubt keine Rückgabetyp-Änderung per `CREATE OR REPLACE`) — gleiches Muster wie bei `draw_card()` im Mystic-Ei-Feature. `leaderboard_aggregated()`/`leaderboard_wins()` bleiben unverändert.
- **35 Streckenfelder**: `RACE_FIELDS` (index.html) — Array aus `[xPct, yPct]`-Prozent-Koordinaten relativ zur 1536×1024-Bildgröße, in Fahrreihenfolge (Feld 1 = goldenes Stoppuhr-Icon direkt an der Start/Ziel-Linie, Feld 2 = goldenes Pokal-Icon, Felder 3-35 = graue Ovale den Rundkurs entlang, Feld 14 = Flaggen-Icon am geometrisch gegenüberliegenden Punkt zum Start — alle 35 werden als gleichwertige normale Felder behandelt, keine Sonderlogik). Koordinaten wurden einmalig automatisiert vermessen (Hough-Circle-Detection auf dem Streckenbild + manuelle Sichtprüfung in 8 Ausschnitten, um Lücken auszuschließen) und sind fest im Code hinterlegt — kein Neu-Vermessen nötig, außer das Streckenbild wird ausgetauscht.
- **Positionierung**: rein prozentual (`raceFieldFor(minutes)` → `{x%, y%}`), keine `getBoundingClientRect()`-Pixelberechnung — Avatare (`position:absolute; left:X%; top:Y%` innerhalb von `#lb-racetrack`, `position:relative; width:100%`) skalieren dadurch automatisch mit jeder Bento-Kachelgröße mit, auch beim Live-Resize im Bento-Editor. Einfacheres Pendant zum SVG-`viewBox`-Muster bei `updateDualRingArcs()`. Avatar-Breite `.lb-race-avatar { width: 7.5% }` — bewusster Kompromiss, da der durchschnittliche Feld-Abstand nur ca. 5.9 % der Bildbreite beträgt und größere Icons auf benachbarten belegten Feldern zu überlappen beginnen.
- **Feld-Berechnung**: 1 Feld = 20 Minuten (`RACE_MIN_PER_FIELD`), abgerundet (`Math.floor(minutes/20)`) — 60 Min → Feld 3, 65 Min → ebenfalls Feld 3. 0-19 Minuten: Avatar steht an der Startlinie (`RACE_START_POS`), noch auf keinem Feld. **Ab ≥700 Minuten** (`RACE_FINISH_MINUTES` = 35×20) parkt der Avatar **nicht** auf Feld 35, sondern auf der tatsächlichen „START/ZIEL"-Banner-Grafik (`RACE_FINISH_POS`, separate Position) — der Fall „wirklich 12h gelernt", praktisch nie erreicht.
- **Mehrfachbelegung**: mehrere Avatare auf demselben Feld werden nach `(fieldType, fieldIndex)` gruppiert und um die Feldmitte gestaffelt versetzt (`OFFSET_X`/`OFFSET_Y` in `renderRaceTrack()`), damit sie nicht deckungsgleich übereinanderliegen.
- **Top-3-Rand (Gold/Silber/Bronze)**: die Top 3 der heutigen Rangliste bekommen einen farbigen Schimmer-Rand ums Renn-Icon (`.lb-race-rank-1/2/3`). `renderRaceTrack()` berechnet den Rang lokal aus `entries` (bereits sortiert von `leaderboard_today()`, `ORDER BY minutes DESC`) mit derselben Gleichstand-Logik wie `renderLeaderboard()`s Medaillen-Rangliste (Standard-Ranking — punktgleiche Einträge teilen sich den Rang, der nächste distinkte Eintrag springt auf seine tatsächliche Position, z.B. zwei Erste → beide Gold, kein Silber vergeben, nächster Eintrag ist Bronze). Unabhängig vom `.lb-race-car-me`-Glow (eigenes Icon kann beides gleichzeitig haben).
  - **Farben**: Gold `#c9a227` (identisch zum bestehenden „Tagessieger"-Rand im Leaderboard-Card, `isYesterdayWinner`), Silber `#c0c0c0`, Bronze `#8b5a2b` (bewusst dunkler als ein naives `#cd7f32`, wirkte zu hell/orange).
  - **Schimmer statt Volltonfarbe**: `conic-gradient(from 200deg, <Schatten>, <Basis> 25%, <Glanzlicht> 50%, <Basis> 75%, <Schatten> 100%)` pro Rang, als CSS-Custom-Property `--rank-gradient` hinterlegt (gleiches Wiederverwendungs-Idiom wie `--card-color`/`--card-bg`), simuliert den metallischen Glanz der 🥇🥈🥉-Emoji. Reine CSS-Lösung ohne zusätzliches Wrapper-Element: `border-color:transparent` + `background: var(--rank-gradient) border-box` — der transparente Rand lässt den Gradient-Hintergrund nur im Rand-Ring durchscheinen (funktioniert mit `border-radius:50%` und auch bei `<img>`, da der Gradient nur den Bereich außerhalb der Content-Box füllt, die vom Bild selbst überdeckt wird). Für `.lb-race-avatar-placeholder` (👤, eigene Füllfarbe `var(--surface2)`) zusätzlicher `padding-box`-Hintergrund-Layer, damit die Füllfarbe im Innenbereich erhalten bleibt.
- **Rendering/Update-Zyklus**: `loadRaceTrackData(forceRefresh)` ist ein von `lbPeriod` unabhängiger Lade-Pfad (eigener Fetch auf `leaderboard_today()`, nutzt aber denselben Cache-Key/TTL `pomo_lb_cache_today`/`CACHE_TTL_LB.today` wie der Heute-Tab der Ranglisten-Kachel, damit sich beide Wege nicht gegenseitig doppelt befeuern; lädt zusätzlich per `loadRaceCheckpointStatus()` den Checkpoint-Claim-Status, s.u.) — aufgerufen beim Login (`initLeaderboard()`), beim `↻`-Refresh-Klick und im bestehenden 60s-Poll-Intervall. `renderRaceTrack(list)` selbst kennt `lbPeriod` nicht mehr; `renderLeaderboard()` ruft sie zusätzlich direkt auf, aber nur wenn `lbPeriod === 'today'` (verhindert, dass Wochen-/Monats-/AllTime-Minuten fälschlich als heutige Rennpositionen interpretiert werden).

### Diamanten-Checkpoints (60 Min, 180 Min, Flaggen-Feld, Ziellinie)

Vier automatische Checkpoints pro Tag, alle nach demselben Muster: der erste Nutzer, der die jeweilige Schwelle erreicht, bekommt automatisch Diamanten — **ohne** manuellen Einlösen-Button (anders als alle sonstigen Diamanten-Claims im Spiel), inkl. `toast()`-Benachrichtigung. `checkpoint60` (Feld 3, 60 Min, 1💎) und `checkpoint180` (Feld 9, 180 Min, 1💎) sind reine Einzel-Marker-Checkpoints ohne eigene Streckengrafik (Migration `20260820000000_race_checkpoints_60_180.sql`, nachträglich ergänzt); `flag` (Feld 14, 280 Min, 1💎) und `finish` (echte Ziellinie, ≥700 Min, 5💎) sind die ursprünglichen zwei. Solange ein Checkpoint an diesem Tag noch nicht vergeben ist, liegt ein pulsierender 💎-Marker (`.lb-race-diamond`) auf dem jeweiligen Feld — bei `checkpoint60`/`checkpoint180`/`flag` je ein einzelner Marker (passend zur 1💎-Belohnung), auf der Ziellinie **fünf** Marker in einer kleinen Fächer-Anordnung um `RACE_FINISH_POS` (`RACE_FINISH_DIAMOND_OFFSETS`, passend zur 5💎-Belohnung) — rein visuell, die Belohnungshöhe selbst ist davon unabhängig.

- **Migration `20260805000030_race_checkpoint_diamonds.sql`**: neue Tabelle `race_checkpoint_claims` (`date, checkpoint ∈ {'flag','finish'} (seit 20260820000000 erweitert um 'checkpoint60','checkpoint180'), user_id nullable, reward_diamonds, UNIQUE(date, checkpoint)` als Claim-Mutex) + RPC `claim_race_checkpoint(p_checkpoint text)`, folgt exakt dem etablierten Claim-RPC-Muster (`claim_streak_milestone()`): serverseitige Neuprüfung der Schwelle aus `study_days` (nie dem Client vertrauend), `INSERT ... ON CONFLICT (date, checkpoint) DO NOTHING RETURNING id` als atomarer Mutex, `NULL` zurückgegeben wenn bereits vergeben (kein Fehler — passiert für alle außer dem ersten Nutzer täglich mehrfach), sonst `UPDATE profiles.diamonds` + neuer Kontostand als Rückgabe. **Anders als** die user-gebundenen `*_claims`-Tabellen sonst im Projekt: `race_checkpoint_claims` ist per RLS-Policy `USING (true)` öffentlich lesbar (steuert nur die 💎-Marker-Sichtbarkeit, keine privaten Daten).
- **Rollout-Backfill** (gleiche Migration, je Feature-Deploy): da beim Deploy meist schon mehrere Nutzer eine neue Schwelle heute passiert hatten, fügt die Migration bedingt (`WHERE EXISTS (... study_days ... minutes >= <Schwelle>)`) eine Platzhalter-Zeile (`user_id = NULL, reward_diamonds = 0`) für `(heute, <checkpoint>)` ein — markiert den Checkpoint als "heute bereits verbraucht", **ohne** rückwirkend jemandem Diamanten zu geben (bewusst akzeptiert, kein automatischer Nachtrag). Ab dem nächsten Tag (neue `date`-Zeile) läuft der Mechanismus regulär. Besonders wichtig bei `checkpoint60` (20260820000000), da 60 Min ein sehr häufig schon zum Deploy-Zeitpunkt erreichter Wert ist.
- **Client-Trigger**: `checkRaceCheckpoint(checkpoint)` (fire-and-forget wie `ensureRaceCarAssigned()`) wird **edge-getriggert** aus `creditFocusMinutes(key, minutes, label)` aufgerufen — `dayBefore`/`dayAfter` (Minuten für `key` vor/nach der Kreditierung) werden gegen `RACE_CP60_MINUTES`/`RACE_CP180_MINUTES`/`RACE_FLAG_MINUTES`/`RACE_FINISH_MINUTES` verglichen, exakt wie `crossedLevel15(lvlBefore, lvlAfter)`: feuert nur beim tatsächlichen Überschreiten im Moment der Kreditierung, nie rückwirkend. Zusätzlich auf `key === todayKey()` beschränkt — Day-Rollover-Krediten an den Vortag (`checkDayRollover()`, `key = pomoDay`) lösen keinen Checkpoint-Check aus, da die Rennstrecke ausschließlich den aktuellen Tag abbildet.
- **`sweepRaceCheckpoints()`-Sicherheitsnetz**: der reine Edge-Trigger oben verpasst reale Schwellen-Übertritte, die kein einzelner Tab live beobachtet — z. B. `loadStudyDays()` lädt bei Login/Reload bereits einen über der Schwelle liegenden Serverwert direkt in `days[key]` (kein `dayBefore` vorhanden), oder zwei Tabs/Geräte rechnen beide mit ihrem eigenen veralteten lokalen Stand und keiner sieht den addierten Serverwert über der Schwelle. `sweepRaceCheckpoints()` läuft deshalb zusätzlich bei jedem `loadRaceTrackData()`-Aufruf (Login, manueller Refresh, 60s-Poll, beide Zweige — Cache-Hit und Fresh-Fetch) direkt nach dem frischen `loadRaceCheckpointStatus()`: für jeden laut `raceCheckpointClaimed` noch offenen Checkpoint, dessen Schwelle `days[todayKey()]` bereits erreicht, wird `checkRaceCheckpoint()` erneut versucht — ohne `dayBefore`-Vergleich, rein „noch offen + Schwelle erreicht". Sicher, weil `claim_race_checkpoint()` bereits idempotent ist (Claim-Mutex `ON CONFLICT DO NOTHING`); ersetzt den Edge-Trigger nicht, sondern ergänzt ihn nur als Nachhol-Mechanismus.
- **`REVOKE EXECUTE ... FROM anon` ist in diesem Projekt wirkungslos** (verifiziert: `has_function_privilege('anon', ..., 'EXECUTE')` liefert `true` trotz REVOKE, gleiches gilt bereits für `claim_streak_milestone()`/`draw_card()` — vermutlich greift ein PUBLIC-Default-Grant, das REVOKE FROM anon nicht mit abräumt). Funktional unkritisch: `auth.uid()` ist für anonyme Requests `NULL`, `study_days`-Lookup liefert dann nie eine Zeile → `threshold_not_met` greift immer, kein exploitierbarer Pfad. Bekannte, projektweite Einschränkung, kein neu eingeführtes Risiko.

### Bibliotheks-Check-in (Wild Cards)

Die drei Gebäude auf dem Streckenbild (`Rennstrecke/strecke.png`) sind an reale Hallenser Bibliotheken angelehnt: **Steintor** (links, rotes Backsteingebäude), das rechte ockerfarbene Türmchengebäude (`key: 'neuwerk'`, siehe „Neuwerk → Auswärts / zu Hause" unten) und **Juri** (unten/Mitte, moderner Glas-/Betonbau). Spieler können auf ein Gebäude klicken, um sich dort einzuchecken — für alle Clan-Mitglieder sichtbar als kleine rechteckige „Wild Card" (Panini-Sticker-Stil, live aus `avatar_url`/`username` gerendert, **bewusst rechteckig statt rund** und etwas kleiner als die `.lb-race-avatar`-Renn-Icons, damit beides klar unterscheidbar bleibt), Migration `20260901000000_library_checkin.sql`.

- **Datenmodell**: `profiles.library_checkin` (`'steintor'|'neuwerk'|'juri'|NULL`, CHECK-Constraint) + `profiles.library_checkin_date` (das App-Datum des Check-ins). **Kein Reset-Cron** — `get_library_checkins()` filtert serverseitig ohnehin auf `library_checkin_date = heute (Berlin, 4-Uhr-Grenze)`, exakt das gleiche Prinzip wie bei `study_days`/`race_checkpoint_claims` (Werte werden nie aktiv gelöscht, nur nach Datum gefiltert) — ein Check-in von gestern verschwindet dadurch automatisch aus der Anzeige, ohne dass ein pg_cron-Job nötig ist. Client-seitig wird beim Login genauso gefiltert (`userLibraryCheckin` nur übernommen, wenn `profile.library_checkin_date === todayKey()`), damit die eigene Wild Card nicht kurz veraltet aufscheint, bevor der erste `loadLibraryCheckins()` durch ist.
- **`get_library_checkins()` RPC** (`SECURITY DEFINER`): gleiches Sichtbarkeits-Scoping wie `leaderboard_today()` (`public = true AND clan_id = my_clan_id()`), aber **ohne** Join auf `study_days` — ein Check-in ist unabhängig von heutiger Fokuszeit sichtbar. Schreib-Pfad ist bewusst reines `PATCH` über den bestehenden generischen `saveEggProfile()`-Helper (kein RPC nötig), exakt wie bei `race_car_id`/`bento_layout`.
- **Klick-Toggle statt Bestätigungsdialog**: `setLibraryCheckin(key)` — Klick auf das aktuell gewählte Gebäude hebt den Check-in auf, Klick auf ein anderes Gebäude verschiebt die eigene Wild Card dorthin. Nicht-destruktive, jederzeit revidierbare Aktion, daher ohne `showTimerConfirmBanner()`. Optimistisches lokales Update (`userLibraryCheckin`/`libraryCheckins`) + sofortiges Re-Render (`renderRaceTrack()`, siehe Bugfix-Punkt unten), danach fire-and-forget `saveEggProfile()`.
- **Event-Delegation**: ein einziger `click`-Listener wird in `initLeaderboard()` auf den persistenten `#lb-racetrack`-Knoten gebunden (nicht auf Kind-Elemente!), da `renderRaceTrack()` bei jedem Aufruf `wrap.innerHTML` komplett neu baut — `e.target.closest('[data-library]')` übersteht das, weil `wrap` selbst nie ersetzt wird.
- **Hover-Hotspots ohne echtes Pixel-Mask**: es gibt keine Cutout-/Alpha-Masken der drei Gebäude als separate Bild-Assets. Stattdessen zeichnet `renderRaceTrack()` eine `<svg viewBox="0 0 100 100" preserveAspectRatio="none">`-Ebene mit einem handgezeichneten `<polygon>` pro Gebäude (`LIBRARY_BUILDINGS[].points`, grobe Sechseck-Silhouette in Prozent-Koordinaten wie `RACE_FIELDS`) — `:hover` bzw. die eigene aktive Auswahl (`.lb-library-mine`) färbt den `stroke` weiß + `drop-shadow`-Glow, was optisch einer Gebäude-Umrandung entspricht, ohne ein echtes Bild-Masking zu sein.
- **Kalibrierungs-Tool `Rennstrecke/polygon-editor.html`**: eigenständige Dev-Datei (kein Teil der App, nicht von `index.html` verlinkt), lokal per Doppelklick/`file://` zu öffnen. Zeigt `strecke.png` mit den drei Gebäude-Polygonen + Ankerpunkten als direkt per Drag verschiebbare/klickbar erweiterbare SVG-Overlays, live-generiert daraus den fertigen `LIBRARY_BUILDINGS`-Quelltext zum Copy-Paste zurück in `index.html`. Einziger vorgesehener Weg, die Silhouetten nachzujustieren (z. B. bei einem neuen Streckenbild) — kein Neu-Schätzen der Koordinaten von Hand im Code mehr nötig.
- **Wild Cards zeigen nur das Foto**, kein Namens-Label (wurde bei langen Nutzernamen ohnehin abgeschnitten) — der Name bleibt als nativer `title`-Hover-Tooltip abrufbar.
- **Neuwerk → „Auswärts / zu Hause"**: die reale Neuwerk-Bibliothek ist im Sommer geschlossen, daher wurde nur die Anzeige umfunktioniert (`LIBRARY_BUILDINGS[1].name`, index.html) — das Gebäude im Bild bleibt unverändert (weiterhin das ockerfarbene Türmchengebäude), dient aber jetzt als generischer Check-in-Punkt für „ich lerne gerade nicht in Steintor oder Juri". `key: 'neuwerk'` bleibt bewusst unverändert (DB-Wert in `profiles.library_checkin`, CHECK-Constraint) — nur die Beschriftung ändert sich, keine Migration nötig. `Rennstrecke/polygon-editor.html`s `DEFAULTS`-Objekt hält denselben Namen synchron.
- **Bugfix (Renn-Avatare springen zur Startlinie nach Bibliotheks-Klick)**: `setLibraryCheckin()`/`checkRaceCheckpoint()` renderten nach einem lokalen Update mit `renderRaceTrack(lastLeaderboardData)` neu — `lastLeaderboardData` ist aber der Datensatz des zuletzt in der *separaten* Ranglisten-Kachel aktiven Zeitraum-Tabs (Default `'alltime'`), nicht die heutigen Renn-Einträge. Andere Datenform → `raceFieldFor(entry.minutes ?? 0)` fiel für praktisch jeden Eintrag auf die Startposition zurück. Jetzt gibt es einen dedizierten Cache `raceTodayList` (in `renderRaceTrack(list)` gepflegt, sobald ein echtes `list` übergeben wird); beide Stellen rufen `renderRaceTrack()` seither ohne Argument auf und nutzen damit automatisch die zuletzt bekannten, echten heutigen Positionen weiter.
- **`LIBRARY_BUILDINGS`/`LIBRARY_COLORS`** (index.html, neben `RACE_CAR_COUNT`): je Gebäude `key`, `name`, `anchorPct` (geometrischer Schwerpunkt des Polygons — dort zentriert sich die Wild Card, `transform:translate(-50%,-50%)`), `points` (Hover-Polygon) sowie eine feste Rahmenfarbe/Hintergrund (`--card-color`/`--card-bg`-Idiom wie `.deck-card`/`EGG_RARITIES`, macht auf einen Blick erkennbar, zu welchem Gebäude eine Karte gehört). `anchorPct` wurde rechnerisch aus den `points` per Flächenschwerpunkt-Formel (Shoelace-Centroid, nicht der simple Eckpunkt-Durchschnitt) bestimmt — ursprünglich war `anchorPct` ein von Hand gesetzter Fußpunkt mit `translate(-50%,-100%)` ("Karte steht auf dem Gebäude"), was mit dem jetzigen Schwerpunkt-Wert die Karte über der Gebäudemitte hätte schweben lassen statt sie zu zentrieren — der Transform wurde deshalb mitgeändert.
- **Mehrfachbelegung**: mehrere Wild Cards am selben Gebäude werden analog zum `OFFSET_X`/`OFFSET_Y`-Gruppierungsmuster der Renn-Avatare horizontal um den Ankerpunkt gefächert (`LIB_OFFSET_X`).
- **Load/Poll**: `loadLibraryCheckins()` folgt dem Token-Check-Muster von `loadTradeNotifications()`, eingehängt in **beide** Zweige von `loadRaceTrackData()` (Cache-Hit + Frisch-Fetch) — kein eigener Intervall, läuft im bestehenden 60s-Rhythmus/Gating der Rennstrecke mit.

---

## Aufmerksamkeits-Tracking (eigene Bento-Kachel `#attention-card`)

Eigenständige Kachel (7. Bento-Tile, `attention` in `BENTO_TILE_META`, zwischen Heatmap- und Stats-Kachel — sowohl im statischen HTML als auch in `bentoDefaultRows()`), nur sichtbar für eingeloggte Nutzer (kein Clan-/Public-Gating, analog `#challenges-card`). Ein Button „Tired" loggt per Klick den aktuellen Zeitpunkt; darunter zeigt ein Balkendiagramm, wie sich Fokuszeit über den Tagesverlauf verteilt.

- **Tabelle `tired_events`** (Migration `20260822000000_tired_events.sql`): `id uuid (PK), user_id, date, created_at timestamptz DEFAULT now()`. Reines Append-Log (kein UPDATE/DELETE, anders als `pending_focus_sessions`) — RLS erlaubt nur SELECT/INSERT der eigenen Zeilen. `date` wird clientseitig als `todayKey()` mitgesendet (gleiche 4-Uhr-Berlin-Grenze wie überall sonst), damit die Spalten-Zuordnung im Chart ohne serverseitige Neuberechnung funktioniert. Insert über `tryPostTiredEvent()` (Direkt-`fetch`, `Prefer: return=representation`, kein RPC nötig, da keine serverseitige Validierung/Berechnung anfällt).
- **Chart-Semantik**: Y-Achse ist eine **feste 24h-Zeit-Skala** (0 = 04:00, 24 = 03:59 des Folgetags Berlin-Zeit), keine datenabhängige Betrags-Skala wie beim Stats-Balkendiagramm. X-Achse: eine Spalte pro Lerntag, komplette Historie seit App-Start (`ATTENTION_FROM_DATE = '2026-05-10'`, identisch zu `loadBarChart()`s `FROM_DATE`). Pro `pomodoro_sessions`-Zeile ein „schwebendes" Zeitbereich-Rechteck: Ende = `created_at` (Speicherzeitpunkt der Session), Start = Ende minus `duration_minutes`, an der 4-Uhr-Grenze geclamped. **Pausen werden im Fokustimer nicht gespeichert** — das Segment orientiert sich bewusst nur am Speicherzeitpunkt, nicht am tatsächlichen (unbekannten) Sessionstart; kann die reale Verteilung verzerren (bewusst in Kauf genommene Vereinfachung). Tired-Zeitpunkte werden als rote Punkte (`<circle>`, `#dc2626`) an derselben Y-Positionierung eingezeichnet.
- **Spalten-Geometrie identisch zu `renderBarChart()`** (Stats-Card-Balkendiagramm, siehe „Label-Stats Overlay" unten): `leftPad/rightPad/bottomPad/topPad/svgH`, `slotW`/`barW`-Berechnung aus `content.clientWidth`, X-Achsen-Label-Ausdünnung über die modul-globalen `NICE_INTERVALS`/`DE_DAYS`/`MONTHS_DE`-Konstanten (aus `renderBarChart()` herausgehoben, damit beide Charts dieselben Instanzen nutzen), `ResizeObserver`-Pattern (debounced 120ms). `buildDateKeysSinceFromDate(fromDate)` ist der aus `loadBarChart()` extrahierte, geteilte Helper für die Lerntag-Liste seit einem Startdatum.
- **Farben**: `var(--accent)` (Grün, `#1D9E75`) für die Fokuszeit-Segmente, `#dc2626` (bereits im Code als „das" Rot etabliert, z. B. Rolling-Mean-Linie im Stats-Balkendiagramm) für die Tired-Punkte.
- **Datenladung**: `loadAttentionChart()` lädt `pomodoro_sessions` (mit `created_at`, zusätzlich zu `date`/`duration_minutes` — ein eigener Fetch, getrennt vom Stats-Balkendiagramm, das `created_at` nicht selektiert) und `tired_events` parallel für den vollen Zeitraum, aufgerufen einmalig in `onLoginSuccess()`.
- **Live-Update**: `creditFocusMinutes()` hängt bei jeder Kreditierung optimistisch ein neues Segment an (`created_at: new Date().toISOString()`) und rendert neu, ohne Fetch — der reale Serverwert wird beim nächsten Login/Reload über `loadAttentionChart()` ohnehin nachgezogen. Ein Tired-Klick zeichnet den neuen Punkt ebenso sofort lokal nach.
- **Bugfix (heutige Fokuszeiten/Tired-Klicks fehlten bei seit gestern offenem Tab)**: `lastAttentionDateKeys` (die Tages-Spalten-Liste fürs Chart) wurde nur einmal beim Login gebaut (`loadAttentionChart()`). Blieb der Tab über die 4-Uhr-Grenze hinweg offen, fehlte „heute" in dieser inzwischen veralteten Liste — jede danach optimistisch nachgezogene Session (`creditFocusMinutes()`) oder jeder Tired-Klick (`initAttentionCard()`) hatte dann keine Spalte zum Rendern, `renderAttentionChart()`s `byDate[key]`-Guard verwarf sie still (Daten blieben in der DB korrekt, erschienen aber nicht im Chart). Jetzt baut `refreshedAttentionDateKeys()` die Liste bei jedem optimistischen Update frisch (`buildDateKeysSinceFromDate(ATTENTION_FROM_DATE)`), statt die potenziell veraltete `lastAttentionDateKeys` direkt weiterzuverwenden — beide o.g. Aufrufstellen nutzen sie jetzt statt der Variable direkt.
- **Y-Achsen-Orientierung**: oben = 04:00, unten = 03:59 des Folgetags (wie eine Tagesansicht in Kalender-Apps, Zeit läuft von oben nach unten).

### Risiko-Analyse (KDE + DBSCAN)

Zweites, eigenständiges Chart (`#attention-histogram-content`, statisch unter `#attention-chart-content` im Markup, gerendert von `renderAttentionRiskHistogram()`, UI-Überschrift „Müdigkeitsrisiko") erkennt aus der gesamten `tired_events`-Historie wiederkehrende Risiko-Zeitfenster für schlechte Konzentration — per Kernel Density Estimation UND per 1D-DBSCAN als unabhängige Vergleichsmethode. Wird am Ende von `renderAttentionChart()` mitaufgerufen (kein eigener Aufrufer/`ResizeObserver` nötig, läuft im bestehenden Zyklus mit).

- **Zirkuläre Domäne**: die Tageszeit ist periodisch (Periode `ATTENTION_PERIOD_MIN = 1440`, nahtlos über die 4-Uhr-Grenze) — zieht sich durch alle drei Bausteine unten. Intervall-Konvention überall: `{start, end}` in Minuten seit 4:00, `end < start` heißt „wraps über die 4-Uhr-Grenze".
- **KDE**: `circularGaussianKdeDensity()` summiert pro Datenpunkt die drei periodischen Kopien (`x-P`, `x`, `x+P`) — bei den verwendeten Bandbreiten (~10–90 min gegenüber 1440 min Periode) numerisch exakt genug. Bandbreite via `silvermanBandwidthMin()`: **zirkuläre** Standardabweichung (Mardia/Fisher-Formel über die mittlere Resultantenlänge R), nicht die lineare Stichproben-SD — sonst würden zwei nahe der 4-Uhr-Naht liegende, aber tatsächlich benachbarte Punkte (z. B. 23:55/00:05) als ~1430 Minuten auseinanderliegend gezählt statt der wahren zirkulären Distanz von 10 Minuten. **Bekannte Einschränkung**: Silverman's Rule glättet bei mehrgipfligen (multimodalen) Verteilungen tendenziell zu stark, mehrere echte Peaks können zu einem verschmelzen — verifiziert mit den ersten 34 echten Tired-Klicks des Owner-Accounts: Silverman-Default landete bei ~90 min und verschmolz alle Peaks zu einem Klumpen. `ATTENTION_KDE_BANDWIDTH_OVERRIDE_MIN` (`null` = automatisch, Zahl = manueller Override) ist deshalb production auf **12** (fester Wert, nicht `null`) gesetzt — 8/12/15 min gegen die echten Daten verglichen, 12 als bester Kompromiss aus erkennbarer Peak-Struktur (nicht so verrauscht wie 8) und Detailschärfe (nicht so verschmiert wie 15). Jederzeit direkt im Code nachjustierbar.
- **Peaks/Intervalle**: `findCircularPeaks()` (lokale Maxima, zirkulärer Nachbarvergleich, gefiltert auf `≥ maxDensity · ATTENTION_PEAK_MIN_HEIGHT_FRACTION`), `attentionRiskIntervalsFromKde()` läuft von jedem Peak beidseitig, bis die Dichte unter `Peak-Höhe · ATTENTION_INTERVAL_THRESHOLD_FRACTION` fällt (Halbwertsbreite), überlappende Intervalle (auch zirkulär benachbarte) werden gemergt.
- **DBSCAN**: `circularDbscan1D()` konkateniert die Werte dreifach (`-P`/`0`/`+P`) und clustert linear auf dem sortierten Ergebnis (bei sortierten 1D-Daten ist die `eps`-Nachbarschaft ein einfacher Zeiger-Scan, kein O(n²)). Ein Cluster, der wirklich über die 4-Uhr-Naht läuft, zerfällt dabei zwangsläufig in zwei Ketten (an beiden künstlichen Schnittstellen der drei Kopien) — Union-Find über die Cluster-IDs, die ein und derselbe Punkt in seinen drei periodischen Kopien erhält, verschmilzt sie zu einem echten Kreis-Cluster. Das Intervall wird danach **nicht** über Min/Max aller (auch geshifteter) Mitglieder gebildet — die Union kann eine dritte, rein „geisterhafte" Kopie ohne eigene Original-Mitglieder mitverschmelzen und würde das Intervall künstlich aufblähen — sondern über `smallestEnclosingCircularArc()` (größte Lücke im sortierten zirkulären Array liegt außerhalb des Clusters) nur der echten Original-Punkte.
- **Konfiguration bewusst Code-Level statt Settings-UI** (`ATTENTION_KDE_BANDWIDTH_OVERRIDE_MIN`, `ATTENTION_KDE_GRID_STEP_MIN`, `ATTENTION_HISTOGRAM_BIN_MIN`, `ATTENTION_PEAK_MIN_HEIGHT_FRACTION`, `ATTENTION_INTERVAL_THRESHOLD_FRACTION`, `ATTENTION_DBSCAN_EPS_MIN`, `ATTENTION_DBSCAN_MIN_SAMPLES`, alle direkt über den Funktionen) — gleiches Muster wie `RACE_FIELDS`/`LIBRARY_BUILDINGS`/`ATTENTION_FROM_DATE`, reine Kalibrierungswerte nur für den Entwickler beim Beobachten der eigenen Daten relevant.
- **Histogramm-Darstellung**: X-Achse = Tageszeit 04:00 (links) → 04:00 (rechts), normale Leserichtung (bewusst nicht invertiert wie die Y-Achse des Punktdiagramms darüber — Balken stehen, Zeit gehört auf die X-Achse), gleiche Stunden-Gitterlinien-Konvention (`04/08/12/16/20/00/04`) wie oben für eine konsistente Zeit-Referenz zwischen beiden Karten. `ATTENTION_HISTOGRAM_BIN_MIN`-Bins (**15 min**), Balkenhöhe = KDE-Dichte an der Bin-Mitte (gleiche Bandbreite wie die Peak-Erkennung). DBSCAN-Cluster als eigene Marker-Reihe unterhalb der Stunden-Beschriftung (`#64b5f6`, bereits als „Info"-Farbe etabliert, siehe Leaderboard-Rang-Indikator „Neu im Leaderboard"), Ausreißer als kleine graue Punkte; ein wrap-Cluster wird als zwei Liniensegmente bis zum jeweiligen Rand gezeichnet.
- **Balkenfarbe = kontinuierlicher Rot-Verlauf nach Risikohöhe**: `riskBarColor(t)` (`t = risk/axisMax`, geclampt auf `[0,1]`) interpoliert linear (`lerpHexColor()`) zwischen Tailwind red-100 (`#fee2e2`, niedriges Risiko) und red-900 (`#7f1d1d`, hohes Risiko) — Skala bewusst an `axisMax` gekoppelt statt an einen fixen Wertebereich, deckt sich dadurch direkt mit der Balkenhöhe (ein Balken ganz oben an der Achse ist immer auch der dunkelste). Ersetzt die frühere binäre `fill-opacity`-Unterscheidung (voll deckend innerhalb, 0.22 außerhalb eines Risiko-Intervalls) — die KDE-Intervall-Zugehörigkeit ist jetzt davon unabhängig über einen dünnen Rahmen markiert (`stroke="#450a0a"`), damit sie die kontinuierliche Farbskala nicht überdeckt. Kein eigener Legenden-Eintrag mehr dafür (auf Wunsch entfernt) — der Rahmen ist ein stilles Detail, keine erklärte UI-Funktion mehr.
- **Y-Achse = relatives Risiko gegenüber der Gleichverteilung**, nicht mehr „Anteil vom höchsten Balken" (Bugfix/UX-Fix — die ursprüngliche Peak-Normierung reizte praktisch jeden Datensatz unabhängig vom tatsächlichen Risikoniveau bis nahe 100 % aus und war dadurch „fast durchgehend hohe Werte, wenig aussagekräftig"). Eine perfekte Gleichverteilung über 24h hätte konstante Dichte `1/ATTENTION_PERIOD_MIN` — `density · ATTENTION_PERIOD_MIN` ist also exakt der Faktor gegenüber dem Tagesdurchschnitt (1.0 = durchschnittliches Risiko, 2.0 = doppelt so wahrscheinlich wie im Tagesschnitt). Y-Achse dynamisch skaliert über `niceAxisStep()` (analog `NICE_INTERVALS`-Prinzip, aber für die Risiko-Skala: wählt aus `[0.5,1,2,3,5,10,20]` die kleinste Schrittweite mit ≤6 Gitterlinien bis zum höchsten Balken, Untergrenze `maxRisk = Math.max(1, …)` hält die Ø-Linie auch bei durchgehend unterdurchschnittlichem Risiko im sichtbaren Bereich), plus eine hervorgehobene gestrichelte Referenzlinie bei genau `1.0` („Ø" beschriftet) — macht auf einen Blick sichtbar, was über/unter dem Tagesdurchschnitt liegt. Balken-Tooltip zeigt den Faktor (z. B. „14:00 · 2.30× Ø-Risiko").
- **Leerer Zustand**: bei `tiredEvents.length === 0` erscheint ein Platzhaltertext statt eines leeren Charts.

---

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
- **Nur noch ein Pausen-Modus**: „Lange Pause" wurde komplett entfernt, es gibt nur noch `mode='short'`, im UI als „Pause" beschriftet (Button, `modeLabels`, Settings-Panel). Übernimmt weiterhin die bisherigen „Kurze Pause"-Werte (`set-short`/`short_min`). Nach jeder Fokus-Session geht es jetzt immer direkt zu `switchTo('short', …)` — kein Alternieren mehr nach Pomodoro-Anzahl (`getLongAfter()` entfernt). `profiles.long_min`/`long_after` sind dadurch verwaiste, ungenutzte Spalten (keine Migration, um das Risiko klein zu halten — werden client-seitig einfach nicht mehr gelesen/geschrieben)
- **Bugfix (`20260714000000_fix_leaderboard_timer_active_limitless.sql`)**: der grüne Live-Timer-Punkt im Leaderboard blieb im Limitless-Modus immer aus. `leaderboard_today()`/`leaderboard_aggregated()` prüften `timer_active` nur über `end_at IS NOT NULL AND end_at > now()` — ein reines Countdown-Feld. Eine laufende Limitless-Session setzt aber nie `end_at`, sondern `started_at` (siehe „Timer State Persistence"); die Funktionen existierten schon vor dem Limitless-Feature und wurden nie nachgezogen. Jetzt zusätzlich aktiv, wenn `limitless = true AND started_at IS NOT NULL` (analog zum Countdown-Fall ist `started_at` während einer Pause `null`, das Pausiert-Verhalten bleibt also unverändert)
- **Bugfix (`20260729000000_fix_card_trades_sell_fk.sql`, `20260729000010_fix_card_trades_listing_offer_fk.sql`)**: `sell_card()` scheiterte mit `23503`-FK-Fehler beim Verkaufen einer Karten-Kopie, die vorher schon einmal getauscht wurde. Ursache: `respond_to_trade_offer()` überträgt eine Karte per `UPDATE user_cards.user_id` (kein Re-Insert) — dieselbe physische `user_cards`-Zeile bleibt bestehen und wird dauerhaft in `card_trades.user_card_id` referenziert. `sell_card()`s `DELETE FROM user_cards` filtert nur aktiv gelistete Kopien raus, nicht getauschte — das `DELETE` kaskadiert außerdem über `card_listings` (`ON DELETE CASCADE`) weiter zu `trade_offers`, wurde dort aber zusätzlich von `card_trades.listing_id`/`card_trades.trade_offer_id` blockiert (beide ursprünglich ohne `ON DELETE`-Klausel = `NO ACTION`). Fix: alle drei FKs (`user_card_id`, `listing_id`, `trade_offer_id`) auf `ON DELETE SET NULL` umgestellt — `card_trades`-Zeilen werden nie gelöscht (Audit-Log bleibt vollständig, `card_id`/`seller_id`/`buyer_id`/`traded_at` bleiben aussagekräftig), verlieren beim Verkauf der referenzierten Kopie nur den Bezug zur inzwischen weggeräumten physischen Karte/Listing/Trade-Offer

### Bestätigungs-Dialoge (Timer-Card)
- **Reset im Fokus-Modus** (nur wenn `running`): zeigt Bestätigungs-Banner vor `reset()`
- **„✓ Jetzt"-Button**: erscheint bei `mode === 'work' && running && elapsedSec() >= 60` (ab der ersten vollen Minute); Bestätigungs-Banner vor `finishEarly()`
- Fortschritt-verwerfen-Bestätigungen (Moduswechsel, Reset) nutzen `hasProgress()` statt eines direkten `remaining < totalSec`-Vergleichs — im Limitless-Modus ist `totalSec` immer `0`, ein direkter Vergleich würde dort nie greifen

### Eier & Kartensammlung — Supabase-Schreibpfade
- **Ei kaufen**: PATCH `profiles` (diamonds + eggs)
- **Zweiten Brutkasten kaufen**: PATCH `profiles` (diamonds + second_incubator_purchased)
- **-1h / Skip**: PATCH `incubator?user_id=eq.<id>&slot_index=eq.<n>` (focus_minutes_at_placement) + PATCH `profiles` (diamonds); normalisiert lokales `bonusMin` auf 0
- **Drag & Drop → Brutkasten**: POST-Upsert `incubator` (Body inkl. `slot_index`, `?on_conflict=user_id,slot_index`) + PATCH `profiles.eggs`
- **Schlüpfen**: `draw_card()` RPC (serverseitig) → INSERT `user_cards`; bei Fehler lokaler Fallback
- **Karte ins Deck**: DELETE `incubator?user_id=eq.<id>&slot_index=eq.<n>` (nur die Zeile des Slots, aus dem geschlüpft wurde)
- **Level-Up-Ei**: PATCH `profiles.eggs` via `saveEggProfile()`
- **Duplikat verkaufen**: `sell_card(p_card_id)` RPC (atomar: zieht zusätzlich eigene aktive Listings + offene Gegenangebote dieser Karte zurück, DELETE `user_cards` + UPDATE `profiles.diamonds`); nur möglich wenn `count > 1`; Belohnung: common 4 / rare 8 / epic 12 / legendary 16 / mystic 20 💎
- **Karte zum Tausch anbieten**: `create_listing(p_card_id)` RPC → INSERT `card_listings` (kein Preis)
- **Angebot zurückziehen**: `cancel_listing(p_listing_id)` RPC (Claim-Mutex-Update `active→cancelled` + Ablehnung offener Gegenangebote)
- **Gegenangebot machen**: `create_trade_offer(p_listing_id, p_offered_card_ids)` RPC → INSERT `trade_offers` + `trade_offer_cards` (max. 1 pending pro Listing)
- **Gegenangebot zurückziehen**: `cancel_trade_offer(p_offer_id)` RPC (Claim-Mutex-Update `pending→cancelled`, nur eigene Gegenangebote)
- **Gegenangebot annehmen/ablehnen**: `respond_to_trade_offer(p_offer_id, p_accept)` RPC (atomar bei Annahme: beidseitige `user_cards.user_id`-Übertragung + `card_trades`-Log + Cleanup-Kaskade), siehe „Tauschbörse"

---

## Siehe auch

- [[Lernkalender/README|Lernkalender]] — liest `pomodoro_sessions` für sein Statistik-Overlay und erkennt die `pomo_session` wieder
- [[FocusFM/README|FocusFM]] — eigenständiges Projekt, nutzt ebenfalls die [[Web Audio API]] für synthetisierten Sound
- [[Dashboard/README|Dashboard]] — verlinkt auf die online gehostete Pomodoro-Seite (`ragnarg-0.github.io/Pomodoro`)
