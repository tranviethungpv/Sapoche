// The service worker of Sapoche. It does one thing: it receives the pushes of a room's chat (see
// server/src/push.ts) and shows them as notices, and it brings the page forward when a notice is touched. It keeps no
// cache and answers no request, so the app loads as it does without it.
'use strict';

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (event) => event.waitUntil(self.clients.claim()));

// The notices are written here, as the server sends the words of the message and not a sentence. The names of the
// reactions are the ones of server/src/protocol.ts (REACTIONS); a reaction that is already an emoji is shown as it is.
const REACTIONS = {
  heart: '❤️', love: '😍', kiss: '😘', hug: '🤗', blush: '😊', cool: '😎', wink: '😉', pleading: '🥺',
  laugh: '😂', rofl: '🤣', grin: '😁', wow: '😮', mindblown: '🤯', think: '🤔', eyes: '👀', sad: '😢',
  cry: '😭', skull: '💀', sleepy: '😴', fire: '🔥', clap: '👏', raise: '🙌', party: '🥳', hundred: '💯',
  sparkles: '✨', rocket: '🚀', muscle: '💪', thumbsup: '👍', thumbsdown: '👎', ok: '👌', pray: '🙏', music: '🎶',
  dance: '💃', headphones: '🎧', mic: '🎤', guitar: '🎸', drum: '🥁', speaker: '🔊', replay: '🔁',
};

const WORDS = {
  en: {
    app: 'Sapoche',
    sent: 'sent a message',
    replied: (who) => `${who} replied to you`,
    reacted: (who, e) => `${who} reacted ${e} to your message`,
    many: (n) => `${n} new messages`,
  },
  vi: {
    app: 'Sapoche',
    sent: 'đã gửi một tin nhắn',
    replied: (who) => `${who} đã trả lời bạn`,
    reacted: (who, e) => `${who} đã thả ${e} vào tin của bạn`,
    many: (n) => `${n} tin nhắn mới`,
  },
};

// The preview of a message of a room with end-to-end encrypted chat comes sealed (`pv`, and `by`, who wrote it); the page
// keeps the secrets of its rooms in IndexedDB for this. It is the same as ChatCipher in Kotlin, Swift and Dart: a key from
// the secret by HKDF-SHA256, the preview sealed with AES-256-GCM and the room and the writer as associated data.
const bytesOf = (text) => Uint8Array.from(atob(text.replace(/-/g, '+').replace(/_/g, '/')), (c) => c.charCodeAt(0));
const utf8 = (text) => new TextEncoder().encode(text);

async function secretOf(room) {
  try {
    const db = await new Promise((resolve, reject) => {
      const request = indexedDB.open('sapoche-keys', 1);
      request.onupgradeneeded = () => request.result.createObjectStore('documents');
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error);
    });
    const saved = await new Promise((resolve) => {
      const request = db.transaction('documents').objectStore('documents').get('secrets');
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => resolve(null);
    });
    db.close();
    return JSON.parse(saved)[room.toUpperCase()] || null;
  } catch (_) {
    return null;
  }
}

async function openPreview(notice) {
  try {
    const secret = await secretOf(notice.room);
    if (!secret || !notice.pv || !notice.by) return '';
    const room = notice.room.toUpperCase();
    const sealed = bytesOf(notice.pv);
    const epoch = sealed[1];
    const ikm = await crypto.subtle.importKey('raw', bytesOf(secret), 'HKDF', false, ['deriveKey']);
    const key = await crypto.subtle.deriveKey(
      { name: 'HKDF', hash: 'SHA-256', salt: utf8('sapoche-chat-v1'), info: utf8(`${room}|${epoch}`) },
      ikm,
      { name: 'AES-GCM', length: 256 },
      false,
      ['decrypt'],
    );
    const plain = await crypto.subtle.decrypt(
      { name: 'AES-GCM', iv: sealed.slice(2, 14), additionalData: utf8(`sapoche-chat-v1|${room}|${notice.by}|${epoch}|pv`) },
      key,
      sealed.slice(14),
    );
    return new TextDecoder().decode(plain);
  } catch (_) {
    return '';
  }
}

async function appIsInFront() {
  const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
  return windows.some((w) => w.visibilityState === 'visible' && w.focused);
}

async function show(notice) {
  // The person is looking at the app: the chat shows it there, a notice on top would only be in the way
  if (await appIsInFront()) return;
  const words = WORDS[(notice.l || self.navigator.language || 'en').slice(0, 2)] || WORDS.en;
  const tag = `room-${notice.room}`;
  const before = (await self.registration.getNotifications({ tag }))[0];
  const count = (before?.data?.n ?? 0) + 1;
  const emoji = notice.e ? REACTIONS[notice.e] || notice.e : '';
  const text = notice.text || (notice.pv ? await openPreview(notice) : '');
  let title;
  let body;
  if (count > 1) {
    title = notice.rn || words.app;
    body = `${words.many(count)}\n${notice.name}${text ? `: ${text}` : ''}`;
  } else if (notice.k === 'reply') {
    title = words.replied(notice.name);
    body = text;
  } else if (notice.k === 'react') {
    title = words.reacted(notice.name, emoji);
    body = text;
  } else {
    title = notice.name;
    body = text || words.sent;
  }
  await self.registration.showNotification(title, {
    body,
    tag,
    // The first of a run makes a sound; the ones that replace it do not
    renotify: false,
    silent: count > 1,
    icon: 'icons/Icon-192.png',
    badge: 'icons/Icon-192.png',
    data: { room: notice.room, n: count },
  });
}

self.addEventListener('push', (event) => {
  let notice;
  try {
    notice = event.data.json();
  } catch (_) {
    return;
  }
  if (!notice || typeof notice.room !== 'string') return;
  event.waitUntil(show(notice));
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const room = event.notification.data?.room;
  if (!room) return;
  event.waitUntil(
    (async () => {
      const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
      const open = windows[0];
      if (open) {
        await open.focus();
        open.postMessage({ type: 'open-chat', room });
        return;
      }
      // No page is open: the app starts on the room and its chat (a browser that has a name and the key goes straight in)
      await self.clients.openWindow(`./?join=${encodeURIComponent(room)}&chat=1`);
    })(),
  );
});
