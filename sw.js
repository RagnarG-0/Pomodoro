// Pomodoro Service Worker — hält den Timer im Hintergrund am Laufen
// und sendet Benachrichtigungen auch wenn der Tab eingefroren ist.

const VERSION = 'pomo-sw-v1';

// ── Installation & Activation ──────────────────────────────────────────────
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));

// ── Timer state ────────────────────────────────────────────────────────────
let timerHandle = null;
let pendingMode = null;
let pendingAutoResume = false; // true, wenn die gerade endende Pause automatisch in den Fokus zurückführt (siehe onTimerDone)

function clearTimer() {
  if (timerHandle !== null) { clearTimeout(timerHandle); timerHandle = null; }
}

// ── Eye-break reminder (Limitless-Modus) ───────────────────────────────────
// Muss zu LIMITLESS_CHECKPOINT_SEC in index.html synchron bleiben (20 min).
const EYE_BREAK_INTERVAL_MS = 20 * 60 * 1000;
let eyeBreakHandle = null;
let eyeBreakStartedAt = null;

function clearEyeBreak() {
  if (eyeBreakHandle !== null) { clearTimeout(eyeBreakHandle); eyeBreakHandle = null; }
  eyeBreakStartedAt = null;
}

// ── PR-Bruch-Notification (Limitless-Modus) ────────────────────────────────
// One-shot, kein Selbst-Reschedule wie bei scheduleEyeBreak. crossAtMs wird
// clientseitig berechnet (index.html:schedulePRTargetIfPending) — der SW
// macht keine Datum/Zeitzonen-Arithmetik.
let prTargetHandle = null;

function clearPRTarget() {
  if (prTargetHandle !== null) { clearTimeout(prTargetHandle); prTargetHandle = null; }
}

function schedulePRTarget(crossAtMs, prMinutes) {
  clearPRTarget();
  const delay = crossAtMs - Date.now();
  if (delay < 0) return; // defensiv, sollte clientseitig nicht vorkommen
  prTargetHandle = setTimeout(() => onPRTarget(prMinutes), delay);
}

function onPRTarget(prMinutes) {
  prTargetHandle = null;
  self.registration.showNotification('🏆 Neuer Rekord!', {
    body: `Du hast deinen bisherigen Bestwert von ${prMinutes} Minuten überboten!`,
    icon: 'https://em-content.zobj.net/source/apple/391/tomato_1f345.png',
    tag: 'pomodoro-pr-broken',
    renotify: true,
    requireInteraction: false,
    silent: false,
  });
}

// ── Vergessene Limitless-Timer: 3h-Unbroken-Schwelle ───────────────────────
// One-shot wie PR-Target, kein Selbst-Reschedule. crossAtMs wird clientseitig
// berechnet (index.html:scheduleUnbrokenTargetIfPending). Zeigt nur eine
// Notification — die eigentliche Bestätigungslogik (Banner, Auto-Stop nach
// 2min) läuft in index.html (checkUnbrokenThreshold/triggerUnbrokenConfirm),
// sobald der Tab wieder im Vordergrund ist (Klick auf die Notification fokussiert ihn).
let unbrokenTargetHandle = null;

function clearUnbrokenTarget() {
  if (unbrokenTargetHandle !== null) { clearTimeout(unbrokenTargetHandle); unbrokenTargetHandle = null; }
}

function scheduleUnbrokenTarget(crossAtMs) {
  clearUnbrokenTarget();
  const delay = crossAtMs - Date.now();
  if (delay < 0) return; // defensiv, sollte clientseitig nicht vorkommen
  unbrokenTargetHandle = setTimeout(onUnbrokenTarget, delay);
}

function onUnbrokenTarget() {
  unbrokenTargetHandle = null;
  self.registration.showNotification('⏳ Bist du noch da?', {
    body: 'Dein Fokus-Timer läuft seit über 3 Stunden ohne Unterbrechung.',
    icon: 'https://em-content.zobj.net/source/apple/391/tomato_1f345.png',
    tag: 'pomodoro-unbroken-check',
    renotify: true,
    requireInteraction: false,
    silent: false,
  });
}

// ── Automatische Pausen (Limitless, Opt-in) ────────────────────────────────
// Rekurrierend wie Eye-Break (gleiches 20-Min-Intervall, Selbst-Reschedule),
// aber zusätzlich mit Client-Wake-Postmessage, damit auch ein eingefrorener
// Tab die eigentliche Pause-Umschaltung nachholen kann (index.html macht die
// State-Mutation selbst — der SW zeigt nur die Notification und weckt auf).
// Ersetzt EYE_BREAK_START beim Senden (index.html entscheidet), da eine
// echte 5-Minuten-Pause die 10-Sekunden-Wegschau-Erinnerung überflüssig macht.
let autoBreakHandle = null;
let autoBreakStartedAt = null;
let autoBreakIntervalMs = EYE_BREAK_INTERVAL_MS; // vom Client konfigurierbar (Fokus-Intervall, 20-120 min)

function clearAutoBreak() {
  if (autoBreakHandle !== null) { clearTimeout(autoBreakHandle); autoBreakHandle = null; }
  autoBreakStartedAt = null;
}

function scheduleAutoBreak(startedAt, intervalMs) {
  clearAutoBreak();
  autoBreakStartedAt = startedAt;
  autoBreakIntervalMs = intervalMs || EYE_BREAK_INTERVAL_MS;
  const elapsedMs = Date.now() - startedAt;
  const nextBoundaryMs = (Math.floor(elapsedMs / autoBreakIntervalMs) + 1) * autoBreakIntervalMs;
  const delay = startedAt + nextBoundaryMs - Date.now();
  autoBreakHandle = setTimeout(onAutoBreak, Math.max(0, delay));
}

async function onAutoBreak() {
  self.registration.showNotification('☕ Automatische Pause', {
    body: 'Dein Fokus-Timer pausiert für eine kurze Pause und läuft danach automatisch weiter.',
    icon: 'https://em-content.zobj.net/source/apple/391/tomato_1f345.png',
    tag: 'pomodoro-auto-break',
    renotify: true,
    requireInteraction: false,
    silent: false,
  });
  const clients = await self.clients.matchAll({ type: 'window' });
  for (const client of clients) client.postMessage({ type: 'AUTO_BREAK_TRIGGER' });
  if (autoBreakStartedAt !== null) scheduleAutoBreak(autoBreakStartedAt, autoBreakIntervalMs); // nächsten Zyklus planen
}

function scheduleEyeBreak(startedAt) {
  clearEyeBreak();
  eyeBreakStartedAt = startedAt;
  const elapsedMs = Date.now() - startedAt;
  const nextBoundaryMs = (Math.floor(elapsedMs / EYE_BREAK_INTERVAL_MS) + 1) * EYE_BREAK_INTERVAL_MS;
  const delay = startedAt + nextBoundaryMs - Date.now();
  eyeBreakHandle = setTimeout(onEyeBreak, Math.max(0, delay));
}

function onEyeBreak() {
  self.registration.showNotification('👀 Kurz wegschauen', {
    body: 'Schau 10 Sekunden vom Bildschirm weg, um deine Augen zu entlasten.',
    icon: 'https://em-content.zobj.net/source/apple/391/tomato_1f345.png',
    tag: 'pomodoro-eye-break',
    renotify: true,
    requireInteraction: false,
    silent: false,
  });
  if (eyeBreakStartedAt !== null) scheduleEyeBreak(eyeBreakStartedAt); // nächsten 20-min-Zyklus planen
}

async function onTimerDone() {
  let title, body;
  if (pendingMode === 'work') {
    title = '🍅 Pomodoro abgeschlossen!'; body = 'Zeit für eine Pause.';
  } else if (pendingAutoResume) {
    title = '🍅 Pause vorbei'; body = 'Fokus läuft automatisch weiter.';
  } else {
    title = '⏰ Pause vorbei!'; body = 'Bereit für den nächsten Fokus?';
  }

  self.registration.showNotification(title, {
    body,
    icon: 'https://em-content.zobj.net/source/apple/391/tomato_1f345.png',
    tag: 'pomodoro-timer',
    renotify: true,
    requireInteraction: false,
    silent: false,
  });

  const clients = await self.clients.matchAll({ type: 'window' });
  for (const client of clients) client.postMessage({ type: 'TIMER_DONE', mode: pendingMode });

  pendingMode = null; pendingAutoResume = false; timerHandle = null;
}

// ── Nachrichten von der Seite ──────────────────────────────────────────────
self.addEventListener('message', e => {
  const { type, endAt, mode, startedAt, crossAtMs, prMinutes, autoResume, intervalMs } = e.data || {};
  if (type === 'TIMER_START') {
    clearTimer(); pendingMode = mode; pendingAutoResume = !!autoResume;
    timerHandle = setTimeout(onTimerDone, Math.max(0, endAt - Date.now()));
  }
  if (type === 'TIMER_PAUSE' || type === 'TIMER_RESET' || type === 'TIMER_SKIP') {
    clearTimer(); pendingMode = null; pendingAutoResume = false;
    clearEyeBreak();
    clearPRTarget();
    clearAutoBreak();
    clearUnbrokenTarget();
  }
  if (type === 'EYE_BREAK_START') {
    scheduleEyeBreak(startedAt);
  }
  if (type === 'AUTO_BREAK_SCHEDULE') {
    scheduleAutoBreak(startedAt, intervalMs);
  }
  if (type === 'PR_TARGET_SCHEDULE') {
    schedulePRTarget(crossAtMs, prMinutes);
  }
  if (type === 'UNBROKEN_TARGET_SCHEDULE') {
    scheduleUnbrokenTarget(crossAtMs);
  }
});

// ── Klick auf Notification → Tab in Vordergrund ────────────────────────────
self.addEventListener('notificationclick', e => {
  e.notification.close();
  e.waitUntil(
    self.clients.matchAll({ type: 'window' }).then(clients => {
      for (const c of clients) if ('focus' in c) return c.focus();
      if (self.clients.openWindow) return self.clients.openWindow('/');
    })
  );
});
