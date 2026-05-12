# Pomodoro — Codebase Guide

## Architektur

Single-file PWA: `index.html` (~3400 Zeilen) + `sw.js`. Kein Build-System, kein Framework.
Backend: Supabase (Postgres + Auth + Storage).

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
| `profiles` | username, public, avatar_url, diamonds, awards_last, focus_min, short_min, long_min, long_after, display_unit, off_weekdays, sound |
| `study_days` | user_id, date, minutes, off |
| `pomodoro_sessions` | user_id, date, label, duration_minutes |
| `timer_state` | user_id, end_at, total_sec, mode, paused_remaining, pomoday |

### RPCs

| Funktion | Zweck |
|---|---|
| `add_study_minutes(p_date, p_minutes)` | Addiert Delta auf study_days (nicht idempotent!) |
| `get_label_stats(p_user_id)` | Gibt je Label: today_minutes, week_minutes, month_minutes, alltime_minutes |
| `leaderboard_today()` | Rangliste für heute |
| `leaderboard_aggregated(date_from)` | Rangliste ab Datum |
| `get_yesterday_winner()` | Name des gestrigen Tagesersten |

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
```

---

## Timer-Logik

- `tick()` läuft per `setInterval` (250ms), berechnet verbleibende Zeit aus `startedAt`
- `onTimerEnd()` — **async**, claimed die `timer_state`-Zeile via DELETE+`return=representation`
- Nur das Gerät, das die Zeile wirklich löscht (`deleted.length > 0`), ruft `completePomo()` auf → verhindert Doppel-Credits bei mehreren gleichzeitig offenen Tabs
- SW (`sw.js`) hält den Timer via `setTimeout` am Laufen wenn der Tab eingefroren ist, schickt `TIMER_DONE`-Message

### Timer State Persistence (Supabase)
- Laufender Timer: `end_at` gesetzt
- Pausierter Timer: `end_at = null`, `paused_remaining` gesetzt
- Bei Seitenaufruf: `restoreTimerState()` liest den State und setzt fort oder krediert abgelaufene Pomodoros

---

## Datenpfad bei Pomodoro-Abschluss

1. `completePomo()` schreibt `days[key] += mins` lokal
2. `addStudyMinutes(date, delta)` — RPC, addiert auf Supabase
3. `savePomoSession(date, mins, label)` — Insert in `pomodoro_sessions`
4. Caches für Label-Stats + Leaderboard werden **nicht** automatisch invalidiert — nur bei Force-Refresh oder TTL-Ablauf

---

## localStorage Keys

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
| `pomo_label_stats_<userId>` | Label-Stats-Array | 5 min |

---

## UI-Karten (von oben nach unten)

1. **Timer-Card** — Analog-Uhr SVG, Modi (Fokus/Kurze Pause/Lange Pause), Label-Input mit Dropdown, +5min, „✓ Jetzt"-Button (frühzeitiger Abschluss), Confetti bei Abschluss
2. **Heatmap-Card** — 100-Tage-Grid, scrollbar, Klick = Off-Day togglen, DOW-Labels links
3. **Stats-Card** — Level (25 Stufen), Streak, Bester Tag, Wochenschnitt; „mehr Infos" öffnet Label-Stats-Overlay (inset, gleiche Card)
4. **Leaderboard-Card** — nur sichtbar wenn `userPublic === true`; Tabs: Heute/Letzte Woche/Letzter Monat/All Time; Tagessieger-Highlight = goldener Border; Live-Timer-Dot (grün)

---

## Label-Stats Overlay

- Tabs: **Heute** (`today_minutes`) / **Monat** (`month_minutes`) / **Gesamt** (`alltime_minutes`)
- 2-Spalten-Tabelle + SVG-Pie-Chart
- Inline-Rename: PATCH auf `pomodoro_sessions` — wenn Ziel-Label bereits existiert → Merge-Dialog
- PIE_COLORS: 20 Grün-Töne (Array, Index = Rang)

---

## Tagesgrenze

Neuer Tag beginnt um **04:00 Uhr Berliner Zeit** (`todayKey()`).

---

## Sound Engine

Web Audio API, synthetisiert — kein externes Asset. Sounds: bell, ding, chime, soft, bowl, marimba, ping, harp, drum, none.

---

## Bekannte Designentscheidungen

- `add_study_minutes` ist nicht idempotent → nur über das Claim-Mutex in `clearTimerState` aufrufen
- Winner-Cache (`pomo_lb_winner`) ist bewusst vom Listen-Cache getrennt, damit ein fehlgeschlagener Winner-Fetch nicht die Liste blockiert
- `offWeekdays` speichert JS-Wochentagnummern (0=Sonntag), nicht ISO (1=Montag)
- `finishEarly()` überschreibt `totalSec` mit der tatsächlich verstrichenen Zeit, bevor `completePomo()` aufgerufen wird — so wird die reale Dauer gespeichert, nicht die geplante
- `showTimerConfirmBanner(msg, onYes)` ist ein wiederverwendbares Bestätigungs-Modal (`#timer-confirm-banner`); Buttons werden per `cloneNode` ausgetauscht, um Event-Listener-Leaks zu vermeiden

### Bestätigungs-Dialoge (Timer-Card)
- **Reset im Fokus-Modus** (nur wenn `running`): zeigt Bestätigungs-Banner vor `reset()`
- **„✓ Jetzt"-Button**: erscheint nur bei `mode === 'work' && running && elapsedSec >= 25*60`; Bestätigungs-Banner vor `finishEarly()`

---

## Clan-System (Phase 1 implementiert ✅)

### Datenbank ✅
- Tabelle `clans`: `id`, `name`, `leader_id`, `min_focus_min`, `max_focus_min`, `level_config`, `created_at`
- Tabelle `clan_requests`: `id`, `clan_id`, `user_id`, `status` (`pending`/`accepted`/`rejected`), `created_at`
- `profiles` erweitert um `clan_id` und `clan_role` (`'leader'`\|`'member'`\|null)
- RLS: `profiles_read_own` (eigenes Profil), `profiles_read_clan_peers` (via `my_clan_id()` SECURITY DEFINER)
- **Wichtig**: Subqueries in RLS-Policies auf `profiles` müssen SECURITY DEFINER-Funktionen nutzen, sonst rekursiver Loop → Profil nicht lesbar → Auto-Reset

### RPCs (deployed) ✅
| Funktion | Zweck |
|---|---|
| `respond_to_clan_request(p_request_id, p_accept)` | Leader bestätigt/lehnt Anfrage ab; updated profiles bei Accept |
| `remove_clan_member(p_user_id)` | Leader entfernt Mitglied (SECURITY DEFINER) |
| `submit_join_request()` | Neue Nutzer: findet Clan automatisch, legt pending request an |
| `get_clan_members()` | Gibt Mitglieder des eigenen Clans zurück (SECURITY DEFINER) |
| `my_clan_id()` | Hilfsfunktion für RLS-Policy (SECURITY DEFINER, kein direkter Aufruf) |

### UI ✅
- **Header**: Glocken-Icon (nur Leader) mit Badge + Dropdown für Beitrittsanfragen
- **Header**: „Clan"-Button (Nutzer ohne Clan) mit Dropdown zum Anfragen
- **Leaderboard**: nur sichtbar wenn `userPublic && clanRole` — neue unapproved Nutzer sehen es nicht
- **Leader-Einstellungen**: Min./Max. Fokuszeit + Mitgliederliste mit Entfernen-Button
- **Timer**: `+5 min` geclampt auf `clanMaxFocus`
- **Neue Nutzer**: `submitJoinRequest()` automatisch nach Registrierung

### Migration ✅
- Clan „Schwitzende Verbindung Halle" angelegt, Ragnar als Leader
- Alle `public = true` Profile direkt als Member eingetragen

### Ausstehend (Phase 2)
- Leaderboard-Tabs: Mein Clan / Global / Clan-Vergleich
- Level-Namen-Editor für Leader
- Registrierungsflow: Clan gründen / beitreten / überspringen

### Default Level-Namen
| Level | Name | Icon | Ab (Min) |
|---|---|---|---|
| 1 | Erkaltete Tastatur | 🧊 | 0 |
| 2 | Morgenmuffel | 🧊 | 300 |
| 3 | Notizzettelsammler | 🧊 | 600 |
| 4 | Koffeinabhängiger | 🧊 | 900 |
| 5 | Halbherziger Held | 🧊 | 1.500 |
| 6 | Sofagelehrter | 🛋️ | 2.100 |
| 7 | Bücherstapelturmer | 🛋️ | 3.000 |
| 8 | Pausensnacker | 🛋️ | 3.900 |
| 9 | Gemütlicher Grübler | 🛋️ | 4.800 |
| 10 | Pflichterfüller | 🛋️ | 6.000 |
| 11 | Entflammter | 🔥 | 7.800 |
| 12 | Nachtschwarmer | 🔥 | 9.600 |
| 13 | Karteikartenkönig | 🔥 | 12.000 |
| 14 | Zeitfresser | 🔥 | 14.400 |
| 15 | Leuchtendes Beispiel | 🔥 | 17.400 |
| 16 | Schreibtischkämpfer | 🦁 | 21.000 |
| 17 | Geduldiger Riese | 🦁 | 25.200 |
| 18 | Stirnrunzler | 🦁 | 30.000 |
| 19 | Schlafloser Denker | 🦁 | 35.400 |
| 20 | Unaufhaltsamer | 🦁 | 41.400 |
| 21 | Zeitsouverän | 👑 | 45.000 |
| 22 | Chronos-Bezwinger | 👑 | 49.200 |
| 23 | Erleuchteter | 👑 | 54.000 |
| 24 | Pomodoro-Legende | 👑 | 58.800 |
| 25 | Pomodoro-Gott | 👑 | 63.000 |
