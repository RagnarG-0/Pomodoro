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
| `profiles` | username, public, avatar_url, diamonds, eggs, clan_id, clan_role, focus_min, short_min, daily_focus_goal_min, display_unit, off_weekdays, sound, second_incubator_purchased |
| `study_days` | user_id, date, minutes, off |
| `pomodoro_sessions` | user_id, date, label, duration_minutes |
| `timer_state` | user_id, end_at, total_sec, mode, paused_remaining, pomoday, limitless, started_at, credited_min, stash_total_sec, stash_paused_remaining, stash_limitless, stash_pomoday, stash_credited_min |
| `incubator` | user_id + slot_index (PK, slot_index ∈ {1,2}), egg_color char(1), placed_at, focus_minutes_at_placement |
| `cards` | id int (PK), name, rarity |
| `user_cards` | id uuid (PK), user_id, card_id, obtained_at |
| `clans` | id, name, leader_id, min_focus_min, max_focus_min, level_config (JSONB), created_at |
| `clan_requests` | id, clan_id, user_id, status (`pending`/`accepted`/`rejected`), created_at |
| `weekly_challenges` | challenge_key (PK), tier, metric_type, param_n, param_h, reward_diamonds, pool_index, label, active |
| `weekly_challenge_claims` | id uuid (PK), user_id, week_start, challenge_key, reward_diamonds (Snapshot), claimed_at |

`profiles.eggs` ist ein TEXT-String der Form `y-b-0-0-0-0-0-0-0-0` (10 Tokens, `-`-getrennt). Farb-IDs: `y/b/g/r`, `0` = leerer Slot.

`profiles.clan_role` ist `'leader'` | `'member'` | null.

`incubator` hat max. 2 Zeilen pro Nutzer (`slot_index` 1/2, PK ist das Paar) — Slot 2 nur nutzbar nach Kauf (`profiles.second_incubator_purchased`, ab Level 15, siehe „Zweiter Brutkasten"). Brut-Fortschritt je Slot = `sum(study_days.minutes) − focus_minutes_at_placement`, Ziel = 600.

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
challengesActiveTier // 'leicht' | 'mittel' | 'schwer' — aktiver Tab in der Wochen-Challenges-Karte
claimedChallengeKeys // Set<string> — bereits eingelöste challenge_keys der aktuellen Woche
newDesignOn   // boolean — Settings-Opt-in „Neues Design" (Bento-Grid ab Desktop-Breite), Default aus, geräte-lokal
focusModeOn   // boolean — Fokus-Modus (blendet alle Karten außer Timer aus), manuell + automatisch bei mode==='work'
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
- **Timer-Card-Anzeige**: statt der analogen Uhr (`updateWatch()`) zeigt `updateLimitlessTrack()` einen horizontalen Fortschrittsbalken (`#limitless-track-wrap`, Sibling von `.watch-wrap` in der Timer-Card, direkt über `#time-display`); `renderTimer()` togglet zwischen beiden über `showElapsed` (= `mode === 'work' && limitless`). Balkenlänge = Tagesziel (`dailyFocusGoalMin`) relativ zu 720 min (12h) verfügbarer Breite (`pxPerMin = #limitless-track-scroll.clientWidth / 720`) — bei 12h-Ziel volle Breite, bei 1h-Ziel 1/12 davon; `.limitless-track` ist per `margin:0 auto` zentriert, solange er schmaler als die Karte ist. Füllung = live „heute gelernte Minuten" (`(days[creditKey]||0) - limitlessCreditedMin + Math.floor(remaining/60)`, `creditKey = pomoDay || todayKey()`), aktualisiert bei jedem Tick über explizite Pixel-Breiten (nicht Prozent, da der Balken über das Ziel hinaus wachsen kann). Wird das Ziel erreicht, wechselt die Füllung dauerhaft auf einen umgekehrten Verlauf + Schimmer-Muster (`.over-goal`, bleibt für den Rest der Session so); wird es überschritten, wachsen Track und Füllung gemeinsam über die 12h-Referenzbreite hinaus weiter (kein Deckel) — `#limitless-track-scroll` erlaubt dafür horizontales Scrollen bei sehr langen Sessions. 20-Minuten-Checkpoints werden als Striche (`.limitless-track-tick`, „lit" sobald erreicht) auf dem Balken markiert; `_limitlessTickCount` cached die zuletzt gebaute Strich-Anzahl und verhindert unnötigen DOM-Neuaufbau bei unverändertem Etappen-Stand (Tick läuft alle 250ms). Kein PR-Marker mehr in dieser Bar-Visualisierung (bewusst entfernt, wirkte als Ablenkung) — die separate PR-Bruch-Push-Notification (siehe unten) ist davon unberührt und nutzt `computeBestDay()` weiterhin unabhängig
- **Tagesziel**: `dailyFocusGoalMin` (Minuten, 30–720, 5er-Schritte) bestimmt die Balkenlänge (s.o.). Settings-Row `#daily-goal-row` sichtbar nur wenn Limitless aktiv (`syncAutoBreaksVisibility()`, analog `#focus-interval-row`). Persistiert in `profiles.daily_focus_goal_min` (cross-device, Default `null` → Client fällt auf 240 zurück) — anders als `limitlessSetting`/`autoBreaksSetting`/`focusIntervalMin`, die geräte-lokal in `localStorage` liegen. Wird wie `focus_min`/`short_min` erst beim Klick auf „Speichern" übernommen (kein Live-Apply beim Tippen im Eingabefeld), aktualisiert den sichtbaren Balken danach aber sofort auch während der Timer läuft
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
| `pomo_new_design_v1` | `'1'`/`'0'` — Opt-in „Neues Design" (Bento-Grid ab Desktop-Breite), Default aus, geräte-lokal | — |
| `pomo_focus_mode_v1` | `'1'`/`'0'` — Fokus-Modus-Zustand, geräte-lokal | — |

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

### Bento-Grid-Layout (Desktop, Einstellungen-Opt-in)

Ab `min-width:1024px` können die 6 Karten statt im reinen vertikalen Stack in einem Bento-Grid angeordnet werden: Timer volle Breite oben, darunter Heatmap+Stats 50/50, darunter Wochen-Challenges (~40%) + Ei/Deck (~60%), darunter Leaderboard als eigene volle Reihe. Zentriert auf `max-width:900px`.

- **Opt-in, Default aus**: neue Settings-Checkbox „Neues Design (Beta)" (Sektion „Layout", zwischen „Anzeigeeinheit" und „Freie Wochentage"), `localStorage` Key `pomo_new_design_v1`, geräte-lokal. `newDesignOn`-Variable, `initNewDesignSetting()` (Muster wie `initLimitlessSetting()`) togglet `body.new-design`. Ohne diese Einstellung ist das Layout auch ab Desktop-Breite exakt wie vor diesem Feature — jederzeit über die Checkbox rückgängig machbar, falls das neue Layout Probleme macht.
- **DOM**: 3 neue IDs (`#timer-card`, `#heatmap-card`, `#stats-card`) plus 3 neue Wrapper-Divs `.bento-row.bento-row-main` (Heatmap+Stats), `.bento-row.bento-row-secondary` (Challenges-Card + `#egg-section-wrapper`, inkl. der dazwischenliegenden `position:fixed`-Overlays wie `#updateBannerOverlay` — deren Position im Baum ist irrelevant, `position:fixed` wird nie zum Flex-Item), `.bento-row.bento-row-leaderboard` (Leaderboard allein).
- **CSS**: `.bento-row { display:contents; }` als Default (mobil/Toggle-aus: pixelgleich zu vorher, kein eigener Layout-Effekt). Nur wenn **beides** zutrifft — `body.new-design` UND `@media(min-width:1024px)` — wird `.bento-row` zu `display:flex; width:100%; gap:1.25rem;`. `width:100%` ist hier nötig (wie bei `.header`/`.card`/`#egg-section-wrapper`), sonst gerät der Flex-Container ohne eigene Breite mit seinem `width:100%`-Kind in einen Shrink-to-fit-Zirkelbezug und wird zu schmal (`body`s `align-items:center` stretcht Top-Level-Kinder nicht). Ausgeblendete Kacheln (z. B. Challenges vor Login, Leaderboard ohne Public-Clan) erzeugen kein Flex-Item (`display:none`) — das verbleibende Geschwister füllt die Lücke automatisch, Leaderboard-Reihe kollabiert auf Höhe 0.
- Fokus-Intervall/Zoom-Details (Hero-Vergrößerung `#time-display`/`#watch-svg`) ebenfalls nur unter `body.new-design`.

### Fokus-Modus (Header-Button, unabhängig vom Bento-Grid-Toggle)

Neuer Header-Button `#focus-toggle-btn` (`.icon-btn`, gleiche Klasse wie `#gear-btn`, zwischen `#bell-wrap` und `#gear-btn`) blendet alle Karten außer der Timer-Card aus — für ablenkungsfreies Lernen. **Nicht** an den Bento-Grid-Toggle gekoppelt, immer verfügbar, unabhängig davon ob „Neues Design" aktiv ist.

- **State/Persistenz**: `focusModeOn`, `localStorage` Key `pomo_focus_mode_v1`, geräte-lokal. `setFocusMode(on)` / `applyFocusModeUI()` / `initFocusMode()`.
- **Aktivierung**: manuell per Klick jederzeit, **plus** automatisch bei jedem Eintritt in `mode==='work'` — zwei Hook-Punkte: (1) `switchTo(m, autoStart)` als erste Zeile (`if (m==='work') setFocusMode(true);`, deckt Mode-Button-Klick, Auto-Resume aus `workStash`, `skip()`, `onTimerEnd()`-Rücksprung ab), (2) `restoreTimerState()` — intern in `restoreTimerStateInner()` umbenannt, der äußere `restoreTimerState()`-Wrapper prüft in einem `finally`-Block nach dem `await` `if (mode==='work') setFocusMode(true);` (deckt die 4 Stellen ab, an denen die Funktion `mode` direkt setzt, ohne über `switchTo()` zu laufen — Seiten-Reload/Login auf zweitem Gerät während laufender Session).
- **Ausschalten passiert ausschließlich über den Button-Klick** — kein Code-Pfad ruft `setFocusMode(false)` sonst auf; auch während einer Pause bleibt ein manuell aktivierter Fokus-Modus an.
- **CSS**: `body.focus-mode` blendet `#heatmap-card`, `#stats-card`, `#challenges-card`, `#egg-section-wrapper`, `#leaderboard-card` per `!important` aus (überstimmt bestehende Ad-hoc-`style.display`-Zuweisungen an anderer Stelle im Code) und nullt `margin-bottom` der `.bento-row`-Wrapper. Gezielt die 5 Karten-IDs, nicht die Wrapper selbst — sonst würden auch darin verschachtelte Overlays (`#hatchOverlay` etc.) unterdrückt, falls während einer fokussierten Session ein Level-Up/Ei-Schlüpfen auftritt.

#### Fullscreen-Timer + Ring-Visualisierung

Im Fokus-Modus wird `#timer-card` zu einem echten Vollbild-Overlay (`position:fixed; inset:0`, `background:var(--bg)`, CSS-Grid mit `grid-template-areas`) — inkl. Header (Titel + alle Buttons außer `#focus-toggle-btn`, der per `position:fixed` oben rechts herausgelöst wird und der einzige Ausweg aus dem Vollbild bleibt). Funktioniert auf jeder Bildschirmgröße (`clamp()`/`vmin`-basierte Größen, kein separater Breakpoint), unabhängig vom Bento-Grid-Toggle — bei gleichzeitig aktivem `body.new-design` gewinnt die Fullscreen-Regel, weil sie im Stylesheet **nach** dem Bento-`@media`-Block steht (gleiche Spezifität, spätere Deklaration gewinnt).

- **Neuer Ring statt Analoguhr**: `#focus-ring-wrap`/`#focus-ring-svg`/`#focus-ring-arc` — ein 4. mutually-exclusive Visualisierungs-Element (analog zum bestehenden `watch-wrap`/`limitless-track-wrap`-Muster), nur im Fokus-Modus sichtbar. Dicker Ring (Radius 72 vs. 68 bei der kleinen Uhr), bewusst **ohne** Ticks/Zeiger — die normale Analoguhr bleibt für alle Nicht-Fokus-Fälle unverändert. `renderTimer()` schaltet jetzt 3-fach um (`watch-wrap` / `limitless-track-wrap` / `focus-ring-wrap`), gesteuert über `document.body.classList.contains('focus-mode')`.
- **Geteilte Fortschritts-Berechnung**: `currentProgressFrac()` (aus `updateWatch()` extrahiert) liefert den Bruch (0..1) für beide Timer-Untermodi (Countdown: `remaining/totalSec`; Limitless: Bruch zum nächsten 20-Min-Checkpoint) und wird von `updateWatch()` UND `updateFocusRing()` genutzt — nur die Bruch-*Berechnung* ist geteilt, die Zeiger-Winkel-Formeln der kleinen Uhr bleiben unverändert (bewusst nicht vereinheitlicht, da Countdown- und Limitless-Zweig unterschiedliche Winkel-Richtungssemantik haben). `CIRC_RING = 2*Math.PI*72` neben der bestehenden `CIRC`-Konstante.
- **Checkpoint-Ticks/Over-Goal-Färbung** aus `updateLimitlessTrack()` haben bewusst **kein** Ring-Äquivalent (v1) — würden die gewünschte Reduktion auf „ohne Zeiger/Ticks" wieder konterkarieren; `updateLimitlessTrack()` wird im Fokus-Modus schlicht nie aufgerufen.
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

### Level-15-Feier-Overlay

Beim erstmaligen Überschreiten der Level-15-Schwelle (`activeLevels[14]`, gleiche Schwelle wie „Zweiter Brutkasten") zeigt `celebrateLevel15()` (`#level15Overlay`) ein persönliches Feier-Bild als Full-Screen-Overlay: dreht sich ein (720°, Bounce-Scale), kommt zur Ruhe, danach Konfetti-Burst, bleibt stehen bis „Weiter" geklickt wird. Bild liegt relativ im Repo (`level15.jpg`, **nicht** über die `CDN`-jsDelivr-Konstante wie Eier/Karten — ein frisch gepushtes File auf `@main` kann dort bis zu 24h gecacht ausbleiben). Titel ist ein fest hinterlegter Text (kein `activeLevels[14].label`) — ein persönlicher Insider-Gag zu diesem einen Meilenstein, kein allgemeiner Level-Name.

- **Erkennung**: `crossedLevel15(lvlBefore, lvlAfter)` ist ein reiner Edge-Trigger, unabhängig vom generischen `awardEgg()`-Level-Up-Check daneben, aufgerufen an denselben 4 Level-Up-Stellen (`completePomo()`, `checkLimitlessCheckpoint()`, beide Zweige von `checkDayRollover()`). Da Fokusminuten nie sinken, feuert das garantiert nur einmal im Leben eines Accounts; bereits über Level 15 stehende Bestandsnutzer lösen es nie aus.
- **Animation**: Rotation (`.lvl15-frame-wrap`) und Scale-in-Bounce (`.lvl15-frame`) laufen bewusst als zwei getrennte CSS-Animationen auf zwei verschiedenen Elementen statt einem gemeinsamen Keyframe-Set für `rotate()+scale()` — Letzteres erzeugte einen sichtbaren Ruckler gegen Ende (die Easing-Kurve der Rotation kollidierte mit dem Scale-Bounce-Overshoot). Der Glow-Kreis dahinter ist radialsymmetrisch, seine Mitrotation fällt nicht auf.
- **Dismiss**: `cloneNode`/`replaceWith`-Muster (wie `showTimerConfirmBanner()`) verhindert Listener-Stacking.

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
| Zweiter Brutkasten (einmalig, ab Level 15) | 30 💎 |

Fehler-Banner bei zu wenig Diamanten: „Du bist wohl gesetzlich versichert. Verdiene mehr Diamanten und probiere es nochmal!"

### Zweiter Brutkasten

- Ab Level 15 (`hasReachedLevel15()`, index-basiert über `activeLevels[14].minMinutes` — robust gegen abweichend lange `clans.level_config`-Arrays) erscheint eine zweite Spalte (`#incubatorCol2`) neben dem bestehenden Brutkasten, per Kauf für 30 💎 dauerhaft freischaltbar (`buySecondIncubator()`, `profiles.second_incubator_purchased`). Bis Level 15 ist `#incubatorCol2` statisch `display:none` im Markup — keinerlei Layout-Unterschied für Nutzer unterhalb Level 15
- **Parametrisiert statt dupliziert**: `getEggProgress`, `renderIncubator`, `renderIncubatorButtons`, `startHatch`, `splitEgg` nehmen alle einen Slot-Parameter `n` (Default `1`, bestehende Aufrufe ohne Argument bleiben unverändert Slot 1). Der Zugriff auf den jeweiligen State läuft über `incData(n)` (`n===1 ? incubatorData : incubatorData2`). DOM-IDs sind für Slot 2 mit `2` suffixiert (`incubatorSlot2`, `btnMinus1h2`, `btnSkip2`, inkl. der dynamisch erzeugten `incEggWrap2` — wichtig, da zwei gleichzeitig schlüpfbereite Eier sonst um dieselbe ID kollidieren würden)
- **Bind-Funktionen statt Top-Level-Listener**: die −1h/Skip-Klick-Handler (`bindIncubatorButtons(n)`) und der Drag&Drop-Handler auf den Slot (`bindIncubatorDragDrop(n)`) werden je einmal für `n=1` und `n=2` aufgerufen. Alle Supabase-Schreibpfade auf `incubator` filtern zusätzlich auf `slot_index` (`&slot_index=eq.${n}` bei PATCH/DELETE, `slot_index: n` im Body + `?on_conflict=user_id,slot_index` beim Upsert) — sonst würden sich beide Slots gegenseitig überschreiben/löschen, da die PK jetzt `(user_id, slot_index)` ist
- **Gesperrter Zustand** (Level 15 erreicht, aber noch nicht gekauft): `.incubator-slot.locked` (opacity 0.42, kein Blur), großes 🔒 (34px) als eigene, nicht gedimmte Ebene zentriert über dem Slot (`.incubator-lock-layer`), keine −1h/Skip-Buttons (komplett ausgeblendet, nicht nur disabled), stattdessen eine schmale Pillen-Schaltfläche „+ 💎30" (`#btnUnlockIncubator2`). `updateSecondIncubatorVisibility()` steuert diesen Zustand (aufgerufen nach `loadEggData()` und an allen 4 Level-Up-Stellen, analog zu `if (incubatorData) renderIncubator();`)
- Nach dem Kauf verhält sich Slot 2 in jeder Hinsicht wie Slot 1 (Drag&Drop, −1h/Skip, Schlüpfen) — kein erneutes Level-Gating, `secondIncubatorUnlocked` ist permanent
- `eggHatchingSlot` merkt sich beim Schlüpfen, aus welchem Slot die gerade im Overlay gezeigte Karte stammt, damit der „In Deck legen"-Handler (`btnDeck`) die richtige `incubator`-Zeile löscht und den richtigen State (`incubatorData`/`incubatorData2`) leert

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
- **Zweiten Brutkasten kaufen**: PATCH `profiles` (diamonds + second_incubator_purchased)
- **-1h / Skip**: PATCH `incubator?user_id=eq.<id>&slot_index=eq.<n>` (focus_minutes_at_placement) + PATCH `profiles` (diamonds); normalisiert lokales `bonusMin` auf 0
- **Drag & Drop → Brutkasten**: POST-Upsert `incubator` (Body inkl. `slot_index`, `?on_conflict=user_id,slot_index`) + PATCH `profiles.eggs`
- **Schlüpfen**: `draw_card()` RPC (serverseitig) → INSERT `user_cards`; bei Fehler lokaler Fallback
- **Karte ins Deck**: DELETE `incubator?user_id=eq.<id>&slot_index=eq.<n>` (nur die Zeile des Slots, aus dem geschlüpft wurde)
- **Level-Up-Ei**: PATCH `profiles.eggs` via `saveEggProfile()`
- **Duplikat verkaufen**: `sell_card(p_card_id)` RPC (atomar: DELETE `user_cards` + UPDATE `profiles.diamonds`); nur möglich wenn `count > 1`; Belohnung: common 2 / rare 4 / epic 6 / legendary 8 / mystic 10 💎

---

## Siehe auch

- [[Lernkalender/README|Lernkalender]] — liest `pomodoro_sessions` für sein Statistik-Overlay und erkennt die `pomo_session` wieder
- [[FocusFM/README|FocusFM]] — eigenständiges Projekt, nutzt ebenfalls die [[Web Audio API]] für synthetisierten Sound
- [[Dashboard/README|Dashboard]] — verlinkt auf die online gehostete Pomodoro-Seite (`ragnarg-0.github.io/Pomodoro`)
