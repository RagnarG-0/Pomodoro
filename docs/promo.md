# M2/Promo-Modus

Ein Apple-Segmented-Control in der Titelzeile (`#track-seg`) schaltet zwischen zwei Versionen der App um:

- **M2**: die ursprüngliche App, Daten in `public` (unverändert).
- **Promo** (Doktorarbeit): funktional eine 1:1-Kopie, aber mit komplett eigener, anfangs leerer Datenwelt: Lernzeit, Sessions/Labels, Timer, Statistiken/Level/Streak, Ranglisten, Rennstrecke, Wochen-Challenges/Boni, Diamanten, Eier, Brutkasten, Karten und Tauschbörse.

**Geteilt** zwischen beiden Modi: Account/Login, Profil-Identität (Name, Avatar, `public`), alle Einstellungen (Fokus-/Pausenlänge, Tagesziel, Sound, freie Wochentage, Bento-Layout, Rennauto), Clan und Mitgliedschaft (Promo-Ranglisten sind ebenfalls clan-gescoped), Kataloge (Karten, Challenges, Meilensteine, Perfekte-Woche-Wert), Mensa-/Bibliotheks-Check-in und das Admin-Flag. Der Lernkalender liest weiterhin nur M2 (`public.pomodoro_sessions`).

## Client

- **Modus-State**: `localStorage` `pomo_track_v1` (`'m2'` | `'promo'`, Default `m2`). Ein Inline-Script direkt nach `<body>` setzt `body[data-track]` vor dem ersten Paint (Hintergrund/Palette). In der IIFE liest `const TRACK` dieses Attribut.
- **Umschalten** (`initTrackSwitch()`): Schieber gleitet sofort, dann `promoAvailable()`-Vorab-Check (nur Richtung Promo), danach wird `body[data-track]` direkt umgesetzt (Palette/Hintergrund blenden über), Key gesetzt, Scroll-Position in `sessionStorage` (`pomo_track_scroll`) gemerkt und nach ~320 ms `location.reload()`. Die Sitzung (`pomo_session`) ist geteilt, `initAuth()` stellt sie per Refresh ohne Login-Dialog wieder her, `restoreTrackScroll()` springt zurück an die alte Position. Der globale State (`days`, Caches, Timer) wird so nie halb umgeschaltet. Bei laufendem oder angefangenem Timer (`running || hasProgress()`) ist das Umschalten gesperrt („Erst den laufenden Timer beenden“), sonst bliebe die `timer_state`-Zeile im alten Schema liegen.
- **Ausfallsicherheit**: Promo darf die Sitzung nie kaputt machen. `promoAvailable()` (`GET wallets?limit=1` mit `Accept-Profile: promo`) läuft vor dem Wechsel und beim Start im Promo-Modus (Anfang `initAuth()`); schlägt er fehl, fällt `fallBackToM2()` auf M2 zurück (Toast „Promo nicht erreichbar – zurück zu M2“ nach dem Reload). `loadProfileResult()` unterscheidet Request-Fehler (`ok:false`) von wirklich fehlendem Profil — nur Letzteres legt in `onLoginSuccess()` ein Ersatzprofil an; ein Fehler in Promo führt ebenfalls zu `fallBackToM2()`. (Ursprünglicher Bug: Schema noch nicht exposed → PGRST106 → `onLoginSuccess()` warf → Login-Dialog, wirkte wie Abmeldung.)
- **Schema-Wahl**: `schemaHeaders()` liefert in Promo `Accept-Profile: promo` und `Content-Profile: promo`, in M2 `{}` (Requests byte-identisch zu vorher). Die Funktion ist eingebaut in `authHeaders()`, `sbHeaders()` und die drei Stellen mit eigenen Headers (Rennstrecken-Claims, `leaderboard_today` der Rennstrecke, `loadLeaderboard()`). Tabellen- und RPC-Namen bleiben unverändert. **Neue `/rest/v1`-Calls immer über `authHeaders()` bauen**, sonst landen sie in Promo still in `public`. `/auth/v1` und `/storage/v1` bekommen keinen Profil-Header.
- **localStorage**: `trackKey(k)` hängt in Promo `__promo` an. Das gilt für alle datenbezogenen Caches und Queues: `pomo_heatmap_v3`, `pomo_labels_v1`, `pomo_current_label_v1`, `pomo_pending_credits`, `pomo_pending_stash_v1`, `pomo_pending_timer_state`, `pomo_lb_cache_*`, `pomo_lb_winner`, `pomo_lb_ranks_ref_*`/`_cur_*`, `pomo_label_stats_*` und `pomo_market_cache`. Einstellungen, Session und Design-Keys bleiben geteilt. Ein neuer datenbezogener Key muss ebenfalls durch `trackKey()`.
- **M2-only**: Der M2-Recap (`maybeShowRecap()`, Button „Recap ansehen“) erscheint nur bei `TRACK === 'm2'`. Die Level-15-Feier feuert in Promo erneut, sobald das Promo-Level 15 erreicht ist (eigene Lernzeit).
- **Design**: Jeder Modus hat einen eigenen Hintergrund und eine eigene Palette, jeweils hell/dunkel über `prefers-color-scheme` (Entwurf: Claude-Design „Pomodoro Hintergründe M2/Promo“).
  - M2: Punkteraster mit Smaragd-Schimmer und den bisherigen Farben.
  - Promo: liniertes Papier mit roter Randlinie und den Promotion-Dashboard-Farben „Warmes Papier/Salbeigrün“ (`body[data-track="promo"]` überschreibt `--bg`, `--surface*`, `--border*`, `--text*`, `--accent*`, `--ring-*`).
  - Gefüllte Buttons nutzen `--accent-fill`/`--on-accent` statt `--accent`/`#fff`, damit der Text in beiden Modi und Themes genug Kontrast hat.

## Datenbank: Schema `promo`

Migration `supabase/migrations/20261111000000_promo_schema.sql`. Sie wurde aus den Live-Definitionen von `public` generiert (Stand 2026-11-11) und ist rein additiv. Die einzige Berührung von `public` ist ein zusätzlicher Trigger auf `public.profiles`.

| Art | Objekte |
|---|---|
| Echte, leere Kopien (`LIKE … INCLUDING ALL`, gleiche Constraints/Indizes/RLS-Policies) | `study_days` (+ Trigger `study_days_audit`), `study_days_log`, `pomodoro_sessions`, `timer_state`, `pending_focus_sessions`, `tired_events`, `incubator`, `user_cards`, `card_listings`, `card_trades`, `trade_offers`, `trade_offer_cards`, `weekly_challenge_claims`, `streak_milestone_claims`, `perfect_week_claims`, `set_bonus_claims`, `race_checkpoint_claims`, `daily_winners` |
| Durchreichende Views (`security_invoker`, RLS der public-Tabelle gilt) | `cards`, `clans`, `clan_requests`, `weekly_challenges`, `streak_milestones`, `perfect_week_config`, `mensa_menu_items` |
| `promo.wallets` | `user_id` (PK → `public.profiles`), `diamonds`, `eggs`, `second_incubator_purchased`: das Promo-Gegenstück der Spielwelt-Spalten von `public.profiles`. Bestandsprofile wurden mit Defaults befüllt; neue Profile bekommen ihre Zeile per Trigger `profiles_ensure_promo_wallet` (AFTER INSERT auf `public.profiles`). |
| `promo.profiles` (View) | `public.profiles ⨝ promo.wallets` mit identischer Spaltenreihenfolge, die drei Spielwelt-Spalten kommen aus der Wallet. Schreibbar per INSTEAD-OF-Trigger `profiles_view_write` (INSERT/UPDATE, kein DELETE). Geteilte Spalten gehen nach `public.profiles` (Security Invoker, die RLS „nur eigenes Profil“ gilt weiter), die Spielwelt-Spalten in die Wallet. `diamonds` wird als Delta geschrieben, damit parallele `diamonds = diamonds + x` aus RPCs sich nicht überschreiben. |
| Funktionen | Alle public-RPCs außer `replace_mensa_menu` (nur Mensa-Scraper) als Kopie mit `SET search_path TO 'promo', 'public'`. Unqualifizierte Tabellennamen lösen dadurch auf promo auf, Identität und Clan über die Views. Explizite `public.`-Referenzen wurden zu `promo.` umgeschrieben. |
| pg_cron | `promo-reset-stale-work-sessions` (`*/5`), `promo-daily-winners` (`2-59/5`, schreibt Diamanten direkt in `promo.wallets`), `promo-cleanup-study-log` (stündlich) |

**Data-API**: `promo` muss als exposed schema freigegeben sein. Lokal steht das in `supabase/config.toml` `[api] schemas`, remote unter Dashboard → Project Settings → Data API → Exposed schemas.

**Achtung `supabase config push`**: pusht die *gesamte* `config.toml` ohne Rückfrage, auch `[auth]`. Die Auth-Werte in `config.toml` (`site_url`, `additional_redirect_urls`, `[auth.email] max_frequency`/`otp_length`, `[auth.mfa.totp]`) sind deshalb auf die Produktionswerte gesetzt; vorher immer `supabase config push` nur nach Diff-Kontrolle bzw. Exposed schemas lieber im Dashboard ändern.

### Wartungsregeln

- **Jede künftige Migration an einer gespiegelten Tabelle oder RPC muss im `promo`-Schema nachgezogen werden.** Das gilt für neue Spalten, geänderte Funktionen und neue RPCs. Sonst driftet Promo still weg oder bricht in Promo mit 404/400.
- **Neue Spalte auf `public.profiles`**: Die View `promo.profiles` expandiert ihre Spalten nur beim Anlegen. Also View und `profiles_view_write()` neu erzeugen (Spaltenliste + Defaults), sonst fehlt die Spalte in Promo.
- **Neue Tabelle**: Entscheiden, ob sie zur Datenwelt (Kopie in promo) oder zum geteilten Bereich (View in promo) gehört.
- Die Migration lässt sich mit dem Generator aus dem Live-Schema neu bauen. Er lag zur Entstehung nur im Scratchpad und ist nicht im Repo. Für spätere Änderungen deshalb gezielte Migrationen schreiben statt neu zu generieren.
