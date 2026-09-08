# Eier & Kartensammlung — Details

Vertiefung zu [[CLAUDE.md]] → `## UI-Karten` / `## Eier-System` / `## Karten-Katalog`.

### Eier & Kartensammlung — Schlüsseldetails

- **Placeholder**: `#egg-placeholder-overlay` mit `backdrop-filter:blur(12px)` über `#egg-section-wrapper`. Clan-Leader kann via Settings-Toggle + `localStorage('pomo_egg_preview')` deaktivieren.
- **Bilder**: serviert via jsDelivr (`CDN`-Konstante). Eier: `CDN/Eier/<farbe>/Stadium_<1-4>.png`. Karten: `CDN/Karten/<rarität>/<name>.png`.
- **`draw_card()` RPC**: serverseitig, `SECURITY DEFINER`, schreibt in `user_cards` und gibt `card_id` zurück. Client schlägt Karte in `CARD_CATALOG` nach.
- **`bonusMin`**: lokales Offset auf `focus_minutes_at_placement` für optimistische -1h/Skip-Updates. Wird nach Supabase-Write auf 0 normalisiert.


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
