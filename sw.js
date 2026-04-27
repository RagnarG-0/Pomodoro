// Pomodoro Service Worker — hält den Timer im Hintergrund am Laufen
// und sendet Benachrichtigungen auch wenn der Tab eingefroren ist.

const VERSION = 'pomo-sw-v1';

// ── Installation & Activation ──────────────────────────────────────────────
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));

// ── Timer state ────────────────────────────────────────────────────────────
let timerHandle = null;   // setTimeout handle
let pendingMode = null;   // welcher Modus gerade läuft ('work' | 'short' | 'long')

function clearTimer() {
  if (timerHandle !== null) {
    clearTimeout(timerHandle);
    timerHandle = null;
  }
}

// Benachrichtigung anzeigen + alle Tabs informieren
async function onTimerDone() {
  const title = pendingMode === 'work'
    ? '🍅 Pomodoro abgeschlossen!'
    : '⏰ Pause vorbei!';
  const body = pendingMode === 'work'
    ? 'Zeit für eine Pause.'
    : 'Bereit für den nächsten Fokus?';

  // Push Notification — sichtbar auch wenn Tab im Hintergrund
  self.registration.showNotification(title, {
    body,
    icon: 'https://em-content.zobj.net/source/apple/391/tomato_1f345.png',
    badge: 'https://em-content.zobj.net/source/apple/391/tomato_1f345.png',
    tag: 'pomodoro-timer',          // ersetzt vorherige Notification
    renotify: true,
    requireInteraction: false,
    silent: false,
  });

  // Alle offenen Tabs der Seite informieren, damit sie den Modus wechseln
  const clients = await self.clients.matchAll({ type: 'window' });
  for (const client of clients) {
    client.postMessage({ type: 'TIMER_DONE', mode: pendingMode });
  }

  pendingMode = null;
  timerHandle = null;
}

// ── Nachrichten von der Seite ──────────────────────────────────────────────
self.addEventListener('message', e => {
  const { type, endAt, mode } = e.data || {};

  if (type === 'TIMER_START') {
    // endAt = Date.now() + remaining * 1000  (vom Tab geschickt)
    clearTimer();
    pendingMode = mode;
    const msLeft = Math.max(0, endAt - Date.now());
    timerHandle = setTimeout(onTimerDone, msLeft);
  }

  if (type === 'TIMER_PAUSE' || type === 'TIMER_RESET' || type === 'TIMER_SKIP') {
    clearTimer();
    pendingMode = null;
  }
});

// Klick auf Notification → Tab in Vordergrund bringen
self.addEventListener('notificationclick', e => {
  e.notification.close();
  e.waitUntil(
    self.clients.matchAll({ type: 'window' }).then(clients => {
      for (const client of clients) {
        if ('focus' in client) return client.focus();
      }
      // Falls kein Tab offen: neues Fenster
      if (self.clients.openWindow) return self.clients.openWindow('/');
    })
  );
});
