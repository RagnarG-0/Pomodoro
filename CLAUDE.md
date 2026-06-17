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
| `profiles` | username, public, avatar_url, diamonds, eggs, clan_id, clan_role, focus_min, short_min, long_min, long_after, display_unit, off_weekdays, sound |
| `study_days` | user_id, date, minutes, off |
| `pomodoro_sessions` | user_id, date, label, duration_minutes |
| `timer_state` | user_id, end_at, total_sec, mode, paused_remaining, pomoday |
| `incubator` | user_id (PK), egg_color char(1), placed_at, focus_minutes_at_placement |
| `cards` | id int (PK), name, rarity |
| `user_cards` | id uuid (PK), user_id, card_id, obtained_at |
| `clans` | id, name, leader_id, min_focus_min, max_focus_min, level_config (JSONB), created_at |
| `clan_requests` | id, clan_id, user_id, status (`pending`/`accepted`/`rejected`), created_at |

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
| `pomo_label_stats_<userId>` | Label-Stats-Array | 5 min |
| `pomo_egg_preview` | `'1'` wenn Clan-Leader den Placeholder deaktiviert hat | — |
| `pomo_export_last_<userId>` | Zeitstempel des letzten CSV-Exports (Cooldown) | 12h |

---

## UI-Karten (von oben nach unten)

1. **Timer-Card** — Analog-Uhr SVG, Modi (Fokus/Kurze Pause/Lange Pause), Label-Input mit Dropdown, +5min, „✓ Jetzt"-Button (frühzeitiger Abschluss), Confetti bei Abschluss
2. **Heatmap-Card** — 100-Tage-Grid, scrollbar, Klick = Off-Day togglen, DOW-Labels links
3. **Stats-Card** — Level (25 Stufen), Streak, Bester Tag, Wochenschnitt; „mehr Infos" öffnet Label-Stats-Overlay (inset, gleiche Card)
4. **Ei-Box** (`#eggBox`) — Diamanten-Anzeige, Brutkasten (1 Slot), -1h/Skip-Buttons, aufklappbares 10-Slot-Inventar; hinter Placeholder versteckt (`#egg-placeholder-overlay`)
5. **Deck-Box** (`#deckBox`) — aufklappbares Karten-Grid, nach Rarität sortiert, Stapel-Optik bei Duplikaten; hinter demselben Placeholder
6. **Leaderboard-Card** — nur sichtbar wenn `userPublic === true && clanRole != null`; Tabs: Heute/Letzte Woche/Letzter Monat/All Time; Tagessieger-Highlight = goldener Border; Live-Timer-Dot (grün)

### Eier & Kartensammlung — Schlüsseldetails

- **Placeholder**: `#egg-placeholder-overlay` mit `backdrop-filter:blur(12px)` über `#egg-section-wrapper`. Clan-Leader kann via Settings-Toggle + `localStorage('pomo_egg_preview')` deaktivieren.
- **Bilder**: serviert via jsDelivr (`CDN`-Konstante). Eier: `CDN/Eier/<farbe>/Stadium_<1-4>.png`. Karten: `CDN/Karten/<rarität>/<name>.png`.
- **`draw_card()` RPC**: serverseitig, `SECURITY DEFINER`, schreibt in `user_cards` und gibt `card_id` zurück. Client schlägt Karte in `CARD_CATALOG` nach.
- **`bonusMin`**: lokales Offset auf `focus_minutes_at_placement` für optimistische -1h/Skip-Updates. Wird nach Supabase-Write auf 0 normalisiert.

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

| Level | Name (Default) | Icon | Ab (Min) |
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

Level-Up → `awardEgg()` (zufällige Farbe in ersten freien Slot; bei vollem Inventar wird ältestes Ei ersetzt).

---

## Karten-Katalog (32 Karten)

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
- `finishEarly()` überschreibt `totalSec` mit der verstrichenen Zeit **abgerundet auf volle Minuten** (`Math.floor(elapsedSec / 60) * 60`), bevor `completePomo()` aufgerufen wird — so werden keine Sekunden in Supabase gespeichert
- `showTimerConfirmBanner(msg, onYes)` ist ein wiederverwendbares Bestätigungs-Modal (`#timer-confirm-banner`); Buttons werden per `cloneNode` ausgetauscht, um Event-Listener-Leaks zu vermeiden

### Bestätigungs-Dialoge (Timer-Card)
- **Reset im Fokus-Modus** (nur wenn `running`): zeigt Bestätigungs-Banner vor `reset()`
- **„✓ Jetzt"-Button**: erscheint bei `mode === 'work' && running && elapsedSec >= 60` (ab der ersten vollen Minute); Bestätigungs-Banner vor `finishEarly()`

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
