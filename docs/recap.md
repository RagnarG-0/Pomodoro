# M2-Recap — Details

Vertiefung zu [[CLAUDE.md]] → `## M2-Recap`. Overlay `#recapOverlay`, Button `#recap-open-btn` (Stats-Card-Kopfzeile).

## Überblick

Einmaliger „Wrapped"-Rückblick zum M2: Story-Overlay im 4:3-Format (1024×768, per `recapFit()` an die Fenstergröße skaliert) mit bis zu 8 Screens: Danke → Lernzeit → Rekorde → Streak → Level → Karten → Clan/Treppchen → Zusammenfassung mit „Speichern" (PDF-Urkunde via jsPDF, erst beim Klick von jsDelivr geladen — cdnjs wäre durch die CSP `script-src` blockiert) und „Weiter". Design-Vorlage war `recap-mock.html` (abgenommen 24.09.2026).

## Datums-Gate (niemals vor dem 04.10.2026, 04:00 Uhr Berlin)

Zwei Stufen, beide müssen bestehen, fail-closed:

1. **Client** `recapActive()`: `todayKey() >= RECAP_START` (`'2026-10-04'`, gleiche 4-Uhr-Berlin-Tagesgrenze wie überall). Solange false: kein Overlay, kein Button, **kein einziger Request**.
2. **Server** `recapServerGate()` → RPC `recap_available()` (Migration `20260925000000_recap_available.sql`): `((now() at time zone 'Europe/Berlin') - interval '4 hours')::date >= '2026-10-04'`. Schützt gegen falsch vorgestellte Geräteuhren. Fehler/Timeout (8 s) → kein Recap. Nur ein `true` wird pro Seitenladung gecacht (`recapServerOk`).

Das Datum steht an genau zwei Stellen: `RECAP_START` (JS) und in der SQL-Funktion. Es gibt bewusst keinen URL-Parameter-/Debug-Bypass im deployten Code — getestet wird in einer lokalen Kopie mit überbrückten Gates.

## Ablauf

- `maybeShowRecap()` wird am Ende von `onLoginSuccess()` aufgerufen (nicht awaited): Client-Gate → `totalMin > 0` → Server-Gate → Button einblenden → falls noch nicht gesehen `showRecapNow(false)`.
- `showRecapNow()` lädt die Daten (`collectRecapData()`) und wartet (max. ~60 s), falls gerade `#level15Overlay`, `#hatchOverlay` oder `#timer-confirm-banner` offen ist.
- Seen-Flag `pomo_recap_m2_seen_v1_<userId>` (geräte-lokal) wird beim Schließen gesetzt (X, Esc, „Weiter"). Beim Logout wird ein offenes Recap ohne Seen-Flag geschlossen und der Button versteckt.
- Steuerung: Klick links (30 %) zurück / sonst weiter, ←/→, Esc, Leertaste = Pause, Auto-Weiter nach `RECAP_SLIDE_MS` (9 s). Der globale Leertasten-Timer-Handler ignoriert die Taste, solange das Recap offen ist.

## Datenquellen (`collectRecapData()`)

| Feld | Quelle |
|---|---|
| Lernzeit, Lerntage, erster Tag | `days` |
| Bester Tag | `computeBestDay()` |
| Beste Woche (Mo–So) / bester Monat | `computeBestPeriod('week'|'month')`, bei Gleichstand der jüngere |
| Längster Streak + Zeitraum | `computeLongestStreakRange()` (Semantik wie `computeLongestStreak()`, freie Tage zählen wie normale Tage); „läuft noch" = endet heute oder gestern bei heute 0 min |
| Level | `getCurrentLevel()` auf `activeLevels` (Clan-`level_config`, ohne Clan `DEFAULT_LEVELS`) |
| Karten | `eggDeck` (distinct) / `CARD_CATALOG.length`, Fächer per `pickFanCards()` (je Rarität eine zufällige eigene Karte) |
| Treppchen | `daily_winners?user_id=eq.<id>&select=rank` (offizielle Tagesplatzierungen, öffentlich lesbar) |
| All-Time-Platz | `leaderboard_aggregated('2000-01-01')` + `computeRanks()`, nur bei `userPublic && clanRole` |

Zeitangaben im Recap sind immer im Zeitformat (`recapFmtMin()`), unabhängig von `displayUnit`.

## Randfälle

- Keine Lernzeit → kein Recap, kein Button.
- Keine Karten → Karten-Screen entfällt.
- Weder All-Time-Platz noch Treppchen → Clan-Screen entfällt; nur eines von beiden → der Screen bzw. die Zusammenfassungs-Box zeigt nur diesen Teil. Progress-Segmente passen sich an (`--r-n`).
- < 5 Karten → Fächer wird von der Mitte aus belegt.
- Singular/Plural für Tag/Lerntag/Stunde/Minute.
- Urkunde: kein Emoji (Standard-PDF-Fonts), langer Name wird verkleinert, Box-Reihen zentriert bei 6–8 Kästen.

## CSS

Komplett unter `#recapOverlay` gescoped (inkl. generischer Klassen wie `.rise`/`.fade`/`.s1`–`.s8`), eigene Tokens `--r-*`, `z-index: 970` (über `#level15Overlay` 960). `#recapOverlay h1/h2` neutralisiert den globalen `h1`-Stil (uppercase/muted). `prefers-reduced-motion` schaltet alle Animationen ab.
