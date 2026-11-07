// Service worker de Level Up: solo muestra las notificaciones push y abre la tienda al tocarlas.
// No guarda nada en caché (así nunca se queda una versión vieja de la página).
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()));

// Solo rutas de esta misma web (nunca un enlace de afuera)
function rutaSegura(ruta) {
  const r = String(ruta || '');
  return /^(index\.html(#[A-Za-z0-9:_-]*)?|admin-cuentas\.html)$/.test(r) ? r : 'index.html';
}

self.addEventListener('push', (e) => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (error) { d = {}; }
  const titulo = String(d.titulo || 'Level Up').slice(0, 120);
  e.waitUntil((async () => {
    // Con la tienda abierta y a la vista, el aviso ya aparece en la página (campana): no se repite
    const ventanas = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    if (ventanas.some((v) => v.focused && v.visibilityState === 'visible')) return;
    await self.registration.showNotification(titulo, {
      body: String(d.texto || 'Tienes un aviso nuevo.').slice(0, 600),
      icon: 'icono-192.png',
      badge: 'icono-insignia.png',
      tag: String(d.etiqueta || 'levelup'),
      renotify: true,
      data: { ruta: rutaSegura(d.ruta) },
    });
  })());
});

self.addEventListener('notificationclick', (e) => {
  e.notification.close();
  const ruta = rutaSegura(e.notification.data && e.notification.data.ruta);
  const destino = new URL(ruta, self.registration.scope);
  e.waitUntil((async () => {
    const ventanas = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    // Si la tienda ya está abierta, se enfoca y se le dice qué abrir (sin recargar)
    for (const v of ventanas) {
      const u = new URL(v.url);
      if (u.origin === destino.origin && u.pathname === destino.pathname && 'focus' in v) {
        await v.focus();
        v.postMessage({ tipo: 'abrir-aviso', enlace: destino.hash.replace('#', '') });
        return;
      }
    }
    await self.clients.openWindow(destino.href);
  })());
});
