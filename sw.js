// Pomodoro Service Worker — hält den Timer im Hintergrund am Laufen
// und sendet Benachrichtigungen auch wenn der Tab eingefroren ist.

const VERSION = 'pomo-sw-v1';

// ── Installation & Activation ──────────────────────────────────────────────
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));

// ── Timer state ────────────────────────────────────────────────────────────
let timerHandle = null;
let pendingMode = null;

function clearTimer() {
  if (timerHandle !== null) { clearTimeout(timerHandle); timerHandle = null; }
}

async function onTimerDone() {
  const title = pendingMode === 'work' ? '🍅 Pomodoro abgeschlossen!' : '⏰ Pause vorbei!';
  const body  = pendingMode === 'work' ? 'Zeit für eine Pause.' : 'Bereit für den nächsten Fokus?';

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

  pendingMode = null; timerHandle = null;
}

// ── Nachrichten von der Seite ──────────────────────────────────────────────
self.addEventListener('message', e => {
  const { type, endAt, mode } = e.data || {};
  if (type === 'TIMER_START') {
    clearTimer(); pendingMode = mode;
    timerHandle = setTimeout(onTimerDone, Math.max(0, endAt - Date.now()));
  }
  if (type === 'TIMER_PAUSE' || type === 'TIMER_RESET' || type === 'TIMER_SKIP') {
    clearTimer(); pendingMode = null;
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
