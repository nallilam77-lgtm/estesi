# Level Up · Tienda de cuentas de Free Fire

Mercado de cuentas de Free Fire con **Level Up como intermediario**: el comprador paga a Level Up, el dinero queda retenido, el vendedor entrega los datos en el chat del trato y, cuando el comprador confirma (o pasan 24 h sin reclamo), el precio pasa al saldo del vendedor. Comprar y vender no tiene comisión: solo se descuenta un **4 % al retirar**, y los retiros se pagan los lunes.

## Páginas (`public/`)

| Página | Para qué |
|---|---|
| `index.html` | Tienda: buscar cuentas, vender y "Mi panel" (tratos con chat, saldo de ventas y retiros, mis publicaciones) |
| `reglas-cuentas.html` | Reglas del Intermediario |
| `admin-cuentas.html` | Panel de administración: aprobar publicaciones, confirmar pagos, resolver reclamos, pagar retiros y ajustes |

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
6. En `admin-cuentas.html` → **Ajustes**: escribir en "Instrucciones de pago" tus datos de Pago Móvil / Binance y la tasa en Bs.

## Panel de administración

Entrar en `/admin-cuentas.html` (por ejemplo https://estesi-blond.vercel.app/admin-cuentas.html) con el correo y la contraseña de la tienda. Solo funciona para usuarios de la tabla `mercado_admins`; en la tienda, a esos usuarios les aparece el enlace "Admin" arriba.

## Valores que se cambian desde Ajustes (tabla `mercado_config`)

`comision_retiro` (4), `retiro_minimo` (5 USD), `garantia_usd` (1), `horas_pago` (2), `horas_revision` (24), `tasa_bs`, `instrucciones_pago`.
