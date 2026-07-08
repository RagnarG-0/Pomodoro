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

### Tabellen

| Tabelle | Inhalt |
|---|---|
| `profiles` | username, public, avatar_url, diamonds, eggs, clan_id, clan_role, focus_min, short_min, display_unit, off_weekdays, sound |
| `study_days` | user_id, date, minutes, off |
| `pomodoro_sessions` | user_id, date, label, duration_minutes |
| `timer_state` | user_id, end_at, total_sec, mode, paused_remaining, pomoday, limitless, started_at, credited_min |
| `incubator` | user_id (PK), egg_color char(1), placed_at, focus_minutes_at_placement |
| `cards` | id int (PK), name, rarity |
| `user_cards` | id uuid (PK), user_id, card_id, obtained_at |
| `clans` | id, name, leader_id, min_focus_min, max_focus_min, level_config (JSONB), created_at |
| `clan_requests` | id, clan_id, user_id, status (`pending`/`accepted`/`rejected`), created_at |
| `weekly_challenges` | challenge_key (PK), tier, metric_type, param_n, param_h, reward_diamonds, pool_index, label, active |
| `weekly_challenge_claims` | id uuid (PK), user_id, week_start, challenge_key, reward_diamonds (Snapshot), claimed_at |

`profiles.eggs` ist ein TEXT-String der Form `y-b-0-0-0-0-0-0-0-0` (10 Tokens, `-`-getrennt). Farb-IDs: `y/b/g/r`, `0` = leerer Slot.

`profiles.clan_role` ist `'leader'` | `'member'` | null.

`incubator` hat max. 1 Zeile pro Nutzer. Brut-Fortschritt = `sum(study_days.minutes) − focus_minutes_at_placement`, Ziel = 600.

`clans.level_config` ist ein JSONB-Array mit 25 Einträgen `{ name, icon, minMinutes }`.

### RPCs

| Funktion | Zweck |
|---|---|
| `add_study_minutes(p_date, p_minutes)` | Addiert Delta auf study_days (nicht idempotent!) |
| `get_label_stats(p_user_id)` | Gibt je Label: today_minutes, week_minutes, month_minutes, alltime_minutes |
| `leaderboard_today()` | Rangliste für heute |
| `leaderboard_aggregated(date_from)` | Rangliste ab Datum |
| `get_yesterday_winner()` | Name des gestrigen Tagesersten |
| `draw_card()` | Würfelt Rarität (40/30/18/9/3 %), wählt Karte, schreibt in `user_cards`, gibt `card_id int` zurück |
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
eggInventory  // Array[10] — null | { id, color } — lokale Kopie aus profiles.eggs
incubatorData // null | { color, focus_minutes_at_placement, bonusMin } — aus incubator-Tabelle
eggDeck       // Array von { id, name, rarity, src, count } — aus user_cards
clanRole      // 'leader' | 'member' | null — aus profiles.clan_role
clanId        // uuid | null — aus profiles.clan_id
clanMaxFocus  // number — aus clans.max_focus_min (begrenzt +5min-Button)
limitlessSetting     // boolean — persistierte Checkbox-Präferenz „Unbegrenzt (Stoppuhr)"
limitless            // boolean — true, wenn die AKTUELLE Work-Session eine Stoppuhr ist
limitlessCreditedMin // number — bereits per Zwischenkredit gutgeschriebene Minuten der laufenden Limitless-Session
lastTimerInteractionAt // ms-Timestamp — für Idle-Suspend des 4-Uhr-Reset-Watchdogs (siehe „4-Uhr-Reset")
challengesActiveTier // 'leicht' | 'mittel' | 'schwer' — aktiver Tab in der Wochen-Challenges-Karte
claimedChallengeKeys // Set<string> — bereits eingelöste challenge_keys der aktuellen Woche
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
- **Timer-Card-Anzeige**: statt der analogen Uhr (`updateWatch()`) zeigt `updateLimitlessTrack()` einen horizontalen Fortschrittsbalken auf einem fixen 0–12h-Zeitstrahl (`#limitless-track-wrap`, Sibling von `.watch-wrap` in der Timer-Card); `renderTimer()` togglet zwischen beiden über `showElapsed` (= `mode === 'work' && limitless`). Balkenfüllung = live „heute gelernte Minuten" (`(days[creditKey]||0) - limitlessCreditedMin + Math.floor(remaining/60)`, `creditKey = pomoDay || todayKey()`), aktualisiert bei jedem Tick — nicht nur beim 20-Min-Checkpoint. Ein Marker auf dem Zeitstrahl zeigt den persönlichen Rekord (`computeBestDay(excludeKey)` — neuer optionaler Parameter, schließt den heutigen Tag aus, damit der Rekord nicht sich selbst hinterherläuft; ohne Argument weiterhin für die „Bester Tag"-Stat-Karte in `renderStats()`). Fill- und Marker-Position werden unabhängig auf `Math.min(1, x/720)` geklemmt (12h-Rand)
- **PR-Bruch-Notification**: wird der persönliche Rekord während einer laufenden Limitless-Session überschritten, feuert eine Push-Notification (Tag `pomodoro-pr-broken`, eigener Tag getrennt von `pomodoro-eye-break`/`pomodoro-timer`) — auch bei eingefrorenem Hintergrund-Tab, da SW-seitig vorausgeplant statt im Vordergrund-Tick geprüft. `schedulePRTargetIfPending(startedAtMs)` (index.html, nahe `swSend`) berechnet den exakten Zeitpunkt (`crossAtMs = startedAtMs + (prMin - baseline) * 60000`) und sendet `{ type: 'PR_TARGET_SCHEDULE', crossAtMs, prMinutes }`; der SW plant dafür per `setTimeout` (one-shot, kein Selbst-Reschedule wie beim Eye-Break) und cleart es bei `TIMER_PAUSE`/`TIMER_RESET`/`TIMER_SKIP` mit. Aufgerufen an denselben Stellen wie `EYE_BREAK_START` (`start()`, `restoreTimerState()`). Idempotent **ohne** localStorage-Flag: `baseline = days[creditKey] - limitlessCreditedMin` bewegt sich nie unabhängig von `limitlessCreditedMin` (beide wachsen in `checkLimitlessCheckpoint()` immer um dasselbe Delta) — ist der Rekord bereits gebrochen (frühere Session heute, oder vor einer Pause in der laufenden Session), gilt `baseline >= prMin` sofort und es wird nichts neu geplant
- **Stolperstein**: mehrere Stellen berechnen `totalSec`/`remaining` bei Idle-Zustand neu aus `getMin(mode) * 60` (Boot vor `initAuth()`, `save-settings-btn`, Logout, `loadClanSettings()`, Label speichern/auswählen) — jede davon muss zuerst auf `mode === 'work' && limitless` prüfen und in diesem Fall `0`/`0` setzen, sonst zeigt die Stoppuhr nach Neuladen/Speichern fälschlich die normale Fokusdauer (z. B. „01:00:00" bei 60-Min-Fokuseinstellung) statt „00:00:00"

### 4-Uhr-Reset laufender/pausierter Fokus-Sessions
- Um 4 Uhr Berliner Zeit wird jede laufende oder pausierte Fokus-Session (Countdown **und** Limitless) automatisch wie ein „✓ Jetzt" beendet: nur die bis 4 Uhr tatsächlich verstrichene Zeit wird `pomoday` (Vortag) gutgeschrieben, danach Leerlauf — kein automatisches Fortsetzen, kein Toast (still, wie der Zwischenkredit)
- **Client**: `checkDayRollover()` (index.html, neben `checkLimitlessCheckpoint()`) prüft `todayKey() !== pomoDay`; aufgerufen von `start()` (vor der eigentlichen Start/Pause-Logik, macht den Check unabhängig vom Watchdog-Zustand), den Mode-Button- und `btn-reset`-Klick-Handlern (sonst ginge der Fortschritt beim `reset()` verloren, ohne kreditiert zu werden), dem `visibilitychange`-Handler und einem 60s-Watchdog-`setInterval`
- Watchdog setzt sich nach 2h Inaktivität (`!running` und `lastTimerInteractionAt` >2h her) selbst aus; `markTimerActivity()` (in `start()`, `reset()`, `finishEarly()`, `skip()`) reaktiviert ihn beim nächsten Timer-Klick synchron innerhalb desselben Aufrufs — nicht erst beim nächsten Watchdog-Tick
- `clearTimerState()` dient als Claim-Mutex gegen den Server-Cron (siehe unten) — wer zuerst die `timer_state`-Zeile löscht, kreditiert; der andere setzt nur lokal in den Leerlauf zurück
- **Server**: `reset_stale_work_sessions()` (SECURITY DEFINER, `supabase/migrations/20260708000000_reset_stale_work_sessions.sql`), per `pg_cron` alle 5 Minuten. Grenzwertbasiert statt zeitpunktbasiert geprüft (`4:00 Berlin AT TIME ZONE`, DST-sicher) — läuft auch, wenn niemand die Seite offen hat (z.B. Limitless-Session über Nacht bei geschlossenem Tab). Rührt bereits vor 4 Uhr regulär abgelaufene Countdown-Sessions bewusst nicht an (bestehendes „nie zurückgekehrt"-Verhalten, kein Teil dieses Features)
- **Bugfix (`20260711000000_fix_reset_cron_double_credit.sql`)**: Der Cron kreditierte ursprünglich **vor** dem `DELETE FROM timer_state`, ohne zu prüfen, ob die Zeile zu dem Zeitpunkt überhaupt noch existierte — lief eine Session dem Client-seitigen `checkDayRollover()` im selben 5-Minuten-Fenster über den Weg, konnte dieselbe Restzeit doppelt kreditiert werden (sichtbar u.a. als überzählige Medaillen in `leaderboard_wins()`, die live aus `study_days` rechnet). Jetzt: `DELETE ... RETURNING *` zuerst, nur bei tatsächlich gelöschter Zeile wird mit den frisch gelöschten Werten kreditiert (Claim-Mutex jetzt symmetrisch zum Client)
- **Bugfix (`20260712000000_fix_daily_winners_timing.sql`)**: Der separate `daily-winners`-Cron (Diamanten-Auszahlung, globale Top-3 unabhängig vom Clan) lief fix um 01:59 UTC (~03:59 Berlin im Sommer, ~02:59 im Winter) — **vor** der echten 4-Uhr-Grenze. Bei kurzen Pomodoros fiel das nie auf, aber eine über Nacht laufende Session wird erst nach 4 Uhr durch `reset_stale_work_sessions()` final verbucht; lief `daily-winners` davor, fehlte genau dieser letzte Rest in `daily_winners` — und wegen `ON CONFLICT (date, rank) DO NOTHING` nie nachträglich korrigierbar. Jetzt: alle 5 Minuten geprüft, aber nur ausgewertet sobald `extract(hour from ... at time zone 'Europe/Berlin') >= 4` (davor liefert die CTE 0 Zeilen, reiner No-Op), zeitlich 2 Minuten nach `reset-stale-work-sessions` versetzt (`2-59/5 * * * *` vs. `*/5 * * * *`), damit übrig gebliebene Nacht-Sessions garantiert zuerst verbucht sind. **Wichtig**: `leaderboard_wins()`/`get_yesterday_winner()` (clan-scoped, live aus `study_days`) sind davon nicht betroffen und waren nie das Problem — `daily_winners` ist die **globale** Top-3-Rangliste (alle öffentlichen Nutzer, unabhängig vom Clan), nur für die Diamanten-Auszahlung; unterschiedliche Rangfolgen zwischen beiden sind normal und kein Fehler

### Timer State Persistence (Supabase)
- Laufender Countdown-Timer: `end_at` gesetzt, `limitless = false`
- Laufende Limitless-Session: `started_at` gesetzt (Pendant zu `end_at`), `end_at = null`, `limitless = true`, `credited_min` = zuletzt kreditierter Stand
- Pausierter Timer: `end_at = null` (bzw. `started_at = null` bei Limitless), `paused_remaining` gesetzt
- Bei Seitenaufruf: `restoreTimerState()` liest den State und setzt fort (Countdown oder Stoppuhr) oder krediert abgelaufene Pomodoros
- **Spalte heißt `pomoday` (Kleinschreibung)**, nicht `pomoDay` — ein früherer Bug las sie beim Restore fälschlich als `state.pomoDay` (immer `undefined`); beide Restore-Zweige lesen jetzt korrekt `state.pomoday`
- `start()` überschreibt `pomoDay` beim Fortsetzen nach Pause **nicht** mehr (nur `if (pomoDay == null)`) — verhindert, dass ein Pause-Resume kurz vor 4 Uhr den Kredit-Tag verschiebt

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
| `pomo_display_unit` | 'pomodoros' \| 'time' | — |
| `pomo_sound` | ausgewählter Sound-Key | — |
| `pomo_lb_cache_<period>` | Leaderboard-Liste ohne Winner | 2–10 min |
| `pomo_lb_winner` | Gestriger Tagessieger (Name) | 1h |
| `pomo_lb_ranks_<period>` | Rang-Snapshot nach letztem Server-Fetch (`{ name: rank }`) | — |
| `pomo_label_stats_<userId>` | Label-Stats-Array | 5 min |
| `pomo_egg_preview` | `'1'` wenn Clan-Leader den Placeholder deaktiviert hat | — |
| `pomo_export_last_<userId>` | Zeitstempel des letzten CSV-Exports (Cooldown) | 12h |
| `pomo_limitless_v1` | `'1'`/`'0'` — Präferenz „Unbegrenzt (Stoppuhr)"-Modus, geräte-lokal | — |

---

## UI-Karten (von oben nach unten)

1. **Timer-Card** — Analog-Uhr SVG (im Limitless-Fokusmodus stattdessen der Zeitstrahl-Fortschrittsbalken, siehe „Limitless (Stoppuhr-)Fokus-Modus"), Modi (Fokus/Pause), Label-Input mit Dropdown, +5min, „✓ Jetzt"-Button (frühzeitiger Abschluss), Confetti bei Abschluss
2. **Heatmap-Card** — 100-Tage-Grid, scrollbar, Klick = Off-Day togglen, DOW-Labels links
3. **Stats-Card** — Level (25 Stufen), Streak, Bester Tag, Wochenschnitt; „mehr Infos" öffnet Label-Stats-Overlay (inset, gleiche Card)
4. **Wochen-Challenges-Card** (`#challenges-card`) — nur sichtbar für eingeloggte Nutzer (kein Clan-/Public-Gating); Tabs Leicht/Mittel/Schwer, je 3 Progress-Bar-Zeilen mit Belohnungs-Label / „Einlösen"-Button / „✓ eingelöst"
5. **Ei-Box** (`#eggBox`) — Diamanten-Anzeige, Brutkasten (1 Slot), -1h/Skip-Buttons, aufklappbares 10-Slot-Inventar; hinter Placeholder versteckt (`#egg-placeholder-overlay`)
6. **Deck-Box** (`#deckBox`) — aufklappbares Karten-Grid, nach Rarität sortiert, Stapel-Optik bei Duplikaten; hinter demselben Placeholder
7. **Leaderboard-Card** — nur sichtbar wenn `userPublic === true && clanRole != null`; Tabs: Heute/Letzte Woche/Letzter Monat/All Time; Tagessieger-Highlight = goldener Border; Live-Timer-Dot (grün, `entry.timer_active` aus `leaderboard_today()`/`leaderboard_aggregated()`); Rang-Änderungs-Indikator (▲ grün / ▼ rot / ● hellblau für Neue) vor dem 🃏-Button, nur nach echtem Server-Fetch sichtbar

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

---

## Clan-System

### Datenbank
- **`clans`**: id, name, leader_id, min_focus_min, max_focus_min, level_config (JSONB-Array mit 25 Stufen), created_at
- **`clan_requests`**: id, clan_id, user_id, status (`pending`/`accepted`/`rejected`), created_at
- **`profiles`** erweitert um `clan_id` und `clan_role` (`'leader'`|`'member'`|null)
- RLS: `profiles_read_own` (eigenes Profil) + `profiles_read_clan_peers` (via `my_clan_id()` SECURITY DEFINER)
- **Wichtig**: Subqueries in RLS-Policies auf `profiles` müssen SECURITY DEFINER-Funktionen nutzen — sonst rekursiver Loop → Profil nicht lesbar → Auto-Reset

### UI
- **Header**: Glocken-Icon (nur Leader) mit Badge + Dropdown für offene Beitrittsanfragen
- **Header**: „Clan"-Button (Nutzer ohne Clan) mit zwei Tabs: „Clan suchen" und „Neuen Clan erstellen"
- **Clan suchen**: listet alle aktiven Clans, Anfrage geht an spezifischen Clan
- **Neuen Clan erstellen**: Namenseingabe, Ersteller wird automatisch Leader
- **Leader-Einstellungen**: Clan-Name, Min./Max. Fokuszeit, Level-Namen-Editor, Mitgliederliste mit Entfernen-Button
- **Timer**: `+5 min` wird auf `clanMaxFocus` geclampt
- **Neue Nutzer**: `submitJoinRequest()` wird automatisch nach Registrierung aufgerufen; Registrierungsflow bietet Clan gründen / beitreten / überspringen

### Registrierter Clan
- Clan „Schwitzende Verbindung Halle" — alle `public = true`-Profile als Member

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

---

## Karten-Katalog (33 Karten)

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

Raritäten & Ziehwahrscheinlichkeiten: common 40 %, rare 30 %, epic 18 %, legendary 9 %, mystic 3 %.

---

## Eier-System

### Farben & Bilder
4 Ei-Farben: `y` (gelb), `b` (blau), `g` (grün), `r` (rot). Bilder: `CDN/Eier/<farbe>/Stadium_<1-4>.png`.

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
| Brutzeit −1h | 1 💎 |
| Brutzeit überspringen | ⌈verbleibende Stunden⌉ 💎 |

Fehler-Banner bei zu wenig Diamanten: „Du bist wohl gesetzlich versichert. Verdiene mehr Diamanten und probiere es nochmal!"

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
- **Rate-Limit**: 12h-Cooldown pro Nutzer über `pomo_export_last_<userId>` (`cacheSet`/localStorage), um Supabase-Egress zu begrenzen. Wird nur bei erfolgreichem Export mit Treffern gesetzt — leere Zeiträume zählen nicht
- Fehlerfälle: kein Login → „Bitte anmelden.", ungültiger Zeitraum (`from > to`) → Validierungsfehler ohne Request, aktiver Cooldown → Restzeit-Anzeige (`Xh Ymin`)

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

### Bestätigungs-Dialoge (Timer-Card)
- **Reset im Fokus-Modus** (nur wenn `running`): zeigt Bestätigungs-Banner vor `reset()`
- **„✓ Jetzt"-Button**: erscheint bei `mode === 'work' && running && elapsedSec() >= 60` (ab der ersten vollen Minute); Bestätigungs-Banner vor `finishEarly()`
- Fortschritt-verwerfen-Bestätigungen (Moduswechsel, Reset) nutzen `hasProgress()` statt eines direkten `remaining < totalSec`-Vergleichs — im Limitless-Modus ist `totalSec` immer `0`, ein direkter Vergleich würde dort nie greifen

### Eier & Kartensammlung — Supabase-Schreibpfade
- **Ei kaufen**: PATCH `profiles` (diamonds + eggs)
- **-1h / Skip**: PATCH `incubator` (focus_minutes_at_placement) + PATCH `profiles` (diamonds); normalisiert lokales `bonusMin` auf 0
- **Drag & Drop → Brutkasten**: POST-Upsert `incubator` + PATCH `profiles.eggs`
- **Schlüpfen**: `draw_card()` RPC (serverseitig) → INSERT `user_cards`; bei Fehler lokaler Fallback
- **Karte ins Deck**: DELETE `incubator`
- **Level-Up-Ei**: PATCH `profiles.eggs` via `saveEggProfile()`
- **Duplikat verkaufen**: `sell_card(p_card_id)` RPC (atomar: DELETE `user_cards` + UPDATE `profiles.diamonds`); nur möglich wenn `count > 1`; Belohnung: common 2 / rare 4 / epic 6 / legendary 8 / mystic 10 💎

---

## Siehe auch

- [[Lernkalender/README|Lernkalender]] — liest `pomodoro_sessions` für sein Statistik-Overlay und erkennt die `pomo_session` wieder
- [[FocusFM/README|FocusFM]] — eigenständiges Projekt, nutzt ebenfalls die [[Web Audio API]] für synthetisierten Sound
- [[Dashboard/README|Dashboard]] — verlinkt auf die online gehostete Pomodoro-Seite (`ragnarg-0.github.io/Pomodoro`)
