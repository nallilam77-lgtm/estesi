# Level Up · Tienda de cuentas de Free Fire

## Contexto
**Level Up** es un mercado de cuentas de Free Fire en Venezuela con Level Up como **intermediario**: el comprador recarga **saldo** (orden de recarga por Binance/PayPal/Pago Móvil con captura + referencia que aprueba un admin, con chat por orden), compra con ese saldo y el dinero queda retenido, el vendedor entrega los datos en el chat del trato y, al finalizar (o tras 24 h sin reclamo), el precio pasa al saldo del vendedor. Sin comisión al comprar ni vender: **4 % solo al retirar**; los retiros se pagan los lunes. Ya NO es un centro de recargas (ese código quedó en la rama local `recargas-respaldo`).

## Repositorio
- Subir SOLO a **estesi**: https://github.com/nallilam77-lgtm/estesi (`main` sigue a `estesi/main`).
- No tocar los remotos `levelups` ni `origin` (level.online).

## Stack
- **Frontend estático** en `public/` (Vercel, sin build): `index.html` (portada + cuentas + cómo funciona + preguntas; vistas Vender y Mi panel), `reglas-cuentas.html`, `admin-cuentas.html`. Utilidades compartidas y chat en `public/js/mercado.js`. Diseño: `css/tienda.css` (navegación, portada, tarjetas, secciones, pie) va sobre paginas-legales/creadores/billetera/cuentas.css; los iconos son un sprite SVG al inicio de index.html (nada de emojis como iconos). Ojo: creadores.css ya define `.beneficios` y `.faq`; no reutilizar esos nombres.
- **Supabase** (mismo proyecto que usaba la billetera de recargas): `supabase/cuentas.sql` tiene tablas, RLS y TODAS las funciones del trato. El navegador solo lee; cada cambio (comprar, informar pago, entregar, finalizar, reclamar, retirar, acciones de admin) es una función `security definer` que valida quién llama y el estado. La publishable key de `mercado.js` no es secreta.
- Ajustes editables desde el admin (tabla `mercado_config`): comisión de retiro, retiro mínimo, garantía, horas de pago y de revisión, tasa Bs, instrucciones de pago.

## Reglas
- Antes de tocar HTML/CSS de `public/`, leer `.claude/UI_RULES.md` (estética oscura gaming, acento de Free Fire `--game-*`, glass, espaciados, modo ligero en celulares) y comprobar a 360 px.
- Nunca pintar datos de usuarios con `innerHTML`: `textContent` / `Mercado.crear`.
- Nunca escribir secretos en el código ni leer/modificar `.env`.
- Cambios en el SQL: mantenerlo re-ejecutable; toda función que cambie `cuentas_venta` hace `set_config('mercado.sistema', '1', true)`; el saldo solo lo mueven `_mover_saldo` (parte `disponible`, ganada vendiendo, retirable) y `_mover_recargado` (parte `recargado`, solo para comprar); las capturas van al bucket privado `comprobantes`; Postgres no acepta regex `{n,m}` con m > 255. Probar el flujo completo antes de subir (PGlite con `auth.uid()`/`auth.role()` que leen `request.jwt.claim.*`).
- Antes de subir un cambio en `vercel.json`, validarlo (`node -e "JSON.parse(require('fs').readFileSync('vercel.json','utf8'))"`): un JSON inválido hace fallar TODOS los despliegues y Vercel sigue mostrando la versión anterior (pasó el 2026-11-07 con `\.` sin escapar; en JSON va `\\.`). Si algo no se actualiza, revisar el estado del commit en GitHub (Vercel deja ahí "failure" con el motivo).
- Al cambiar un `.css`/`.js` ya publicado, subir su `?v=` en las páginas (caché del navegador/CDN).
- Explicar los cambios en español.
