// scrape-mensa-menu: Holt den heutigen Speiseplan von 4 Mensen des
// Studentenwerks Halle über das Drittanbieter-Portal meine-mensa.de (kein
// offizielles API — die Studentenwerk-Halle-Seite selbst bettet dieses
// iframe ein, siehe docs/mensa.md) und schreibt ihn nach
// public.mensa_menu_items (via replace_mensa_menu() RPC).
//
// Wird täglich per pg_cron + pg_net getriggert (siehe
// supabase/migrations/20260911000030_mensa_scrape_cron.sql). Kann auch
// manuell getestet werden:
//   curl -i -X POST "<SUPABASE_URL>/functions/v1/scrape-mensa-menu" \
//     -H "Authorization: Bearer <SERVICE_ROLE_KEY>"
//
// Erste Edge Function in diesem Projekt — siehe CLAUDE.md/docs/mensa.md.

import { DOMParser, Element } from "https://deno.land/x/deno_dom@v0.1.45/deno-dom-wasm.ts";

const MEINE_MENSA_URL = "https://meine-mensa.de/speiseplan_iframe";

// meine-mensa.de location_ids der 4 gewünschten Mensen (per curl gegen die
// echte Seite ermittelt, siehe docs/mensa.md).
const MENSA_LOCATION_IDS: Record<string, number> = {
  harzmensa: 3,
  neuwerk: 9,
  tulpe: 10,
  franckesche: 14,
};

// Matching der <h5>Speiseplan <Name></h5>-Überschrift auf unseren internen
// Key — bewusst per Substring/Regex statt exaktem String-Vergleich, robuster
// gegen kleine Formulierungsänderungen der Fremdseite (z.B. Leerzeichen,
// "Mensa"-Präfix).
const H5_KEY_MATCH: [RegExp, string][] = [
  [/harzmensa/i, "harzmensa"],
  [/franckesche/i, "franckesche"],
  [/neuwerk/i, "neuwerk"],
  [/tulpe/i, "tulpe"],
];

interface ParsedDish {
  mensa_key: string;
  dish_name: string;
  price_student: number | null;
  price_staff: number | null;
  price_guest: number | null;
  badges: string[];
  allergen_codes: string[];
  sort_order: number;
}

// App-Tagesgrenze: 4 Uhr Berliner Zeit — identische Semantik zu todayKey()
// im Client bzw. ((now() AT TIME ZONE 'Europe/Berlin') - interval '4 hours')::date
// serverseitig (siehe get_mensa_checkins()). Implementiert ohne
// Drittbibliothek: Berlin-Wanduhrzeit als UTC-Werte konstruieren, 4h
// abziehen, Datumsteil nehmen — funktioniert unabhängig von der
// Server-Zeitzone der Function und ohne DST-Sonderfälle, da nur auf der
// bereits lokalisierten Wanduhrzeit gerechnet wird.
function todayKeyBerlin(): string {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: "Europe/Berlin",
    year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", second: "2-digit", hourCycle: "h23",
  }).formatToParts(new Date());
  const get = (t: string) => Number(parts.find((p) => p.type === t)!.value);
  const berlinAsUtc = new Date(Date.UTC(
    get("year"), get("month") - 1, get("day"),
    get("hour"), get("minute"), get("second"),
  ));
  berlinAsUtc.setUTCHours(berlinAsUtc.getUTCHours() - 4);
  return berlinAsUtc.toISOString().slice(0, 10);
}

// "3,40 / 6,30 / 8,40€" -> [3.4, 6.3, 8.4]. Fehlender/leerer Wert je Segment
// -> null (z.B. wenn eine Zielgruppe für ein Gericht keinen Preis hat).
function parsePrices(text: string | null | undefined): (number | null)[] {
  if (!text) return [null, null, null];
  return text.split("/").map((seg) => {
    const cleaned = seg.replace(/[€\s]/g, "").replace(",", ".");
    const n = parseFloat(cleaned);
    return Number.isFinite(n) ? n : null;
  });
}

// Zusatzstoffe/Allergene-Rohtext -> Codes-Array. Format:
// "Konservierungsstoffe (2), enthält Weizengluten (A1), enthält Milch
// (einschließlich Laktose) (F)" — pro Komma-Segment ist der Code die
// LETZTE Klammergruppe (wichtig bei verschachtelten Klammern wie beim
// Milch-Beispiel).
function parseAllergenCodes(text: string | null | undefined): string[] {
  if (!text) return [];
  const codes: string[] = [];
  for (const segment of text.split(",")) {
    const match = segment.trim().match(/\(([^()]*)\)\s*$/);
    if (match && match[1]) codes.push(match[1].trim());
  }
  return codes;
}

async function fetchMenuHtml(dateKey: string): Promise<string> {
  // Schritt 1: GET — liefert Session-Cookies + CSRF-Token, beides für den
  // folgenden POST nötig (Laravel-typisches Formular, kein JSON-API).
  const getRes = await fetch(MEINE_MENSA_URL);
  if (!getRes.ok) throw new Error(`GET ${MEINE_MENSA_URL} -> ${getRes.status}`);

  // Deno-Fetch: getSetCookie() liefert die einzelnen Set-Cookie-Header als
  // Array — NICHT headers.get('set-cookie') verwenden, das joint mehrere
  // Cookies fehlerhaft mit Komma zusammen und zerstört Attribute.
  const setCookies = typeof getRes.headers.getSetCookie === "function"
    ? getRes.headers.getSetCookie()
    : (getRes.headers.get("set-cookie") ? [getRes.headers.get("set-cookie")!] : []);
  const cookieHeader = setCookies.map((c) => c.split(";")[0]).join("; ");

  const getHtml = await getRes.text();
  const getDoc = new DOMParser().parseFromString(getHtml, "text/html");
  const csrfToken =
    getDoc?.querySelector('meta[name="csrf-token"]')?.getAttribute("content") ??
    getDoc?.querySelector('input[name="_token"]')?.getAttribute("value");
  if (!csrfToken) throw new Error("kein CSRF-Token in der GET-Antwort gefunden");

  // Schritt 2: POST — alle 4 location_ids in einem Request, week=0 +
  // explizites date liefert genau den einen gewünschten Tag statt der
  // ganzen Woche.
  const form = new URLSearchParams();
  form.set("_token", csrfToken);
  form.set("date", dateKey);
  form.set("week", "0");
  for (const id of Object.values(MENSA_LOCATION_IDS)) form.append("location_ids[]", String(id));

  const postRes = await fetch(MEINE_MENSA_URL, {
    method: "POST",
    headers: {
      "Content-Type": "application/x-www-form-urlencoded",
      "Cookie": cookieHeader,
    },
    body: form.toString(),
  });
  if (!postRes.ok) throw new Error(`POST ${MEINE_MENSA_URL} -> ${postRes.status}`);
  return await postRes.text();
}

function parseMenuHtml(html: string): ParsedDish[] {
  const doc = new DOMParser().parseFromString(html, "text/html");
  if (!doc) throw new Error("HTML-Parsing fehlgeschlagen (parseFromString gab null zurück)");

  const items: ParsedDish[] = [];
  // Jede Mensa ist ein eigener <div class="card mt-3">-Block mit einem
  // <h5>Speiseplan <Name></h5> im Header, gefolgt von <div class="card
  // food-container">-Elementen (ein Div pro Gericht) — bereits gegen die
  // echte Antwort verifiziert (siehe docs/mensa.md).
  const mensaBlocks = doc.querySelectorAll(".card.mt-3");
  for (const blockNode of mensaBlocks) {
    const block = blockNode as unknown as Element;
    const h5 = block.querySelector("h5");
    if (!h5) continue;
    const h5Text = h5.textContent || "";
    const match = H5_KEY_MATCH.find(([re]) => re.test(h5Text));
    if (!match) {
      console.warn("unbekannter Speiseplan-Titel, übersprungen:", h5Text.trim());
      continue;
    }
    const mensaKey = match[1];

    let sortOrder = 0;
    const dishNodes = block.querySelectorAll(".food-container");
    for (const dishNode of dishNodes) {
      const dish = dishNode as unknown as Element;
      const nameEl = dish.querySelector(".food_title");
      const dishName = nameEl?.textContent?.trim();
      if (!dishName) continue;

      const pricesText = dish.querySelector(".prices")?.textContent ?? null;
      const [priceStudent, priceStaff, priceGuest] = parsePrices(pricesText);

      const badges = Array.from(dish.querySelectorAll('img[data-toggle="tooltip"]'))
        .map((img) => (img as unknown as Element).getAttribute("title"))
        .filter((t): t is string => !!t);

      const allergenText = dish.querySelector(".collapse")?.textContent ?? null;
      const allergenCodes = parseAllergenCodes(allergenText);

      items.push({
        mensa_key: mensaKey,
        dish_name: dishName,
        price_student: priceStudent,
        price_staff: priceStaff,
        price_guest: priceGuest,
        badges,
        allergen_codes: allergenCodes,
        sort_order: sortOrder++,
      });
    }
  }
  return items;
}

async function writeMenu(dateKey: string, items: ParsedDish[]): Promise<void> {
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRoleKey) throw new Error("SUPABASE_URL/SUPABASE_SERVICE_ROLE_KEY fehlen in der Function-Umgebung");

  const res = await fetch(`${supabaseUrl}/rest/v1/rpc/replace_mensa_menu`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "apikey": serviceRoleKey,
      "Authorization": `Bearer ${serviceRoleKey}`,
    },
    body: JSON.stringify({ p_date: dateKey, p_items: items }),
  });
  if (!res.ok) throw new Error(`replace_mensa_menu fehlgeschlagen: ${res.status} ${await res.text()}`);
}

Deno.serve(async (_req: Request) => {
  try {
    const dateKey = todayKeyBerlin();
    const html = await fetchMenuHtml(dateKey);
    const items = parseMenuHtml(html);

    // Bei 0 geparsten Gerichten NICHT schreiben (verhindert, dass eine
    // Struktur-/Session-Änderung der Fremdseite den bestehenden Speiseplan
    // stillschweigend leert) — alter Stand bleibt stehen, der Client
    // erkennt ihn via date-Filter selbst als veraltet/"nicht verfügbar".
    if (items.length === 0) {
      throw new Error("0 Gerichte geparst — vermutlich Struktur-/Session-Fehler, breche ohne DB-Schreiben ab");
    }

    await writeMenu(dateKey, items);

    return new Response(JSON.stringify({ ok: true, date: dateKey, count: items.length }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  } catch (e) {
    console.error("scrape-mensa-menu error:", e);
    return new Response(JSON.stringify({ ok: false, error: String(e) }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
});
