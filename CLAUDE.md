# Level Up · Tienda de cuentas de Free Fire

## Contexto
**Level Up** es un mercado de cuentas de Free Fire en Venezuela con Level Up como **intermediario**: el comprador recarga **saldo** (orden de recarga por Binance/PayPal/Pago Móvil con captura + referencia que aprueba un admin, con chat por orden), compra con ese saldo y el dinero queda retenido, el vendedor entrega los datos en el chat del trato y, al finalizar (o tras 24 h sin reclamo), el precio pasa al saldo del vendedor. Sin comisión al comprar ni vender: **4 % solo al retirar**; los retiros se pagan los lunes. Ya NO es un centro de recargas (ese código quedó en la rama local `recargas-respaldo`).

## Repositorio
- Subir SOLO a **estesi**: https://github.com/nallilam77-lgtm/estesi (`main` sigue a `estesi/main`).
- No tocar los remotos `levelups` ni `origin` (level.online).

## Stack
- **Frontend estático** en `public/` (Vercel, sin build): `index.html` (portada + cuentas + cómo funciona + preguntas; vistas Vender y Mi panel), `reglas-cuentas.html`, `privacidad.html`, `admin-cuentas.html`. Utilidades compartidas y chat en `public/js/mercado.js`. Diseño: `css/tienda.css` (navegación, portada, tarjetas, secciones, pie) va sobre paginas-legales/creadores/billetera/cuentas.css; los iconos son un sprite SVG al inicio de index.html (nada de emojis como iconos). Ojo: creadores.css ya define `.beneficios` y `.faq`; no reutilizar esos nombres.
- **Supabase** (mismo proyecto que usaba la billetera de recargas): `supabase/cuentas.sql` tiene tablas, RLS y TODAS las funciones del trato. El navegador solo lee; cada cambio (comprar, entregar, finalizar, reclamar, retirar, acciones de admin) es una función `security definer` que valida quién llama y el estado. La publishable key de `mercado.js` no es secreta.
- Ajustes editables desde el admin (tabla `mercado_config`): comisión de retiro, retiro mínimo, garantía, horas de entrega (reembolso automático si el vendedor no entrega) y de revisión, días de liberación (lo de ventas se retira pasados N días: `_ventas_por_liberar`, `mi_saldo()`), tasa Bs, instrucciones de pago y correos (remitente, nombre, `sitio_url`).
- Ya no hay pago manual: `venta_informar_pago` y `admin_confirmar_pago` se eliminaron; `pendiente_pago` solo existe en tratos viejos.

## Reglas
- Antes de tocar HTML/CSS de `public/`, leer `.claude/UI_RULES.md` (estética oscura gaming, acento de Free Fire `--game-*`, glass, espaciados, modo ligero en celulares) y comprobar a 360 px.
- Nunca pintar datos de usuarios con `innerHTML`: `textContent` / `Mercado.crear`.
- Admin → Sistema: `admin_estado()` (tamaño, conteos, dinero, salud) y `admin_limpiar(dias, que[], ejecutar)` (nunca toca dinero; devuelve rutas de Storage que el panel borra). `vercel.json` tiene CSP estricta: si agregas un dominio externo (scripts, imágenes, APIs), agrégalo ahí.
- Perfiles públicos: tabla `perfiles` (nombre único, lectura pública, se guarda con `perfil_guardar`); `mercado_perfil(id)` arma el perfil público (nunca el correo); enlace `index.html#perfil-<id>`. Publicar exige tener nombre. Directorio público de vendedores en la portada (#vendedores): `mercado_vendedores(texto, orden)`, solo quien tiene cuentas publicadas/reservadas/vendidas o ventas > 0.
- Supabase repite `SIGNED_IN` al volver a la pestaña: reaccionar solo si cambió el usuario.
- Nunca usar `alert`/`confirm`/`prompt` del navegador: avisos con `Mercado.notificar(texto, tipo)` y confirmaciones con `await Mercado.confirmar({...})` (el admin usa su `dialogo()`).
- Tratos: apelación (`venta_apelar`, se marca atendida cuando un admin escribe en el chat) y calificación del comprador al vendedor (`venta_calificar`, tabla `calificaciones`; `mercado_reputacion` devuelve ventas + estrellas). Admin → Cuentas: `admin_buscar_usuarios` y ajustes de saldo (`admin_ajustar_saldo` = ventas, `admin_ajustar_recargado` = recargado).
- Nunca escribir secretos en el código ni leer/modificar `.env`.
- Cambios en el SQL: mantenerlo re-ejecutable; toda función que cambie `cuentas_venta` hace `set_config('mercado.sistema', '1', true)`; el saldo solo lo mueven `_mover_saldo` (parte `disponible`, ganada vendiendo, retirable) y `_mover_recargado` (parte `recargado`, solo para comprar); las capturas van al bucket privado `comprobantes`; los chats (tratos, recargas y soporte en vivo: `soporte_mensaje`, bandeja `admin_bandeja`) llegan por Supabase Realtime con `Mercado.enVivo` / `crearChat` y además se revisan cada 15 s por si la conexión en vivo falla; Postgres no acepta regex `{n,m}` con m > 255. Probar el flujo completo antes de subir (PGlite con `auth.uid()`/`auth.role()` que leen `request.jwt.claim.*`).
- Antes de subir un cambio en `vercel.json`, validarlo (`node -e "JSON.parse(require('fs').readFileSync('vercel.json','utf8'))"`): un JSON inválido hace fallar TODOS los despliegues y Vercel sigue mostrando la versión anterior (pasó el 2026-11-07 con `\.` sin escapar; en JSON va `\\.`). Si algo no se actualiza, revisar el estado del commit en GitHub (Vercel deja ahí "failure" con el motivo).
- Al cambiar un `.css`/`.js` ya publicado, subir su `?v=` en las páginas (caché del navegador/CDN).
- Avisos: toda función que cambie algo que le importe a alguien llama a `_notificar(usuario, tipo, titulo, texto, enlace, correo, agrupar)` o `_notificar_admins(...)`. `enlace` = hash de index.html (`trato-N`, `recarga-N`, `cuenta-N`, `saldo`, `panel`, `soporte`) o `admin:<pestaña>`. Nunca copiar el texto de un chat en un aviso (puede llevar contraseñas). Los correos salen por Brevo con pg_net; la clave vive en Supabase Vault (`brevo_api_key`), nunca en el código.
- Errores de la web: `Mercado.registrarError` (automático para errores sin atrapar y RPC con errores desconocidos) → `errores_cliente` → Admin → Sistema. Si agregas un código de error nuevo en el SQL, agrégalo a `ERRORES` de `mercado.js`.
- Borrar cuenta: `cuenta_eliminar_revisar()` / `cuenta_eliminar('ELIMINAR')`; con historial se anonimiza (correo `@levelup.invalid`, sin acceso), sin historial se borra de Auth.
- Pruebas: `cd pruebas && npm install && npm test` (PGlite). Agregar ahí cada flujo nuevo del SQL y correrlo antes de subir.
- Explicar los cambios en español.
