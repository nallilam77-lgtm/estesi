# Level Up · Tienda de cuentas de Free Fire

Mercado de cuentas de Free Fire con **Level Up como intermediario**: el comprador recarga saldo (Binance, PayPal o Pago Móvil, con captura y referencia que apruebas tú), compra con ese saldo y el dinero queda retenido, el vendedor entrega los datos en el chat del trato y, cuando el comprador confirma (o pasan 24 h sin reclamo), el precio pasa al saldo del vendedor. Comprar y vender no tiene comisión: solo se descuenta un **4 % al retirar**, y los retiros se pagan los lunes.

## Páginas (`public/`)

| Página | Para qué |
|---|---|
| `index.html` | Tienda: buscar cuentas, vender, "Mi panel" (tratos con chat y mis publicaciones) y "Mi saldo" (recargas con captura y chat, retiros) |
| `reglas-cuentas.html` | Reglas del Intermediario |
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

## Dónde se guarda cada cosa (Supabase)

- Saldo de cada usuario: `saldos_vendedor` (`recargado` = solo para comprar; `disponible` = ganado vendiendo, se retira). Historial: `movimientos_vendedor`.
- Órdenes de recarga: `ordenes_recarga`; su chat: `mensajes_recarga`.
- Capturas de pago: Storage, bucket **privado** `comprobantes/<id del usuario>/…` (solo el dueño y los admins, con enlaces de 1 h).
- Fotos de las cuentas: Storage, bucket público `cuentas-fotos`.

## Panel de administración

Entrar en `/admin-cuentas.html` (por ejemplo https://estesi-blond.vercel.app/admin-cuentas.html) con el correo y la contraseña de la tienda. Solo funciona para usuarios de la tabla `mercado_admins`; en la tienda, a esos usuarios les aparece el enlace "Admin" arriba.

## Valores que se cambian desde Ajustes (tabla `mercado_config`)

`comision_retiro` (4), `retiro_minimo` (5 USD), `garantia_usd` (1), `horas_revision` (24), `tasa_bs`, `instrucciones_pago` (nota para quien recarga), `recarga_minima` (1 USD), `paypal_recargo` (%), `binance_pay_id`, `binance_nombre`, `paypal_correo`, `paypal_nombre`, `pm_banco`, `pm_telefono`, `pm_cedula`, `pm_titular`. (`horas_pago` solo aplica a tratos viejos sin saldo.)
