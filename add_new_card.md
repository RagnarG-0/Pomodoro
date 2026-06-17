# Protokoll: Neue Karte hinzufügen

Wird verwendet, wenn ein neues Karten-Bild (PNG) zur Pomodoro-App hinzugefügt werden soll.

## Eingaben, die der Nutzer liefert

- Karten-Bild (PNG, z.B. via Pfad oder Anhang)
- Optional: gewünschte Rarität (`common` / `rare` / `epic` / `legendary` / `mystic`). Wenn nicht angegeben, anhand des Bild-Stylings/Inhalts einschätzen oder nachfragen.

## Schritte

1. **Nächste freie ID ermitteln**
   - `CARD_CATALOG` in `index.html` durchsuchen (`grep -n "CARD_CATALOG" index.html`), höchste vergebene ID + 1 nehmen.
   - Achtung: IDs können Lücken haben (z.B. wenn eine Karte nachträglich entfernt wurde) — die nächste ID ist also **nicht** automatisch "Anzahl Einträge + 1", sondern `max(id) + 1`.

2. **Kartenname festlegen**
   - Aus dem Bildtitel ableiten, deutsche Schreibweise, Bindestrich statt Leerzeichen wo es dem Stil bestehender Karten entspricht (z.B. `Gilbert-Syndrom`, `Juri-Gänger`, `Sono-Patient`). Leerzeichen sind technisch möglich (z.B. `Performative Male`), aber Bindestrich ist die Mehrheits-Konvention.
   - **Der Name muss exakt dem Dateinamen des Bildes entsprechen** (ohne `.png`) — der Client baut den Bildpfad als `${CDN}/Karten/${folder}/${name}.png`.

3. **Bild ablegen**
   - Datei nach `Karten/<rarity>/<Name>.png` kopieren (Ordnername = Rarität: `common`, `rare`, `epic`, `legendary`, `mystic`).
   - `cp "<Quellpfad>" "Karten/<rarity>/<Name>.png"`

4. **`CARD_CATALOG` in `index.html` ergänzen**
   - Neue Zeile am Ende des Arrays (vor `];`):
     ```js
     { id: <ID>, name:'<Name>', rarity:'<rarity>', folder:'<rarity>' },
     ```

5. **SQL-Insert für Supabase erstellen**
   - Neue Datei `supabase/add_cards_<YYYYMMDD>.sql` (heutiges Datum):
     ```sql
     -- Neue Karte (ID <ID>) einfügen
     INSERT INTO public.cards (id, name, rarity) VALUES
       (<ID>, '<Name>', '<rarity>')
     ON CONFLICT (id) DO NOTHING;
     ```
   - Diese Datei liegt **nicht** unter `supabase/migrations/` und wird nicht automatisch ausgeführt — der Nutzer führt sie manuell im Supabase SQL-Editor aus.

6. **`CLAUDE.md` aktualisieren**
   - Neue Zeile in der Tabelle unter "## Karten-Katalog" ergänzen: `| <ID> | <Name> | <rarity> |`
   - Kartenanzahl in der Überschrift (`## Karten-Katalog (N Karten)`) auf die neue Gesamtzahl korrigieren.

7. **Nicht automatisch committen/pushen** — nur wenn der Nutzer das explizit sagt.

## Ergebnis-Checkliste

- [ ] Bild liegt in `Karten/<rarity>/<Name>.png`
- [ ] Eintrag in `CARD_CATALOG` (`index.html`)
- [ ] `supabase/add_cards_<datum>.sql` erstellt (vom Nutzer noch manuell in Supabase auszuführen)
- [ ] `CLAUDE.md`-Tabelle + Kartenanzahl aktualisiert
