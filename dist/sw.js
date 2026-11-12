/* Only the public offline page and brand icons are cached. No API, auth or order data. */
const RELEASE = '8b04659571b44950';
const PREFIX = 'mio-pwa-public-';
const CACHE = PREFIX + RELEASE;
const OFFLINE = '/offline.html';
const ASSETS = [OFFLINE, '/icons/mio-192.png', '/icons/mio-512.png'];
self.addEventListener('install', event => {
  event.waitUntil(caches.open(CACHE).then(cache => cache.addAll(ASSETS)));
});
self.addEventListener('activate', event => {
  event.waitUntil((async () => {
    await Promise.all((await caches.keys()).filter(key => key.startsWith(PREFIX) && key !== CACHE).map(key => caches.delete(key)));
    await self.clients.claim();
  })());
});
self.addEventListener('message', event => {
  if (event.data?.type === 'ACTIVATE_UPDATE') self.skipWaiting();
});
self.addEventListener('fetch', event => {
  const request = event.request, url = new URL(request.url);
  if (request.method !== 'GET' || url.origin !== self.location.origin) return;
  if (request.mode === 'navigate') {
    event.respondWith(fetch(request, {cache:'no-store'}).catch(async () =>
      (await caches.match(OFFLINE)) || new Response('You are offline. Reconnect and reload.', {status:503,headers:{'Content-Type':'text/plain'}})
    ));
  } else if (ASSETS.includes(url.pathname) && !url.search) {
    event.respondWith(caches.match(request).then(cached => cached || fetch(request)));
  }
  // Everything else uses the browser network path. Never save or replay mutations.
});
