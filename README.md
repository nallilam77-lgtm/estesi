# Level Up · Tienda de cuentas de Free Fire

Mercado de cuentas de Free Fire con **Level Up como intermediario**: el comprador recarga saldo (Binance, PayPal o Pago Móvil, con captura y referencia que apruebas tú), compra con ese saldo y el dinero queda retenido, el vendedor entrega los datos en el chat del trato y, cuando el comprador confirma (o pasan 24 h sin reclamo), el precio pasa al saldo del vendedor. Comprar y vender no tiene comisión: solo se descuenta un **4 % al retirar**, y los retiros se pagan los lunes.

## Páginas (`public/`)

| Página | Para qué |
|---|---|
| `index.html` | Tienda: buscar cuentas, vender, "Mi panel" (tratos con chat y mis publicaciones) y "Mi saldo" (recargas con captura y chat, retiros) |
| `reglas-cuentas.html` | Reglas del Intermediario |
| `privacidad.html` | Política de privacidad (qué datos se guardan y cómo borrar la cuenta) |
| `admin-cuentas.html` | Panel de administración: aprobar/rechazar/eliminar recargas y responder su chat, aprobar publicaciones, resolver reclamos, pagar retiros y ajustes (tus datos de Binance, PayPal y Pago Móvil) |

Es un sitio estático (Vercel) que habla directo con **Supabase**. La publishable key de `public/js/mercado.js` no es secreta: lo que cada usuario puede ver o cambiar lo deciden las reglas de `supabase/cuentas.sql` (RLS + funciones). El navegador solo lee; cada cambio (comprar, entregar, finalizar, retirar…) lo valida la base de datos.

## Activar

1. **Supabase → SQL Editor**: pegar TODO `supabase/cuentas.sql` → Run (se puede repetir).
2. Crear tu cuenta en la tienda y hacerte administrador:
   ```sql
   insert into public.mercado_admins (usuario) select id from auth.users where email = 'TU-CORREO@gmail.com';
   ```
3. **Supabase → Authentication → URL Configuration**: poner el dominio de la tienda en *Site URL* y agregar `https://TU-DOMINIO/index.html` en *Redirect URLs*.
4. (Recomendado) **Database → Extensions → pg_cron** y volver a correr el SQL: los tratos vencidos se cierran solos cada 10 min.
5. **Vercel**: importar este repositorio (sin build; la carpeta publicada es `public/`).
6. En `admin-cuentas.html` → **Ajustes**: escribir tus datos de Binance, Pago Móvil (y la tasa en Bs) y PayPal. Un método sin datos no aparece en la tienda.
7. **Notificaciones al celular** (recomendado; sin esto los avisos solo se ven dentro de la web). El cliente instala la tienda como app (*Mi panel → Tu cuenta → Instalar la app*; en iPhone: Safari → Compartir → *Agregar a inicio*) y toca *Activar*: le llegan aunque tenga la app cerrada.
   1. **Supabase → Database → Extensions**: activar **pg_net**.
   2. En TU computadora (no la pegues en ningún chat): `npx web-push generate-vapid-keys`. Salen una *Public Key* y una *Private Key*.
   3. **Supabase → Edge Functions → Deploy a new function → Via Editor**: nombre **`enviar-push`**, pegar todo `supabase/functions/enviar-push/index.ts` y desplegar. En los detalles de la función, **apagar "Verify JWT"** (la llama la base de datos; es seguro, ver el comentario del archivo). Con la CLI: `supabase functions deploy enviar-push --no-verify-jwt`.
   4. **Edge Functions → Secrets**: agregar `VAPID_PUBLICA` (la Public Key), `VAPID_PRIVADA` (la Private Key) y, opcional, `VAPID_CONTACTO` (`mailto:tucorreo@gmail.com`).
   5. En tu celular: abrir la tienda con tu cuenta de admin → *Mi panel → Tu cuenta → Activar*. Luego en el admin → **Ajustes → Notificaciones al celular → "Enviarme una notificación de prueba"**. Admin → Sistema muestra dispositivos y envíos.
   Si cambias las claves VAPID, los dispositivos se vuelven a suscribir solos la próxima vez que abran la tienda. La dirección de la función está en `mercado_config.push_url` (la tienda y la base la leen de ahí): si Supabase le puso otro nombre, cámbiala con `update public.mercado_config set valor = 'https://…supabase.co/functions/v1/NOMBRE' where clave = 'push_url';`. Abrir esa dirección en el navegador muestra si las claves están bien.
8. **Correos automáticos** (opcional; necesita un correo remitente que Brevo acepte):
   1. Crear una cuenta gratis en [Brevo](https://www.brevo.com) (300 correos al día). En *Senders, Domains & Dedicated IPs → Senders* agregar y verificar el correo remitente (puede ser tu Gmail).
   2. En Brevo: *SMTP & API → API Keys → Generate a new API key*. Copiarla (empieza con `xkeysib-`).
   3. **Supabase → Database → Extensions**: activar **pg_net**.
   4. **Supabase → SQL Editor** (pegando TU clave en lugar de la de ejemplo; la clave queda cifrada en Vault y nunca va en el código):
      ```sql
      select vault.create_secret('xkeysib-PEGA-AQUI-TU-CLAVE', 'brevo_api_key');
      ```
      Para cambiarla después: `select vault.update_secret((select id from vault.secrets where name = 'brevo_api_key'), 'xkeysib-NUEVA');`
   5. En el admin → **Ajustes → Correos automáticos**: escribir el correo remitente verificado, guardar y tocar **"Enviarme un correo de prueba"**. Admin → Sistema muestra cuántos se enviaron.
9. Si usas otro dominio (no `estesi-blond.vercel.app`), cámbialo en Ajustes → *Dirección de la tienda* y en `public/sitemap.xml`, `public/robots.txt` y las etiquetas `og:` / `canonical` de `public/index.html`.

## Dónde se guarda cada cosa (Supabase)

- Saldo de cada usuario: `saldos_vendedor` (`recargado` = solo para comprar; `disponible` = ganado vendiendo, se retira). Historial: `movimientos_vendedor`.
- Órdenes de recarga: `ordenes_recarga`; su chat: `mensajes_recarga`.
- Chat de soporte en vivo: `soporte_chats` (una conversación por usuario) y `mensajes_soporte`. Los chats llegan al instante con Supabase Realtime (el SQL agrega las tablas de mensajes y `ordenes_recarga` a la publicación `supabase_realtime`).
- Capturas de pago: Storage, bucket **privado** `comprobantes/<id del usuario>/…` (solo el dueño y los admins, con enlaces de 1 h).
- Fotos de las cuentas: Storage, bucket público `cuentas-fotos`.

## Panel de administración

Entrar en `/admin-cuentas.html` (por ejemplo https://estesi-blond.vercel.app/admin-cuentas.html) con el correo y la contraseña de la tienda. Solo funciona para usuarios de la tabla `mercado_admins`; en la tienda, a esos usuarios les aparece el enlace "Admin" arriba.

## Valores que se cambian desde Ajustes (tabla `mercado_config`)

`comision_retiro` (4), `retiro_minimo` (5 USD), `garantia_usd` (1), `horas_entrega` (12: si el vendedor no entrega en ese tiempo, el trato se cancela solo y se reembolsa; 0 = nunca), `horas_revision` (24), `dias_liberacion` (3: lo cobrado por una venta se usa para comprar al momento pero se retira pasados esos días; 0 = al momento), `tasa_bs`, `instrucciones_pago` (nota para quien recarga), `recarga_minima` (1 USD), `paypal_recargo` (%), `binance_pay_id`, `binance_nombre`, `paypal_correo`, `paypal_nombre`, `pm_banco`, `pm_telefono`, `pm_cedula`, `pm_titular`, `correo_remitente`, `correo_nombre`, `sitio_url`. (`horas_pago` solo aplica a tratos viejos sin saldo.)

Si cambias `horas_entrega`, `horas_revision`, `dias_liberacion` o la comisión, actualiza también el texto de `public/reglas-cuentas.html` (ahí van escritos 12 h, 24 h, 3 días y 4 %).

## Avisos, errores y cuentas borradas

- **Avisos** (tabla `notificaciones`): los crean las funciones del SQL con `_notificar` (venta nueva, entrega, cobro, cancelación, reclamo, recarga aprobada o rechazada, retiro pagado, respuestas de Level Up…). Se ven en la campana de la tienda, llegan en vivo y, si el usuario las activó, como **notificación push** en sus dispositivos (`push_suscripciones`, `public/sw.js`, Edge Function `enviar-push`; ver paso 7). Los importantes también pueden ir por **correo** (Brevo, paso 8). Los avisos de chat nunca copian el texto del mensaje (puede llevar contraseñas) y se agrupan: uno por conversación hasta que se lea. Cada usuario puede apagar los correos en *Mi panel → Tu cuenta*.
- **Errores de la web** (tabla `errores_cliente`): los errores de JavaScript en los navegadores de los clientes se reportan solos (`Mercado.registrarError`) y se ven en Admin → Sistema.
- **Borrar cuenta** (*Mi panel → Tu cuenta*): sin tratos se borra todo; con tratos se borran los datos personales y se conservan los tratos y movimientos de dinero sin correo ni nombre. Exige no tener tratos abiertos ni saldo.

## Pruebas

`pruebas/flujo.mjs` levanta un Postgres en memoria (PGlite) con Auth, Storage, pg_net y Vault simulados, corre `supabase/cuentas.sql` tres veces y recorre todo el flujo (recarga, compra, chat, entrega, cierre, retiros con liberación, reembolso automático, reclamo, avisos, correos, errores, borrar cuenta) comprobando al final que el dinero cuadra:

```
cd pruebas && npm install && npm test
```
