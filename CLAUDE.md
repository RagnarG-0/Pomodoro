# Pomodoro — Codebase Guide

## Architektur

Single-file PWA: `index.html` (~4500 Zeilen) + `sw.js`. Kein Build-System, kein Framework.
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
| `profiles` | username, public, avatar_url, diamonds, eggs, focus_min, short_min, long_min, long_after, display_unit, off_weekdays, sound |
| `study_days` | user_id, date, minutes, off |
| `pomodoro_sessions` | user_id, date, label, duration_minutes |
| `timer_state` | user_id, end_at, total_sec, mode, paused_remaining, pomoday |
| `incubator` | user_id (PK), egg_color char(1), placed_at, focus_minutes_at_placement |
| `cards` | id int (PK), name, rarity |
| `user_cards` | id uuid (PK), user_id, card_id, obtained_at |

`profiles.eggs` ist ein TEXT-String der Form `y-b-0-0-0-0-0-0-0-0` (10 Tokens, `-`-getrennt). Farb-IDs: `y/b/g/r`, `0` = leerer Slot.

`incubator` hat max. 1 Zeile pro Nutzer. Brut-Fortschritt = `sum(study_days.minutes) − focus_minutes_at_placement`, Ziel = 600.

### RPCs

| Funktion | Zweck |
|---|---|
| `add_study_minutes(p_date, p_minutes)` | Addiert Delta auf study_days (nicht idempotent!) |
| `get_label_stats(p_user_id)` | Gibt je Label: today_minutes, week_minutes, month_minutes, alltime_minutes |
| `leaderboard_today()` | Rangliste für heute |
| `leaderboard_aggregated(date_from)` | Rangliste ab Datum |
| `get_yesterday_winner()` | Name des gestrigen Tagesersten |
| `draw_card()` | Würfelt Rarität (40/30/18/9/3 %), wählt Karte, schreibt in `user_cards`, gibt `card_id int` zurück |

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
5. Level-Up-Check: `getCurrentLevel()` vor/nach dem Eintrag vergleichen → `awardEgg()` bei Aufstieg
6. `renderIncubator()` — Brut-Fortschritt wird nach jedem Pomo neu berechnet (kein Timer)

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
| `pomo_egg_preview` | `'1'` wenn Clan-Leader den Placeholder deaktiviert hat | — |

---

## UI-Karten (von oben nach unten)

1. **Timer-Card** — Analog-Uhr SVG, Modi (Fokus/Kurze Pause/Lange Pause), Label-Input mit Dropdown, +5min, „✓ Jetzt"-Button (frühzeitiger Abschluss), Confetti bei Abschluss
2. **Heatmap-Card** — 100-Tage-Grid, scrollbar, Klick = Off-Day togglen, DOW-Labels links
3. **Stats-Card** — Level (25 Stufen), Streak, Bester Tag, Wochenschnitt; „mehr Infos" öffnet Label-Stats-Overlay (inset, gleiche Card)
4. **Ei-Box** (`#eggBox`) — Diamanten-Anzeige, Brutkasten (1 Slot), -1h/Skip-Buttons, aufklappbares 10-Slot-Inventar; hinter Placeholder versteckt (`#egg-placeholder-overlay`)
5. **Deck-Box** (`#deckBox`) — aufklappbares Karten-Grid, nach Rarität sortiert, Stapel-Optik bei Duplikaten; hinter demselben Placeholder
6. **Leaderboard-Card** — nur sichtbar wenn `userPublic === true`; Tabs: Heute/Letzte Woche/Letzter Monat/All Time; Tagessieger-Highlight = goldener Border; Live-Timer-Dot (grün)

### Eier & Kartensammlung — Schlüsseldetails

- **Placeholder**: `#egg-placeholder-overlay` mit `backdrop-filter:blur(12px)` über `#egg-section-wrapper`. Clan-Leader kann via Settings-Toggle + `localStorage('pomo_egg_preview')` deaktivieren.
- **Bilder**: serviert via jsDelivr (`CDN`-Konstante). Eier: `CDN/Eier/<farbe>/Stadium_<1-4>.png`. Karten: `CDN/Karten/<rarität>/<name>.png`.
- **`draw_card()` RPC**: serverseitig, `SECURITY DEFINER`, schreibt in `user_cards` und gibt `card_id` zurück. Client schlägt Karte in `CARD_CATALOG` nach.
- **`bonusMin`**: lokales Offset auf `focus_minutes_at_placement` für optimistische -1h/Skip-Updates. Wird nach Supabase-Write auf 0 normalisiert.

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

### Eier & Kartensammlung — Supabase-Schreibpfade
- **Ei kaufen**: PATCH `profiles` (diamonds + eggs)
- **-1h / Skip**: PATCH `incubator` (focus_minutes_at_placement) + PATCH `profiles` (diamonds); normalisiert lokales `bonusMin` auf 0
- **Drag & Drop → Brutkasten**: POST-Upsert `incubator` + PATCH `profiles.eggs`
- **Schlüpfen**: `draw_card()` RPC (serverseitig) → INSERT `user_cards`; bei Fehler lokaler Fallback
- **Karte ins Deck**: DELETE `incubator`
- **Level-Up-Ei**: PATCH `profiles.eggs` via `saveEggProfile()`