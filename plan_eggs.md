# Feature-Plan: Eier & Kartensammlung

---

## Status — Stand 2026-05-18

### Phase 1 — Datenbank ✅ FERTIG
Migration: `supabase/migrations/20260518000000_eggs_cards.sql` (im Supabase SQL Editor ausgeführt)

- `profiles.awards_last` gedroppt, `profiles.eggs TEXT DEFAULT '0-0-0-0-0-0-0-0-0-0'` hinzugefügt
- Tabellen `incubator`, `cards`, `user_cards` angelegt + RLS Policies
- 21 Karten in `cards` eingefügt
- RPC `draw_card()` implementiert (würfelt Rarität, wählt Karte, schreibt in `user_cards`, gibt `card_id` zurück)
- `leaderboard_today()` + `leaderboard_aggregated()` aktualisiert (`awards_last` aus Return-Signatur entfernt)

### Phase 2 — egg_test.html ✅ FERTIG
Anpassungen an `egg_test.html`:

- `EGG_COLORS` + `EGG_STAGES`: Schlüssel von `1/2/3/4` auf `y/b/g/r` umgestellt (= Produktionsformat aus `profiles.eggs`)
- `CARD_CATALOG`: `rarity`-Feld hinzugefügt (nötig für Lookup nach `card_id` vom RPC)
- Initiales Inventar + `buyEgg` verwenden Buchstaben-Farb-IDs
- Fallback in `eggSprite` korrigiert

### Noch offen: Phase 3 — index.html Integration (geplant für heute Nacht)

### Fertig (Testprototyp `egg_test.html`)

**Ei-System:**
- 4 Ei-Farben (gelb, blau, grün, rot) mit je 4 Stadium-PNGs aus `Eier/<farbe>/`
- Stadien: 0 = heil, 1 = erster Riss, 2 = große Risse, 3 = geschlüpft
- Anzeigebreite wächst mit dem Stadium (`STAGE_SCALE = [1.0, 1.02, 1.08, 1.25]`)
- Drag & Drop aus Inventar in den Brutkasten (1 Slot)
- Beim Ablegen werden alle 4 Stadium-Bilder sofort per `preloadEggStages()` vorgeladen
- Fortschrittsbalken + Zeitanzeige
- Stadiumswechsel basiert auf Prozentsatz der Gesamtzeit (`getCrackStage`)
- Pulsierender Glow + „✨ Schlüpfbereit — klicken!" wenn fertig

**Schlüpf-Animation:**
- Ei wackelt (`shake`-Keyframe, 480 ms)
- 8–12 Schalensplitter fliegen mit zufälligem Winkel/Rotation heraus
- Zwei gezackte Hälften (`clip-path` Zickzack) fliegen nach links/rechts oben
- Nach 540 ms: Karte wird gezogen, Overlay erscheint

**Karten-System (clientseitig, Testmodus):**
- 5 Raritäten mit Zieh-Wahrscheinlichkeit und Ordner-Mapping:

| Rarität   | Ordner      | Zieh-Chance |
|-----------|-------------|-------------|
| Normal    | `common`    | 40 %        |
| Selten    | `rare`      | 30 %        |
| Episch    | `epic`      | 18 %        |
| Legendär  | `legendary` | 9 %         |
| Mystisch  | `mystic`    | 3 %         |

- 21 Karten total in `Karten/<rarität>/` (PNG-Dateien, bereinigt)
- Kartenname wird nirgends angezeigt (nur Bild + Rarität-Badge)

**Schlüpf-Overlay:**
- Karte groß angezeigt (`min(82vw, 380px) × min(80vh, 530px)`)
- Rarität-Badge (Mystisch: Shimmer-Animation)
- Button „In Deck legen" mit Fly-Animation zur Deck-Box

**Deck-Box:**
- Aufklappbar, nach Rarität sortiert (seltenste zuerst)
- Stapel-Optik bei Duplikaten (`::before`/`::after`), Badge `×N`
- Karten zeigen echtes Bild, kein Dateiname
- Klick auf Deck-Karte → Ansichts-Overlay (schließt per Klick)

---

## Architektur

### Karten-Bilder
- **Lokal** in `Karten/<rarität>/<name>.png` (Entwicklung + aktueller Testprototyp)
- **Produktion:** GitHub-Repo, serviert über jsDelivr
  - URL-Muster: `https://cdn.jsdelivr.net/gh/<user>/<repo>@main/Karten/<rarität>/<name>.png`
- Kein Supabase Storage — nur IDs auf dem Server

### Karten-Katalog (Client)
- `CARD_CATALOG` hardcoded im JS: Array von `{ id, name, rarity, folder }`
- Client baut Bildpfad aus `folder` + `name` — kein Netzwerkaufruf für den Katalog
- Kein localStorage-Cache nötig (Katalog ist Teil des Bundles)

### Draw-Logik (serverseitig via Supabase RPC)
`draw_card()` (Postgres-Funktion, aufgerufen vom Client nach dem Schlüpfen):
1. Rarität würfeln (`random()` gegen kumulative Schwellen)
2. Zufällige Karte aus `cards` dieser Rarität wählen
3. In `user_cards` inserieren (`user_id`, `card_id`, `obtained_at`)
4. `card_id` zurückgeben → Client schlägt Name + Ordner im `CARD_CATALOG` nach

### Ei-Inventar (Server)
- Gespeichert als TEXT-Spalte `eggs` in `profiles`
- Format: 10 Tokens, getrennt durch `-`, z.B. `b-b-g-y-0-0-0-0-0-0`
- Farb-IDs: `y` = gelb, `b` = blau, `g` = grün, `r` = rot, `0` = leer
- Maximale Kapazität: 10 Slots
- Kein Bild auf Supabase — Client leitet Bildpfad aus Farb-ID ab

### Brutkasten (Server)
- 1 Slot pro Nutzer, Tabelle `incubator`
- Fortschritt = Fokus-Minuten, **nicht** Echtzeit
- Wird nur nach `completePomo()` aktualisiert (kein paralleler Timer)

---

## Karten-Katalog (21 Karten)

| ID | Name                    | Rarität     | Ordner      |
|----|-------------------------|-------------|-------------|
|  1 | FSr-Mitglied            | common      | common      |
|  2 | Glutenboykottierer      | common      | common      |
|  3 | Histotutor              | common      | common      |
|  4 | M1Schwitzer             | common      | common      |
|  5 | Skillslabschauspieler   | common      | common      |
|  6 | Soziologiestudent-in    | common      | common      |
|  7 | Warmduscher             | common      | common      |
|  8 | Anki-Controler-User     | rare        | rare        |
|  9 | Biochemietrader         | rare        | rare        |
| 10 | Mensafrau               | rare        | rare        |
| 11 | Schwesterrabiata        | rare        | rare        |
| 12 | gym10duscher            | rare        | rare        |
| 13 | Medienny                | epic        | epic        |
| 14 | STHebungsüberseher      | epic        | epic        |
| 15 | TomS                    | epic        | epic        |
| 16 | Bibliothek-Schläfer     | legendary   | legendary   |
| 17 | FreundausHarvard        | legendary   | legendary   |
| 18 | glasn                   | legendary   | legendary   |
| 19 | Mediraggy               | legendary   | legendary   |
| 20 | Neurotutor              | legendary   | legendary   |
| 21 | Penig-BG                | mystic      | mystic      |

---

## Datenbankschema (Supabase)

### `profiles` (Änderungen an bestehender Tabelle)
```sql
ALTER TABLE profiles DROP COLUMN awards_last;
ALTER TABLE profiles ADD COLUMN eggs TEXT NOT NULL DEFAULT '0-0-0-0-0-0-0-0-0-0';
```

### Neue Tabelle: `incubator`
```
user_id                     uuid PK+FK → profiles
egg_color                   char(1)       -- 'y' | 'b' | 'g' | 'r'
placed_at                   timestamptz
focus_minutes_at_placement  int           -- Snapshot von sum(study_days.minutes)
```
- `user_id` ist gleichzeitig PK → maximal 1 Zeile pro Nutzer
- Fortschritt = `current_total_focus_min − focus_minutes_at_placement`, Ziel = 600

### Neue Tabelle: `cards`
```
id      int  PK
name    text
rarity  text  -- 'common' | 'rare' | 'epic' | 'legendary' | 'mystic'
```
21 Zeilen, befüllt per INSERT (s. Karten-Katalog oben).

### Neue Tabelle: `user_cards`
```
id           uuid PK default gen_random_uuid()
user_id      uuid FK → profiles
card_id      int  FK → cards
obtained_at  timestamptz default now()
```
Duplikate = mehrere Zeilen. Stapelgröße = COUNT(*) GROUP BY card_id.

---

## Diamanten-System (Erweiterung)

Bestehende Spalte `profiles.diamonds` wird zur Währung.

| Transaktion              | Kosten         | Bedingung                         |
|--------------------------|----------------|-----------------------------------|
| Neues Ei kaufen          | 12 Diamanten   | Freier Slot vorhanden             |
| Brutzeit −1h             | 1 Diamant      | Ei im Brutkasten, Zeit verbleibt  |
| Brutzeit überspringen    | ⌈h_verbleibend⌉ Diamanten | Ausreichend Diamanten  |

**Fehler-Banner bei zu wenig Diamanten:**
> „Du bist wohl gesetzlich versichert. Verdiene mehr Diamanten und probiere es nochmal!"

### Diamanten-Anzeige
- **Entfernt:** Leaderboard (alle Perioden)
- **Neu:** Oben rechts in der Ei-Box, nur für den eingeloggten Nutzer selbst sichtbar

---

## Ei-Box UI

```
┌─ Eier ──────────────────────── 💎 42 ─┐
│                                        │
│  [Brutkasten]                          │
│  Slot mit Ei + Fortschrittsbalken      │
│                                        │
│  [ -1h  💎1 ]  [ Überspringen 💎4 ]   │
│                                        │
│  Inventar (aufklappbar) ▼              │
│  [y][b][ + ][  +  ][ + ][ + ][ + ][ + ][ + ][ + ]  │
│       12💎  12💎  12💎  ...            │
└────────────────────────────────────────┘
```

- Freie Slots zeigen `+` mit `(12 💎)` darunter
- Klick auf `+` → Ei kaufen (zufällige Farbe)
- Aufklappbares Inventar (gleiche Mechanik wie Deck-Box)
- Level-Up vergibt weiterhin automatisch ein Ei (zufällige Farbe) in den ersten freien Slot; ist das Inventar voll, wird das älteste (linkeste) Ei ersetzt

---

## Brut-Fortschritt & Riss-Stufen

Brutzeit = **600 Fokusminuten** (10 Stunden)

| Fokusminuten  | Stadium | Bild         |
|---------------|---------|--------------|
| 0–209         | 0       | `Stadium_1`  |
| 210–419       | 1       | `Stadium_2`  |
| 420–599       | 2       | `Stadium_3`  |
| 600+          | Schlüpfbereit | Pulsieren |

Schwellen = `TOTAL_MIN * [0.35, 0.70, 1.0]`

### Brutzeit-Update-Logik (in `completePomo()`)
```
progress = sum(study_days.minutes) - focus_minutes_at_placement
remaining = max(0, 600 - progress)
if remaining === 0 → Ei ist schlüpfbereit (UI updaten)
```
Kein Real-Time-Countdown — nur Neuberechnung nach jedem abgeschlossenen Pomo.

### -1h Button
```
focus_minutes_at_placement -= 60   (UPDATE incubator)
profiles.diamonds -= 1             (UPDATE profiles)
```
Nur aktiv wenn: Ei im Brutkasten, verbleibende Zeit > 0, diamonds ≥ 1.

### Überspringen Button
```
hours_left = ceil(remaining / 60)
focus_minutes_at_placement = current_total - 600   (→ progress = 600)
profiles.diamonds -= hours_left
```
Nur aktiv wenn: Ei im Brutkasten, verbleibende Zeit > 0, diamonds ≥ hours_left.

---

## UI-Layout `index.html`

```
[Timer-Card]
[Heatmap-Card]
[Stats-Card]          ← awards_last (Klorollen) entfernt
[Ei-Box]              ← NEU (aufklappbar, Diamanten oben rechts)
[Deck-Box]            ← NEU (aufklappbar)
[Leaderboard-Card]    ← Diamanten-Spalte entfernt
```

---

## Implementierungsreihenfolge

### Phase 1 — Datenbank

1. **`profiles` migrieren**
   - `DROP COLUMN awards_last`
   - `ADD COLUMN eggs TEXT DEFAULT '0-0-0-0-0-0-0-0-0-0'`

2. **Tabellen anlegen:** `incubator`, `cards`, `user_cards` + RLS Policies
   - RLS: Nutzer liest/schreibt nur eigene Zeilen

3. **`cards` befüllen** — 21 INSERTs mit IDs 1–21

4. **RPC `draw_card()` schreiben** (Postgres-Funktion)
   - Input: `p_user_id uuid`
   - Rarität würfeln, Karte wählen, in `user_cards` inserieren, `card_id` zurückgeben

### Phase 2 — egg_test.html anpassen

5. **`CARD_CATALOG`** im JS ergänzen (21 Einträge mit `id`, `name`, `rarity`, `folder`)

6. **Ei-Inventar auf 10 Slots** erweitern + aufklappbar machen (analog Deck-Box)

7. **Plus-Symbol** für freie Slots: Ei kaufen für 12 Diamanten
   - Fehler-Banner bei zu wenig Diamanten

8. **Brutkasten-Buttons** `-1h` und `Überspringen` inkl. Diamanten-Abzug

9. **Brutzeit-Logik** auf Fokusminuten umstellen (kein `setInterval` für Fortschritt)

### Phase 3 — index.html Integration

10. **`awards_last` entfernen** — in `index.html` nach `awards_last` suchen und alle Referenzen löschen
    - `profiles`-SELECT (wo wird awards_last gelesen?)
    - Stats-Card UI (Klorollen-Darstellung)
    - Leaderboard-Rendering (`awards_last`-Spalte aus Tabelle)
    - Leaderboard-RPCs geben `awards_last` nicht mehr zurück (bereits in Phase 1 geändert)

11. **Diamanten** aus Leaderboard-Tabelle entfernen
    - `leaderboard_today()` + `leaderboard_aggregated()` geben `diamonds` noch zurück — im Rendering einfach ignorieren

12. **Ei-Box + Deck-Box HTML + CSS** aus `egg_test.html` in `index.html` einfügen
    - Position: nach Stats-Card, vor Leaderboard-Card
    - CSS: kompletter `<style>`-Block aus egg_test.html (ohne `:root`/`body`-Overrides)
    - HTML: `#eggBox` + `#deckBox` + `#hatchOverlay` + `#cardViewOverlay` + `#diamondBanner`

13. **JS aus egg_test.html übertragen** — alle Konstanten + Funktionen in die IIFE von index.html
    - Konstanten: `EGG_COLORS`, `EGG_STAGES`, `CARD_CATALOG`, `RARITIES`, `STAGE_SCALE`, `BREAK_L/R`
    - Globale Vars: `inventory`, `incubatorData` (umbenannt von `incubatorEgg`), `deck`, `deckOpen`, `invOpen`
    - Funktionen: alle render*/buy/toggle/hatch/split/spawn/roll/show-Funktionen

14. **Diamanten-Anzeige** aus `profiles.diamonds` befüllen
    - In `loadProfile()` (oder wo Profil geladen wird): `diamonds`-Wert in `#diamondDisplay` setzen

15. **Ei-Inventar** beim Start aus `profiles.eggs` laden
    - `profiles.eggs` ist ein String `'y-b-0-0-...'` → splitten nach `-`
    - `0` = leerer Slot, Buchstabe = Ei mit dieser Farbe
    - Beim Ändern (Ei kaufen / in Brutkasten legen / Level-Up-Ei) → `UPDATE profiles SET eggs = ...`
    - Hilfsfunktion `eggsToString(inventory)` + `eggsFromString(str)` schreiben

16. **Brutkasten** beim Start aus `incubator`-Tabelle laden
    - `SELECT * FROM incubator WHERE user_id = auth.uid() LIMIT 1`
    - Wenn Zeile vorhanden: `incubatorData` setzen, UI rendern
    - Kein Timer — Fortschritt wird nach jedem `completePomo()` neu berechnet (s. Schritt 18)

17. **Deck** beim Start aus `user_cards` laden
    - `SELECT card_id, obtained_at FROM user_cards WHERE user_id = auth.uid() ORDER BY obtained_at`
    - Für jede `card_id` im `CARD_CATALOG` nachschlagen → `rarity`-Key holen → RARITIES-Objekt zuordnen
    - Nach Rarität sortiert aufbauen (seltenste zuerst)

18. **`completePomo()` erweitern**
    ```js
    // Nach add_study_minutes():
    if (incubatorData) {
      const totalFocusMin = Object.values(days).reduce((s, m) => s + m, 0);
      const progress = totalFocusMin - incubatorData.focus_minutes_at_placement;
      const remaining = Math.max(0, 600 - progress);
      if (remaining === 0) renderIncubator(); // zeigt "Schlüpfbereit"
      else renderIncubator();
    }
    // Level-Up-Check (bereits vorhanden) → bei Levelaufstieg: awardEgg()
    ```
    - `awardEgg()`: zufällige Farbe, in ersten freien Slot, `profiles.eggs` updaten; ist Inventar voll → ältestes (Index 0) ersetzen

19. **Schlüpf-Flow auf `draw_card()` RPC umstellen**
    - In `splitEgg()` statt `rollCard(rollRarity())`:
      ```js
      const { data: cardId } = await supabase.rpc('draw_card');
      const entry = CARD_CATALOG.find(c => c.id === cardId);
      const rarity = RARITIES.find(r => r.folder === entry.rarity);  // rarity-Key aus Katalog
      currentCard = { ...entry, src: encodeURI(`Karten/${entry.folder}/${entry.name}.png`), rarity };
      showHatchOverlay(currentCard);
      ```
    - `splitEgg` muss dafür `async` werden

20. **Ei kaufen** (Plus-Slot) — Supabase-Updates
    ```js
    // 1. diamonds prüfen
    // 2. UPDATE profiles SET diamonds = diamonds - 12, eggs = <neuer String>
    //    WHERE id = auth.uid() AND diamonds >= 12
    // 3. Lokalen State aktualisieren, UI rendern
    ```

21. **Brutkasten-Buttons** — Supabase-Updates
    - `-1h`: `UPDATE incubator SET focus_minutes_at_placement = focus_minutes_at_placement - 60 WHERE user_id = auth.uid()`
      + `UPDATE profiles SET diamonds = diamonds - 1 WHERE id = auth.uid() AND diamonds >= 1`
    - `Überspringen`: `UPDATE incubator SET focus_minutes_at_placement = <currentTotal - 600>`
      + `UPDATE profiles SET diamonds = diamonds - <cost>`
    - Jeweils lokalen State spiegeln + UI rendern

22. **Ei in Brutkasten legen** (Drag & Drop)
    - `INSERT INTO incubator (user_id, egg_color, placed_at, focus_minutes_at_placement)`
      mit `focus_minutes_at_placement = currentTotalFocusMin`
    - `profiles.eggs` updaten (Slot leeren)

23. **Nach Schlüpfen** (Karte ins Deck legen)
    - `DELETE FROM incubator WHERE user_id = auth.uid()`
    - Lokalen `incubatorData = null` setzen

### Phase 4 — Bilder & Deployment

20. **jsDelivr-URLs** für Kartenbilder einsetzen (wenn Repo public)

21. **Karten-Bilder auf GitHub** ablegen / sicherstellen dass Repo public ist

---

## Einmaliges Release-Script (nach Deployment von Phase 3)

Alle bestehenden Nutzer erhalten rückwirkend Eier für bereits erreichte Level.
**Formel:** `(aktuelles Level − 1)` Eier, da man mit Level 1 startet und erst ab Level 2 aufsteigt.

Die Level-Schwellen sind in `clans.level_config` als `minMinutes` hinterlegt (25 Stufen).
Der Client berechnet das Level als Index des höchsten überschrittenen `minMinutes`-Werts.

**SQL — einmalig im Supabase SQL Editor ausführen:**
```sql
-- Vergibt für jeden Nutzer (aktuelles_level - 1) Eier in profiles.eggs.
-- Eier werden zufällig in die ersten freien Slots geschrieben (max. 10).
-- Bereits belegte Slots (eggs != '0') werden nicht überschrieben.
-- Voraussetzung: profiles.eggs existiert (Phase 1 bereits migriert).

WITH level_thresholds AS (
  -- Fokusminuten-Schwellen aus level_config des Clans (sortiert aufsteigend)
  SELECT
    ordinality - 1 AS level_index,   -- Level 1 = Index 0, Level 2 = Index 1, ...
    (elem->>'minMinutes')::int AS min_minutes
  FROM clans,
  LATERAL jsonb_array_elements(level_config) WITH ORDINALITY AS t(elem, ordinality)
  LIMIT 1  -- nur ein Clan vorhanden
),
user_levels AS (
  SELECT
    p.id AS user_id,
    p.eggs,
    COALESCE(SUM(sd.minutes), 0)::int AS total_minutes,
    -- aktuelles Level = höchster Index mit min_minutes <= total_minutes
    COALESCE((
      SELECT MAX(lt.level_index)
      FROM level_thresholds lt
      WHERE lt.min_minutes <= COALESCE(SUM(sd.minutes), 0)
    ), 0) AS current_level
  FROM profiles p
  LEFT JOIN study_days sd ON sd.user_id = p.id
  GROUP BY p.id, p.eggs
),
eggs_to_award AS (
  SELECT
    user_id,
    eggs,
    GREATEST(current_level - 1, 0) AS egg_count  -- Level 1 → 0 Eier, Level 5 → 4 Eier, etc.
  FROM user_levels
  WHERE current_level >= 2  -- Level 1 bekommt keine Eier
)
-- Befüllt die ersten egg_count leeren Slots ('0') mit zufälligen Farben ('y','b','g','r').
-- Komplexe Slot-Befüllung muss als Skript außerhalb von SQL erfolgen (s.u.).
SELECT user_id, eggs, egg_count FROM eggs_to_award ORDER BY egg_count DESC;
```

Da die Slot-Befüllung (String-Manipulation von `y-b-0-0-...`) in reinem SQL aufwändig ist,
**alternativ als kurzes JS-Skript im Browser-Konsole** (einmalig, mit Service-Key oder als eingeloggter Leader):

```js
// Im Browser-Konsole auf der Pomodoro-Seite ausführen (einmalig nach Deployment)
const COLORS = ['y','b','g','r'];
const LEVEL_THRESHOLDS = [0,300,600,900,1500,2100,3000,3900,4800,6000,
  7800,9600,12000,14400,17400,21000,25200,30000,35400,41400,45000,49200,54000,58800,63000];

const { data: users } = await supabase
  .from('profiles')
  .select('id, eggs')
  .neq('eggs', null);

const { data: studyDays } = await supabase
  .from('study_days')
  .select('user_id, minutes');

for (const user of users) {
  const total = studyDays
    .filter(d => d.user_id === user.id)
    .reduce((s, d) => s + d.minutes, 0);
  const level = LEVEL_THRESHOLDS.filter(t => t <= total).length; // 1-basiert
  const eggsToAward = Math.max(level - 1, 0);
  if (eggsToAward === 0) continue;

  const slots = user.eggs.split('-');
  let awarded = 0;
  for (let i = 0; i < slots.length && awarded < eggsToAward; i++) {
    if (slots[i] === '0') {
      slots[i] = COLORS[Math.floor(Math.random() * 4)];
      awarded++;
    }
  }
  await supabase.from('profiles').update({ eggs: slots.join('-') }).eq('id', user.id);
  console.log(`${user.id}: Level ${level}, ${awarded} Eier vergeben → ${slots.join('-')}`);
}
console.log('Fertig.');
```
