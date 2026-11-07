-- =====================================================================
-- LEVEL UP · MERCADO DE CUENTAS DE FREE FIRE CON INTERMEDIARIO (Supabase, mismo proyecto que la billetera)
--
-- Cómo instalarlo: Supabase → SQL Editor → New query → pega TODO este archivo → Run.
-- Se puede volver a correr: crea lo que falta y reemplaza funciones y políticas.
-- Después, hazte administrador (una sola vez, con el correo con el que entras a la web):
--   insert into public.mercado_admins (usuario) select id from auth.users where email = 'tu-correo@gmail.com';
--
-- Las cuentas de usuario son las mismas de la billetera (Supabase Auth).
--
-- SALDO: cada usuario tiene un saldo con dos partes (tabla saldos_vendedor):
--   recargado  → lo que recargó por Binance, PayPal o Pago Móvil (orden de recarga con captura y referencia
--                que un admin aprueba). Sirve para comprar; NO se retira.
--   disponible → lo que ganó vendiendo. Sirve para comprar y es lo único que se retira (con el 4 %).
--   Al comprar se usa primero lo recargado y luego lo de ventas; si el trato se cancela, vuelve cada parte a su lugar.
--
-- FLUJO DE UN TRATO (reglas en public/reglas-cuentas.html):
--   pagada         → el comprador tocó "Comprar con saldo": se descuenta de su saldo, la cuenta queda "reservada"
--                    y el dinero queda RETENIDO por Level Up. Si el vendedor no entrega en `horas_entrega`
--                    (y nadie llamó a Level Up), el trato se cancela solo, el dinero vuelve y la cuenta queda pausada.
--   (pendiente_pago → solo tratos viejos, de antes del saldo. Ya no se crean; un admin puede cancelarlos.)
--   entregada      → el vendedor entregó los datos en el chat del trato. El comprador tiene `horas_revision`
--                    para "Finalizar" o "Tengo un problema" (con video); si no hace nada, se cierra solo.
--   en_reclamo     → un admin decide: a favor del vendedor (se cierra) o del comprador (se cancela y se reembolsa).
--   cerrada        → el precio COMPLETO pasa al saldo del vendedor y la cuenta queda "vendida". Se puede usar
--                    para comprar al momento, pero se RETIRA después de `dias_liberacion` días (por si el dueño
--                    anterior recupera la cuenta por su Facebook/Google).
--   cancelada      → no hubo venta: lo pagado vuelve solo al saldo del comprador.
--
-- COMISIÓN: comprar y vender no cuesta nada. Solo al RETIRAR se descuenta `comision_retiro` % (4).
-- La Garantía Extendida (`garantia_usd`) la paga el comprador y es para Level Up, no para el vendedor.
--
-- SEGURIDAD: el navegador solo LEE (RLS). Todo cambio de estado, saldo o mensaje pasa por las funciones
-- de abajo (security definer), que comprueban quién llama y en qué estado está el trato.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Administradores y configuración
-- ---------------------------------------------------------------------
create table if not exists public.mercado_admins (
  usuario uuid primary key references auth.users (id) on delete cascade
);

create or replace function public.es_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from mercado_admins where usuario = auth.uid());
$$;

create table if not exists public.mercado_config (
  clave text primary key,
  valor text not null
);
insert into public.mercado_config (clave, valor) values
  ('comision_retiro', '4'),        -- % que se descuenta al retirar
  ('retiro_minimo', '5'),          -- USD
  ('garantia_usd', '1'),           -- Garantía Extendida
  ('horas_pago', '2'),             -- para informar el pago tras tocar "Comprar"
  ('horas_revision', '24'),        -- para finalizar o reclamar tras la entrega
  ('tasa_bs', ''),                 -- Bs por 1 USD (vacío = no se muestra el monto en Bs)
  ('instrucciones_pago', 'Paga el total por Pago Móvil (al cambio del día) o por Binance y escribe abajo la referencia. Te confirmamos en el chat del trato.'),
  -- Recargas de saldo: tus datos de cobro (vacío = ese método no aparece en la tienda)
  ('recarga_minima', '1'),         -- USD
  ('paypal_recargo', '0'),         -- % extra que paga quien recarga por PayPal (comisión de PayPal)
  ('binance_pay_id', ''), ('binance_nombre', ''),
  ('paypal_correo', ''), ('paypal_nombre', ''),
  ('pm_banco', ''), ('pm_telefono', ''), ('pm_cedula', ''), ('pm_titular', ''),
  ('horas_entrega', '12'),         -- el vendedor tiene este tiempo para entregar; si no, se devuelve el dinero solo (0 = nunca)
  ('dias_liberacion', '3'),        -- lo cobrado por una venta se puede RETIRAR después de estos días (0 = al momento)
  -- Correos automáticos (Brevo). La clave de Brevo va en Supabase Vault con el nombre 'brevo_api_key', nunca aquí.
  ('correo_remitente', ''),        -- correo verificado en Brevo (vacío = no se envían correos)
  ('correo_nombre', 'Level Up'),
  ('sitio_url', 'https://estesi-blond.vercel.app'),
  -- Notificaciones push: la Edge Function 'enviar-push' (supabase/functions/enviar-push). Sus claves VAPID van en los secretos de la función.
  ('push_url', 'https://qaxgvfzpzywfgcwnalfr.supabase.co/functions/v1/enviar-push')
on conflict (clave) do nothing;
-- Desde que existe el saldo, este texto es la nota que ve quien recarga
update public.mercado_config set valor = 'Envía el monto exacto, toma captura del comprobante y súbela aquí con la referencia o número de orden. Te acreditamos en minutos (horario de atención).'
 where clave = 'instrucciones_pago' and valor like 'Paga el total por Pago Móvil%';

create or replace function public._config_num(p_clave text, p_defecto numeric)
returns numeric language plpgsql stable security definer set search_path = public as $$
declare v text;
begin
  select valor into v from mercado_config where clave = p_clave;
  return coalesce(nullif(trim(v), '')::numeric, p_defecto);
exception when others then
  return p_defecto;
end $$;

-- ---------------------------------------------------------------------
-- Publicaciones
-- ---------------------------------------------------------------------
create table if not exists public.cuentas_venta (
  id              bigint generated always as identity primary key,
  vendedor        uuid not null default auth.uid() references auth.users (id) on delete cascade,
  titulo          text not null check (char_length(titulo) between 8 and 80),
  nivel           smallint not null check (nivel between 1 and 100),
  region          text not null check (region in ('LATAM', 'Brasil', 'EE. UU.', 'Europa', 'Asia', 'Otra')),
  vinculacion     text not null check (vinculacion in ('Facebook', 'Google', 'VK', 'X (Twitter)', 'Apple', 'Huawei', 'Otra')),
  precio_usd      numeric(8, 2) not null check (precio_usd between 1 and 5000),
  destacados      text not null default '' check (char_length(destacados) <= 300),
  descripcion     text not null default '' check (char_length(descripcion) <= 1500),
  fotos           text[] not null default '{}' check (cardinality(fotos) between 1 and 6),
  estado          text not null default 'revision',
  motivo_rechazo  text,
  creado          timestamptz not null default now(),
  actualizado     timestamptz not null default now()
);
alter table public.cuentas_venta drop constraint if exists cuentas_venta_estado_check;
alter table public.cuentas_venta add constraint cuentas_venta_estado_check
  check (estado in ('revision', 'publicada', 'pausada', 'reservada', 'vendida', 'rechazada'));
create index if not exists cuentas_venta_publicadas on public.cuentas_venta (creado desc) where estado = 'publicada';
create index if not exists cuentas_venta_por_vendedor on public.cuentas_venta (vendedor, creado desc);

create table if not exists public.cuentas_contacto (
  cuenta    bigint primary key references public.cuentas_venta (id) on delete cascade,
  vendedor  uuid not null default auth.uid() references auth.users (id) on delete cascade,
  whatsapp  text not null check (whatsapp ~ '^\+58(412|414|416|422|424|426)[0-9]{7}$')
);

-- Reglas que el navegador no puede saltarse. Las funciones del mercado (mercado.sistema = '1'),
-- los admins y el panel de Supabase sí pueden cambiar cualquier cosa.
create or replace function public.cuentas_venta_reglas()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  libre  boolean := coalesce(auth.role(), '') <> 'authenticated'
                    or coalesce(current_setting('mercado.sistema', true), '') = '1'
                    or public.es_admin();
  activas int;
begin
  if libre then
    new.actualizado := now();
    return new;
  end if;

  if tg_op = 'INSERT' then
    new.vendedor := auth.uid();
    new.estado := 'revision';
    new.motivo_rechazo := null;
    new.creado := now();
    select count(*) into activas from cuentas_venta
      where vendedor = auth.uid() and estado in ('revision', 'publicada', 'pausada', 'reservada');
    if activas >= 10 then
      raise exception 'LIMITE_PUBLICACIONES';
    end if;
  else
    if new.vendedor <> old.vendedor or new.creado <> old.creado then
      raise exception 'NO_PERMITIDO';
    end if;
    if old.estado in ('reservada', 'vendida', 'rechazada') then
      raise exception 'NO_EDITABLE';
    end if;
    new.motivo_rechazo := old.motivo_rechazo;
    -- El vendedor solo puede pausar y reanudar una cuenta ya aprobada
    if new.estado <> old.estado and not (
         (old.estado = 'publicada' and new.estado = 'pausada')
      or (old.estado = 'pausada' and new.estado = 'publicada')
    ) then
      raise exception 'NO_PERMITIDO';
    end if;
    -- Cambiar el texto o las fotos de una cuenta aprobada la manda otra vez a revisión (el precio no)
    if old.estado in ('publicada', 'pausada') and (
         new.titulo <> old.titulo or new.nivel <> old.nivel or new.region <> old.region
      or new.vinculacion <> old.vinculacion or new.destacados <> old.destacados
      or new.descripcion <> old.descripcion or new.fotos <> old.fotos
    ) then
      new.estado := 'revision';
    end if;
  end if;

  if exists (select 1 from unnest(new.fotos) f where f !~ ('^' || new.vendedor::text || '/[A-Za-z0-9_-]{8,64}\.(webp|jpg|jpeg|png)$')) then
    raise exception 'FOTO_INVALIDA';
  end if;

  new.actualizado := now();
  return new;
end $$;

drop trigger if exists cuentas_venta_reglas on public.cuentas_venta;
create trigger cuentas_venta_reglas before insert or update on public.cuentas_venta
  for each row execute function public.cuentas_venta_reglas();

-- ---------------------------------------------------------------------
-- Tratos, chat, saldo de vendedores y retiros
-- ---------------------------------------------------------------------
create table if not exists public.ventas_cuentas (
  id                 bigint generated always as identity primary key,
  cuenta             bigint references public.cuentas_venta (id) on delete set null,
  comprador          uuid not null references auth.users (id) on delete restrict,
  vendedor           uuid not null references auth.users (id) on delete restrict,
  titulo             text not null,
  precio_usd         numeric(8, 2) not null check (precio_usd > 0),   -- lo que recibe el vendedor
  garantia           boolean not null default false,
  total_usd          numeric(8, 2) not null check (total_usd > 0),    -- lo que paga el comprador
  estado             text not null default 'pendiente_pago'
                     check (estado in ('pendiente_pago', 'pagada', 'entregada', 'en_reclamo', 'cerrada', 'cancelada')),
  metodo_pago        text,
  referencia_pago    text,
  pago_informado_en  timestamptz,
  pagada_en          timestamptz,
  entregada_en       timestamptz,
  cerrada_en         timestamptz,
  reclamo_motivo     text,
  reclamo_video      text,
  resolucion         text,
  creado             timestamptz not null default now(),
  actualizado        timestamptz not null default now()
);
-- Una cuenta solo puede estar en UN trato abierto
create unique index if not exists ventas_cuenta_abierta on public.ventas_cuentas (cuenta)
  where estado not in ('cerrada', 'cancelada');
create index if not exists ventas_por_comprador on public.ventas_cuentas (comprador, creado desc);
create index if not exists ventas_por_vendedor on public.ventas_cuentas (vendedor, creado desc);
create index if not exists ventas_abiertas on public.ventas_cuentas (estado) where estado not in ('cerrada', 'cancelada');
-- Cuánto se cobró de cada parte del saldo del comprador (para devolverlo igual si se cancela)
alter table public.ventas_cuentas add column if not exists pagado_recargado numeric(12, 2) not null default 0;
alter table public.ventas_cuentas add column if not exists pagado_disponible numeric(12, 2) not null default 0;
-- Apelación: el comprador o el vendedor llama a Level Up al chat. Se limpia cuando un admin escribe en el trato.
alter table public.ventas_cuentas add column if not exists apelada_en timestamptz;
alter table public.ventas_cuentas add column if not exists apelada_por text;

-- Calificación del comprador al vendedor (1 a 5 estrellas), una por trato cerrado
create table if not exists public.calificaciones (
  venta       bigint primary key references public.ventas_cuentas (id) on delete cascade,
  vendedor    uuid not null references auth.users (id) on delete cascade,
  comprador   uuid not null references auth.users (id) on delete cascade,
  estrellas   smallint not null check (estrellas between 1 and 5),
  comentario  text not null default '' check (char_length(comentario) <= 300),
  creado      timestamptz not null default now()
);
create index if not exists calificaciones_por_vendedor on public.calificaciones (vendedor, creado desc);

create table if not exists public.mensajes_venta (
  id      bigint generated always as identity primary key,
  venta   bigint not null references public.ventas_cuentas (id) on delete cascade,
  autor   uuid references auth.users (id) on delete set null,
  rol     text not null check (rol in ('comprador', 'vendedor', 'admin', 'sistema')),
  texto   text not null check (char_length(texto) between 1 and 1000),
  creado  timestamptz not null default now()
);
create index if not exists mensajes_por_venta on public.mensajes_venta (venta, id);

create table if not exists public.saldos_vendedor (
  vendedor    uuid primary key references auth.users (id) on delete cascade,
  disponible  numeric(12, 2) not null default 0 check (disponible >= 0),
  ventas      int not null default 0,       -- ventas cerradas (reputación)
  actualizado timestamptz not null default now()
);
-- Saldo recargado (solo para comprar, no se retira). "disponible" = ganado vendiendo (se retira).
alter table public.saldos_vendedor add column if not exists recargado numeric(12, 2) not null default 0 check (recargado >= 0);

-- Órdenes de recarga: el usuario paga por Binance / PayPal / Pago Móvil y sube captura + referencia
create table if not exists public.ordenes_recarga (
  id              bigint generated always as identity primary key,
  usuario         uuid not null references auth.users (id) on delete cascade,
  metodo          text not null check (metodo in ('binance', 'paypal', 'pago_movil')),
  monto_usd       numeric(10, 2) not null check (monto_usd > 0),       -- lo que se acredita
  monto_pagar     numeric(10, 2) not null check (monto_pagar > 0),     -- lo que envía (PayPal puede llevar recargo)
  monto_bs        numeric(14, 2),                                      -- Pago Móvil, a la tasa del momento
  referencia      text not null,
  captura         text not null,                                       -- ruta en el bucket privado "comprobantes"
  estado          text not null default 'pendiente' check (estado in ('pendiente', 'aprobada', 'rechazada')),
  acreditado_usd  numeric(10, 2),
  nota            text,                                                -- motivo del rechazo
  msg_cliente     timestamptz,                                         -- último mensaje del cliente en el chat
  msg_admin       timestamptz,                                         -- último mensaje de Level Up
  creado          timestamptz not null default now(),
  resuelto        timestamptz
);
create index if not exists ordenes_recarga_por_usuario on public.ordenes_recarga (usuario, creado desc);
create index if not exists ordenes_recarga_pendientes on public.ordenes_recarga (creado) where estado = 'pendiente';
-- La misma referencia no se puede usar dos veces (salvo que la orden se haya rechazado)
create unique index if not exists ordenes_recarga_referencia_unica on public.ordenes_recarga (metodo, lower(referencia)) where estado <> 'rechazada';

create table if not exists public.mensajes_recarga (
  id      bigint generated always as identity primary key,
  orden   bigint not null references public.ordenes_recarga (id) on delete cascade,
  autor   uuid references auth.users (id) on delete set null,
  rol     text not null check (rol in ('cliente', 'admin', 'sistema')),
  texto   text not null check (char_length(texto) between 1 and 1000),
  creado  timestamptz not null default now()
);
create index if not exists mensajes_por_orden on public.mensajes_recarga (orden, id);

create table if not exists public.retiros (
  id            bigint generated always as identity primary key,
  vendedor      uuid not null references auth.users (id) on delete restrict,
  monto_usd     numeric(12, 2) not null check (monto_usd > 0),
  comision_usd  numeric(12, 2) not null check (comision_usd >= 0),
  neto_usd      numeric(12, 2) not null check (neto_usd > 0),
  metodo        text not null check (metodo in ('Pago Móvil', 'Binance', 'Zinli', 'Otro')),
  datos         text not null check (char_length(datos) between 5 and 200),
  estado        text not null default 'pendiente' check (estado in ('pendiente', 'pagado', 'rechazado')),
  referencia    text,     -- del pago que hiciste tú
  motivo        text,     -- si lo rechazaste
  creado        timestamptz not null default now(),
  resuelto      timestamptz
);
create index if not exists retiros_por_vendedor on public.retiros (vendedor, creado desc);
create index if not exists retiros_pendientes on public.retiros (creado) where estado = 'pendiente';

create table if not exists public.movimientos_vendedor (
  id             bigint generated always as identity primary key,
  vendedor       uuid not null references auth.users (id) on delete cascade,
  tipo           text not null check (tipo in ('venta', 'retiro', 'retiro_devuelto', 'ajuste')),
  monto          numeric(12, 2) not null,      -- + entra, - sale
  saldo_despues  numeric(12, 2) not null,
  venta          bigint references public.ventas_cuentas (id) on delete set null,
  retiro         bigint references public.retiros (id) on delete set null,
  detalle        text,
  creado         timestamptz not null default now()
);
alter table public.movimientos_vendedor add column if not exists orden bigint references public.ordenes_recarga (id) on delete set null;
alter table public.movimientos_vendedor drop constraint if exists movimientos_vendedor_tipo_check;
alter table public.movimientos_vendedor add constraint movimientos_vendedor_tipo_check
  check (tipo in ('venta', 'retiro', 'retiro_devuelto', 'ajuste', 'recarga', 'recarga_revertida', 'compra', 'reembolso'));
-- Una venta se acredita una sola vez
create unique index if not exists movimientos_vendedor_venta_unica on public.movimientos_vendedor (venta) where tipo = 'venta';
create index if not exists movimientos_vendedor_por_usuario on public.movimientos_vendedor (vendedor, creado desc);

-- ---------------------------------------------------------------------
-- AVISOS: campana de la tienda (en vivo), notificación del navegador y CORREO para lo importante.
-- enlace = hash de index.html ('trato-12', 'recarga-3', 'saldo', 'panel', 'soporte', 'cuenta-5')
--          o 'admin:<pestaña>' para los avisos de administradores (abren admin-cuentas.html).
-- ---------------------------------------------------------------------
create table if not exists public.notificaciones (
  id      bigint generated always as identity primary key,
  usuario uuid not null references auth.users (id) on delete cascade,
  tipo    text not null,
  titulo  text not null check (char_length(titulo) between 1 and 120),
  texto   text not null check (char_length(texto) between 1 and 600),
  enlace  text not null default '',
  leida   boolean not null default false,
  correo  text,          -- null = sin correo; 'enviado', 'sin_config', 'sin_correo', 'apagado' o 'error'
  creado  timestamptz not null default now()
);
create index if not exists notificaciones_por_usuario on public.notificaciones (usuario, id desc);
create index if not exists notificaciones_sin_leer on public.notificaciones (usuario, enlace) where not leida;

-- Preferencias de cada usuario (por ahora: si quiere correos)
create table if not exists public.preferencias (
  usuario  uuid primary key references auth.users (id) on delete cascade,
  correos  boolean not null default true
);

-- Errores de la web que ocurren en el navegador de los clientes (para enterarte sin que te avisen)
create table if not exists public.errores_cliente (
  id         bigint generated always as identity primary key,
  usuario    uuid references auth.users (id) on delete set null,
  pagina     text not null,
  mensaje    text not null,
  detalle    text not null default '',
  navegador  text not null default '',
  veces      int not null default 1,
  creado     timestamptz not null default now(),
  ultimo     timestamptz not null default now()
);
create index if not exists errores_cliente_recientes on public.errores_cliente (ultimo desc);

-- NOTIFICACIONES PUSH: la tienda instalada como app (celular o computadora) recibe los avisos aunque esté cerrada.
-- Cada navegador que activa los avisos guarda aquí su suscripción (es por dispositivo, no por cuenta: al cambiar
-- de usuario se reasigna). Las manda la Edge Function 'enviar-push' con las claves VAPID de sus secretos.
create table if not exists public.push_suscripciones (
  endpoint   text primary key check (endpoint ~ '^https://' and char_length(endpoint) <= 1000),
  usuario    uuid not null references auth.users (id) on delete cascade,
  p256dh     text not null,
  secreto    text not null,
  navegador  text not null default '',
  creado     timestamptz not null default now(),
  usado      timestamptz not null default now()
);
create index if not exists push_suscripciones_por_usuario on public.push_suscripciones (usuario);
-- null = no se intentó; 'pendiente' (pedida a la función), 'enviando', 'enviado', 'sin_dispositivo', 'sin_config', 'caducado' o 'error'
alter table public.notificaciones add column if not exists push text;

-- Escapa texto para meterlo en el HTML de un correo
create or replace function public._html(p text)
returns text language sql immutable set search_path = public as $$
  select replace(replace(replace(replace(coalesce(p, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;');
$$;

-- Envía un correo con Brevo usando pg_net (asíncrono: sale cuando la transacción termina bien).
-- Necesita: extensión pg_net, la clave en Vault ('brevo_api_key') y 'correo_remitente' en Ajustes.
-- Nunca falla: si algo no está configurado devuelve el motivo y el resto del trato sigue.
create or replace function public._enviar_correo(p_para text, p_asunto text, p_texto text, p_enlace text)
returns text language plpgsql security definer set search_path = public as $$
declare
  api_key text; remitente text; nombre text; sitio text; url text; cuerpo text;
begin
  if coalesce(p_para, '') !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or p_para like '%@levelup.invalid' then return 'sin_correo'; end if;
  if to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)') is null or to_regclass('vault.decrypted_secrets') is null then
    return 'sin_config';
  end if;
  select nullif(trim(valor), '') into remitente from mercado_config where clave = 'correo_remitente';
  execute 'select decrypted_secret from vault.decrypted_secrets where name = $1 order by created_at desc limit 1' into api_key using 'brevo_api_key';
  if remitente is null or nullif(trim(coalesce(api_key, '')), '') is null then return 'sin_config'; end if;
  select coalesce(nullif(trim(valor), ''), 'Level Up') into nombre from mercado_config where clave = 'correo_nombre';
  select rtrim(coalesce(nullif(trim(valor), ''), 'https://estesi-blond.vercel.app'), '/') into sitio from mercado_config where clave = 'sitio_url';
  nombre := coalesce(nombre, 'Level Up');
  sitio := coalesce(sitio, 'https://estesi-blond.vercel.app');
  url := case when p_enlace like 'admin:%' then sitio || '/admin-cuentas.html'
              when coalesce(p_enlace, '') = '' then sitio || '/index.html'
              else sitio || '/index.html#' || p_enlace end;
  cuerpo := format(
    '<div style="background:#0b1120;padding:32px 16px;font-family:Arial,Helvetica,sans-serif">'
    || '<div style="max-width:520px;margin:0 auto;background:#0f172a;border:1px solid #1e293b;border-radius:16px;padding:28px">'
    || '<p style="margin:0 0 16px;font-weight:900;letter-spacing:1px;color:#f1f5f9">LEVEL <span style="color:#ff9900">UP</span></p>'
    || '<h1 style="margin:0 0 12px;font-size:20px;color:#f1f5f9">%s</h1>'
    || '<p style="margin:0 0 24px;font-size:15px;line-height:1.6;color:#cbd5e1;white-space:pre-line">%s</p>'
    || '<a href="%s" style="display:inline-block;padding:14px 22px;border-radius:12px;background:#ff9900;color:#0f172a;font-weight:700;text-decoration:none">Abrir Level Up</a>'
    || '<p style="margin:24px 0 0;font-size:12px;line-height:1.5;color:#94a3b8">Te escribimos porque tienes una cuenta en Level Up. Puedes apagar estos correos en Mi panel → Tu cuenta.</p>'
    || '</div></div>',
    _html(p_asunto), _html(p_texto), _html(url));
  execute 'select net.http_post(url := $1, body := $2, params := ''{}''::jsonb, headers := $3, timeout_milliseconds := 8000)'
    using 'https://api.brevo.com/v3/smtp/email',
          jsonb_build_object('sender', jsonb_build_object('email', remitente, 'name', nombre),
                             'to', jsonb_build_array(jsonb_build_object('email', p_para)),
                             'subject', left(p_asunto, 150), 'htmlContent', cuerpo,
                             'textContent', p_texto || E'\n\n' || url),
          jsonb_build_object('api-key', api_key, 'content-type', 'application/json', 'accept', 'application/json');
  return 'enviado';
exception when others then
  return 'error';
end $$;

-- Pide a la Edge Function que mande la notificación push de un aviso (asíncrono con pg_net: sale cuando
-- la transacción termina bien; la función lee el aviso con push_tomar). Nunca falla.
create or replace function public._enviar_push(p_id bigint, p_usuario uuid)
returns text language plpgsql security definer set search_path = public as $$
declare destino text;
begin
  if not exists (select 1 from push_suscripciones where usuario = p_usuario) then return 'sin_dispositivo'; end if;
  select nullif(trim(valor), '') into destino from mercado_config where clave = 'push_url';
  if destino is null or to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)') is null then return 'sin_config'; end if;
  execute 'select net.http_post(url := $1, body := $2, params := ''{}''::jsonb, headers := $3, timeout_milliseconds := 10000)'
    using destino, jsonb_build_object('id', p_id), jsonb_build_object('content-type', 'application/json');
  return 'pendiente';
exception when others then
  return 'error';
end $$;

-- Deja un aviso para un usuario (campana + en vivo + notificación push en sus dispositivos) y, si p_correo, también le escribe por correo.
-- p_agrupar: si ya tiene un aviso SIN LEER del mismo tipo y enlace, no se repite (chats: un aviso por conversación).
create or replace function public._notificar(p_usuario uuid, p_tipo text, p_titulo text, p_texto text, p_enlace text,
                                             p_correo boolean default false, p_agrupar boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare n_id bigint; estado text; para text;
begin
  if p_usuario is null then return; end if;
  if p_agrupar and exists (select 1 from notificaciones where usuario = p_usuario and tipo = p_tipo
                                                         and enlace = coalesce(p_enlace, '') and not leida) then
    return;
  end if;
  insert into notificaciones (usuario, tipo, titulo, texto, enlace)
  values (p_usuario, p_tipo, left(p_titulo, 120), left(p_texto, 600), coalesce(p_enlace, ''))
  returning id into n_id;
  update notificaciones set push = _enviar_push(n_id, p_usuario) where id = n_id;
  if p_correo then
    if exists (select 1 from preferencias where usuario = p_usuario and not correos) then
      estado := 'apagado';
    else
      select email into para from auth.users where id = p_usuario;
      estado := _enviar_correo(para, p_titulo, p_texto, p_enlace);
    end if;
    update notificaciones set correo = estado where id = n_id;
  end if;
end $$;

-- Lo mismo para todos los administradores
create or replace function public._notificar_admins(p_tipo text, p_titulo text, p_texto text, p_enlace text,
                                                    p_correo boolean default false, p_agrupar boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare a uuid;
begin
  for a in select usuario from mercado_admins loop
    perform _notificar(a, p_tipo, p_titulo, p_texto, p_enlace, p_correo, p_agrupar);
  end loop;
end $$;

-- Marca como leídos los avisos del que llama: todos (null), los de un enlace exacto o los que empiezan con un prefijo ('admin:%')
create or replace function public.notificaciones_leer(p_enlace text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'SIN_SESION'; end if;
  update notificaciones set leida = true
   where usuario = auth.uid() and not leida
     and (p_enlace is null or enlace = p_enlace or (p_enlace like '%\%' and enlace like p_enlace));
end $$;

create or replace function public.preferencias_guardar(p_correos boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'SIN_SESION'; end if;
  insert into preferencias (usuario, correos) values (auth.uid(), coalesce(p_correos, true))
  on conflict (usuario) do update set correos = excluded.correos;
end $$;

-- Guarda la suscripción push de ESTE navegador para el usuario que llama (si era de otro usuario, pasa a este)
create or replace function public.push_guardar(p_endpoint text, p_p256dh text, p_secreto text, p_navegador text)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'SIN_SESION'; end if;
  if coalesce(p_endpoint, '') !~ '^https://[^[:space:]]+$' or char_length(p_endpoint) > 1000
     or coalesce(p_p256dh, '') !~ '^[A-Za-z0-9_=+/-]{20,200}$' or coalesce(p_secreto, '') !~ '^[A-Za-z0-9_=+/-]{8,100}$' then
    raise exception 'DATO_INVALIDO';
  end if;
  insert into push_suscripciones (endpoint, usuario, p256dh, secreto, navegador)
  values (p_endpoint, uid, p_p256dh, p_secreto, left(coalesce(p_navegador, ''), 200))
  on conflict (endpoint) do update set usuario = excluded.usuario, p256dh = excluded.p256dh, secreto = excluded.secreto,
                                       navegador = excluded.navegador, usado = now();
  -- Máximo 10 dispositivos por usuario: se quitan los menos usados
  delete from push_suscripciones where usuario = uid
     and endpoint not in (select endpoint from push_suscripciones where usuario = uid order by usado desc limit 10);
end $$;

-- Quita la suscripción de este navegador (al cerrar sesión o desactivar los avisos)
create or replace function public.push_borrar(p_endpoint text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return; end if;
  delete from push_suscripciones where endpoint = p_endpoint and usuario = auth.uid();
end $$;

-- Solo la Edge Function (service_role): toma un aviso pendiente UNA vez y devuelve qué mandar y a qué dispositivos.
-- Si alguien llama a la función con un id cualquiera no pasa nada: cada aviso se manda una sola vez y solo a su dueño.
create or replace function public.push_tomar(p_id bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare n notificaciones;
begin
  if coalesce(auth.role(), '') <> 'service_role' then raise exception 'SOLO_ADMIN'; end if;
  update notificaciones set push = 'enviando'
   where id = p_id and push = 'pendiente' and creado > now() - interval '15 minutes'
  returning * into n;
  if n.id is null then return null; end if;
  return jsonb_build_object(
    'id', n.id, 'titulo', n.titulo, 'texto', n.texto,
    'ruta', case when n.enlace like 'admin:%' then 'admin-cuentas.html' when n.enlace = '' then 'index.html' else 'index.html#' || n.enlace end,
    'etiqueta', 'levelup-' || coalesce(nullif(n.enlace, ''), n.id::text),
    'suscripciones', (select coalesce(jsonb_agg(jsonb_build_object('endpoint', s.endpoint,
                                                                   'keys', jsonb_build_object('p256dh', s.p256dh, 'auth', s.secreto))), '[]'::jsonb)
                        from push_suscripciones s where s.usuario = n.usuario));
end $$;

-- Solo la Edge Function: guarda el resultado y borra los dispositivos que ya no existen (desinstalaron o quitaron el permiso)
create or replace function public.push_resultado(p_id bigint, p_enviados int, p_caducadas text[])
returns void language plpgsql security definer set search_path = public as $$
begin
  if coalesce(auth.role(), '') <> 'service_role' then raise exception 'SOLO_ADMIN'; end if;
  delete from push_suscripciones where endpoint = any (coalesce(p_caducadas, '{}'::text[]));
  update notificaciones
     set push = case when coalesce(p_enviados, 0) > 0 then 'enviado' when cardinality(coalesce(p_caducadas, '{}'::text[])) > 0 then 'caducado' else 'error' end
   where id = p_id and push = 'enviando';
end $$;

-- Cualquier visitante puede reportar un error de la página. Límite: los repetidos se suman y hay un tope por minuto.
create or replace function public.error_registrar(p_pagina text, p_mensaje text, p_detalle text, p_navegador text)
returns void language plpgsql security definer set search_path = public as $$
declare msg text := left(trim(coalesce(p_mensaje, '')), 300); pag text := left(trim(coalesce(p_pagina, '')), 120);
begin
  if msg = '' then return; end if;
  update errores_cliente set veces = veces + 1, ultimo = now()
   where mensaje = msg and pagina = pag and ultimo > now() - interval '1 day';
  if found then return; end if;
  if (select count(*) from errores_cliente where creado > now() - interval '1 minute') >= 30 then return; end if;
  insert into errores_cliente (usuario, pagina, mensaje, detalle, navegador)
  values (auth.uid(), pag, msg, left(coalesce(p_detalle, ''), 1500), left(coalesce(p_navegador, ''), 200));
end $$;

-- ---------------------------------------------------------------------
-- Funciones internas (no se pueden llamar desde el navegador)
-- ---------------------------------------------------------------------
create or replace function public._mensaje_sistema(p_venta bigint, p_texto text)
returns void language sql security definer set search_path = public as $$
  insert into mensajes_venta (venta, autor, rol, texto) values (p_venta, null, 'sistema', left(p_texto, 1000));
$$;

create or replace function public._mover_saldo(p_vendedor uuid, p_monto numeric, p_tipo text, p_venta bigint, p_retiro bigint, p_detalle text)
returns numeric language plpgsql security definer set search_path = public as $$
declare nuevo numeric;
begin
  insert into saldos_vendedor (vendedor) values (p_vendedor) on conflict (vendedor) do nothing;
  update saldos_vendedor
     set disponible = disponible + p_monto,
         ventas = ventas + case when p_tipo = 'venta' then 1 else 0 end,
         actualizado = now()
   where vendedor = p_vendedor
   returning disponible into nuevo;
  -- saldo_despues = saldo total (ventas + recargado)
  insert into movimientos_vendedor (vendedor, tipo, monto, saldo_despues, venta, retiro, detalle)
  select p_vendedor, p_tipo, p_monto, s.disponible + s.recargado, p_venta, p_retiro, p_detalle from saldos_vendedor s where s.vendedor = p_vendedor;
  return nuevo;
end $$;

-- Igual que _mover_saldo pero sobre la parte RECARGADA (solo para comprar). Únicas dos funciones que tocan saldos.
create or replace function public._mover_recargado(p_usuario uuid, p_monto numeric, p_tipo text, p_venta bigint, p_orden bigint, p_detalle text)
returns numeric language plpgsql security definer set search_path = public as $$
declare nuevo numeric; total numeric;
begin
  insert into saldos_vendedor (vendedor) values (p_usuario) on conflict (vendedor) do nothing;
  update saldos_vendedor set recargado = recargado + p_monto, actualizado = now()
   where vendedor = p_usuario
   returning recargado, recargado + disponible into nuevo, total;
  insert into movimientos_vendedor (vendedor, tipo, monto, saldo_despues, venta, orden, detalle)
  values (p_usuario, p_tipo, p_monto, total, p_venta, p_orden, p_detalle);
  return nuevo;
end $$;

create or replace function public._mensaje_recarga(p_orden bigint, p_texto text)
returns void language sql security definer set search_path = public as $$
  insert into mensajes_recarga (orden, autor, rol, texto) values (p_orden, null, 'sistema', left(p_texto, 1000));
$$;

create or replace function public._venta_cerrar(p_venta bigint, p_detalle text)
returns void language plpgsql security definer set search_path = public as $$
declare v ventas_cuentas;
begin
  select * into v from ventas_cuentas where id = p_venta for update;
  if not found or v.estado not in ('pagada', 'entregada', 'en_reclamo') then
    raise exception 'ESTADO_INVALIDO';
  end if;
  perform set_config('mercado.sistema', '1', true);
  update ventas_cuentas set estado = 'cerrada', cerrada_en = now(), actualizado = now(),
         resolucion = coalesce(resolucion, p_detalle) where id = p_venta;
  update cuentas_venta set estado = 'vendida' where id = v.cuenta;
  perform _mover_saldo(v.vendedor, v.precio_usd, 'venta', v.id, null, format('Venta T-%s · %s', v.id, v.titulo));
  perform _mensaje_sistema(p_venta, format('Trato cerrado. %s USD pasaron al saldo del vendedor. %s', v.precio_usd, coalesce(p_detalle, '')));
  perform _notificar(v.vendedor, 'cobro', format('Cobraste %s USD por T-%s', v.precio_usd, v.id),
    format('El trato "%s" se cerró y el precio completo ya está en tu saldo de ventas.%s', v.titulo,
      case when _config_num('dias_liberacion', 3) > 0
           then format(' Puedes usarlo para comprar ya mismo y retirarlo desde el %s.',
                       to_char((now() + make_interval(days => _config_num('dias_liberacion', 3)::int)) at time zone 'America/Caracas', 'DD/MM'))
           else '' end),
    'trato-' || v.id, true);
  perform _notificar(v.comprador, 'calificar', format('Trato T-%s cerrado', v.id),
    format('La cuenta "%s" es tuya. Cuéntales a otros compradores cómo te fue: califica al vendedor.', v.titulo),
    'trato-' || v.id, false);
end $$;

create or replace function public._venta_cancelar(p_venta bigint, p_motivo text, p_estado_cuenta text)
returns void language plpgsql security definer set search_path = public as $$
declare v ventas_cuentas;
begin
  select * into v from ventas_cuentas where id = p_venta for update;
  if not found or v.estado in ('cerrada', 'cancelada') then
    raise exception 'ESTADO_INVALIDO';
  end if;
  perform set_config('mercado.sistema', '1', true);
  update ventas_cuentas set estado = 'cancelada', cerrada_en = now(), actualizado = now(), resolucion = p_motivo where id = p_venta;
  update cuentas_venta
     set estado = p_estado_cuenta,
         motivo_rechazo = case when p_estado_cuenta = 'rechazada' then p_motivo else motivo_rechazo end
   where id = v.cuenta and estado = 'reservada';
  -- Si se pagó con saldo, cada parte vuelve a donde estaba
  if v.pagado_recargado > 0 then
    perform _mover_recargado(v.comprador, v.pagado_recargado, 'reembolso', v.id, null, format('Reembolso del trato T-%s', v.id));
  end if;
  if v.pagado_disponible > 0 then
    perform _mover_saldo(v.comprador, v.pagado_disponible, 'reembolso', v.id, null, format('Reembolso del trato T-%s', v.id));
  end if;
  perform _mensaje_sistema(p_venta, 'Trato cancelado. ' || p_motivo
    || case when v.pagado_recargado + v.pagado_disponible > 0
            then format(' Se devolvieron %s USD al saldo del comprador.', v.pagado_recargado + v.pagado_disponible) else '' end);
  perform _notificar(v.comprador, 'cancelado', format('Trato T-%s cancelado', v.id),
    p_motivo || case when v.pagado_recargado + v.pagado_disponible > 0
                     then format(E'\nTe devolvimos %s USD a tu saldo.', v.pagado_recargado + v.pagado_disponible) else '' end,
    'trato-' || v.id, true);
  perform _notificar(v.vendedor, 'cancelado', format('Trato T-%s cancelado', v.id),
    format('El trato por "%s" se canceló: %s', v.titulo, p_motivo)
    || case when p_estado_cuenta = 'pausada' then E'\nTu publicación quedó pausada: reanúdala en Mi panel cuando puedas entregar.' else '' end,
    'trato-' || v.id, true);
end $$;

-- Rol de quien llama dentro de un trato (o null si no participa)
create or replace function public._rol_en_venta(v ventas_cuentas)
returns text language sql stable security definer set search_path = public as $$
  select case when v.comprador = auth.uid() then 'comprador'
              when v.vendedor = auth.uid() then 'vendedor'
              when public.es_admin() then 'admin' end;
$$;

-- ---------------------------------------------------------------------
-- Mantenimiento: vence tratos sin pago y cierra los entregados sin reclamo.
-- Corre solo cada 10 min si pg_cron está activo (abajo); además lo llaman las funciones y la página.
-- ---------------------------------------------------------------------
create or replace function public.mercado_mantenimiento()
returns void language plpgsql security definer set search_path = public as $$
declare r record;
begin
  for r in select id from ventas_cuentas
            where estado = 'pendiente_pago' and pago_informado_en is null
              and creado < now() - make_interval(hours => _config_num('horas_pago', 2)::int)
            for update skip locked loop
    perform _venta_cancelar(r.id, 'No se informó el pago a tiempo.', 'publicada');
  end loop;
  for r in select id from ventas_cuentas
            where estado = 'entregada'
              and entregada_en < now() - make_interval(hours => _config_num('horas_revision', 24)::int)
            for update skip locked loop
    perform _venta_cerrar(r.id, 'Cierre automático: pasó el tiempo de revisión sin reclamo.');
  end loop;
  -- El vendedor no entregó a tiempo (y nadie llamó a Level Up): se devuelve el dinero y la publicación queda pausada
  if _config_num('horas_entrega', 12) > 0 then
    for r in select id from ventas_cuentas
              where estado = 'pagada' and apelada_en is null
                and coalesce(pagada_en, creado) < now() - make_interval(mins => (_config_num('horas_entrega', 12) * 60)::int)
              for update skip locked loop
      perform _venta_cancelar(r.id, format('El vendedor no entregó los datos en %s h. Se cancela solo.', _config_num('horas_entrega', 12)), 'pausada');
    end loop;
  end if;
end $$;

-- Lo cobrado por ventas que todavía no se puede RETIRAR (cerradas hace menos de `dias_liberacion` días).
-- Sirve para comprar igual. Si el usuario ya gastó parte, lo retenido nunca supera su saldo de ventas.
create or replace function public._ventas_por_liberar(p_usuario uuid)
returns numeric language sql stable security definer set search_path = public as $$
  select least(
    coalesce((select disponible from saldos_vendedor where vendedor = p_usuario), 0),
    coalesce((select sum(precio_usd) from ventas_cuentas
               where vendedor = p_usuario and estado = 'cerrada'
                 and cerrada_en > now() - make_interval(days => _config_num('dias_liberacion', 3)::int)), 0));
$$;

-- Saldo del que llama: cuánto puede retirar ya y cuándo se libera lo demás
create or replace function public.mi_saldo()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare s saldos_vendedor; retenido numeric; dias int := _config_num('dias_liberacion', 3)::int;
begin
  if auth.uid() is null then raise exception 'SIN_SESION'; end if;
  select * into s from saldos_vendedor where vendedor = auth.uid();
  retenido := _ventas_por_liberar(auth.uid());
  return jsonb_build_object(
    'disponible', coalesce(s.disponible, 0),
    'recargado', coalesce(s.recargado, 0),
    'por_liberar', retenido,
    'retirable', greatest(coalesce(s.disponible, 0) - retenido, 0),
    'dias_liberacion', dias,
    'proxima_liberacion', (select min(cerrada_en) + make_interval(days => dias) from ventas_cuentas
                            where vendedor = auth.uid() and estado = 'cerrada' and cerrada_en > now() - make_interval(days => dias)));
end $$;

-- ---------------------------------------------------------------------
-- Funciones del COMPRADOR
-- ---------------------------------------------------------------------
-- Comprar = pagar con saldo al instante: primero lo recargado, luego lo ganado en ventas. El dinero queda retenido.
create or replace function public.venta_crear(p_cuenta bigint, p_garantia boolean default false)
returns bigint language plpgsql security definer set search_path = public as $$
declare c cuentas_venta; s saldos_vendedor; v_id bigint; extra numeric; total numeric; de_recarga numeric; de_ventas numeric;
begin
  if auth.uid() is null then raise exception 'SIN_SESION'; end if;
  perform mercado_mantenimiento();
  select * into c from cuentas_venta where id = p_cuenta for update;
  if not found or c.estado <> 'publicada' then raise exception 'NO_DISPONIBLE'; end if;
  if c.vendedor = auth.uid() then raise exception 'ES_TUYA'; end if;

  extra := case when p_garantia then _config_num('garantia_usd', 1) else 0 end;
  total := c.precio_usd + extra;
  insert into saldos_vendedor (vendedor) values (auth.uid()) on conflict (vendedor) do nothing;
  select * into s from saldos_vendedor where vendedor = auth.uid() for update;
  if s.recargado + s.disponible < total then raise exception 'SALDO_COMPRA'; end if;
  de_recarga := least(s.recargado, total);
  de_ventas := total - de_recarga;

  perform set_config('mercado.sistema', '1', true);
  update cuentas_venta set estado = 'reservada' where id = c.id;
  insert into ventas_cuentas (cuenta, comprador, vendedor, titulo, precio_usd, garantia, total_usd, estado,
                              metodo_pago, pago_informado_en, pagada_en, pagado_recargado, pagado_disponible)
  values (c.id, auth.uid(), c.vendedor, c.titulo, c.precio_usd, coalesce(p_garantia, false), total, 'pagada',
          'Saldo', now(), now(), de_recarga, de_ventas)
  returning id into v_id;
  if de_recarga > 0 then
    perform _mover_recargado(auth.uid(), -de_recarga, 'compra', v_id, null, format('Compra T-%s · %s', v_id, c.titulo));
  end if;
  if de_ventas > 0 then
    perform _mover_saldo(auth.uid(), -de_ventas, 'compra', v_id, null, format('Compra T-%s · %s', v_id, c.titulo));
  end if;
  perform _mensaje_sistema(v_id, format(
    'Trato T-%s por la cuenta FF-%s. El comprador pagó %s USD con su saldo%s y Level Up los RETIENE hasta el cierre. VENDEDOR: entrega aquí el correo/usuario y la contraseña de la cuenta y luego toca "Ya entregué los datos". Nadie debe entregar datos fuera de este chat.',
    v_id, c.id, total, case when p_garantia then ' (incluye Garantía Extendida)' else '' end));
  perform _notificar(c.vendedor, 'venta', format('¡Vendiste FF-%s! Entrega los datos', c.id),
    format(E'Alguien compró "%s" por %s USD y Level Up retiene el dinero.\nEntra al chat del trato T-%s y entrega el correo/usuario y la contraseña%s.',
      c.titulo, c.precio_usd, v_id,
      case when _config_num('horas_entrega', 12) > 0
           then format(' antes de %s h, o el trato se cancela solo y el dinero vuelve al comprador', _config_num('horas_entrega', 12))
           else '' end),
    'trato-' || v_id, true);
  return v_id;
end $$;

-- Pago manual de antes del saldo: ya no existe (se compra con saldo al instante)
drop function if exists public.venta_informar_pago(bigint, text, text);
drop function if exists public.admin_confirmar_pago(bigint);

create or replace function public.venta_finalizar(p_venta bigint)
returns void language plpgsql security definer set search_path = public as $$
declare v ventas_cuentas;
begin
  select * into v from ventas_cuentas where id = p_venta for update;
  if not found or v.comprador is distinct from auth.uid() then raise exception 'NO_PERMITIDO'; end if;
  if v.estado <> 'entregada' then raise exception 'ESTADO_INVALIDO'; end if;
  perform _venta_cerrar(p_venta, 'El comprador confirmó que recibió la cuenta.');
end $$;

create or replace function public.venta_reclamar(p_venta bigint, p_motivo text, p_video text)
returns void language plpgsql security definer set search_path = public as $$
declare v ventas_cuentas;
begin
  select * into v from ventas_cuentas where id = p_venta for update;
  if not found or v.comprador is distinct from auth.uid() then raise exception 'NO_PERMITIDO'; end if;
  if v.estado <> 'entregada' then raise exception 'ESTADO_INVALIDO'; end if;
  if v.entregada_en < now() - make_interval(hours => _config_num('horas_revision', 24)::int) then raise exception 'FUERA_DE_PLAZO'; end if;
  if char_length(trim(coalesce(p_motivo, ''))) not between 10 and 600 then raise exception 'DATO_INVALIDO'; end if;
  -- (Postgres no acepta repeticiones {n,m} mayores a 255: el largo se revisa aparte)
  if coalesce(p_video, '') !~ '^https://[^\s]{6,}$' or char_length(p_video) > 300 then raise exception 'VIDEO_REQUERIDO'; end if;
  update ventas_cuentas set estado = 'en_reclamo', reclamo_motivo = trim(p_motivo), reclamo_video = p_video, actualizado = now()
   where id = p_venta;
  perform _mensaje_sistema(p_venta, 'El comprador abrió un reclamo con video. Level Up lo revisará y decidirá. El dinero sigue retenido.');
  perform _notificar(v.vendedor, 'reclamo', format('Reclamo en el trato T-%s', p_venta),
    format(E'El comprador de "%s" abrió un reclamo: %s\nLevel Up revisará el video y decidirá. Responde en el chat del trato.', v.titulo, trim(p_motivo)),
    'trato-' || p_venta, true);
  perform _notificar_admins('reclamo', format('Reclamo nuevo · T-%s', p_venta),
    format(E'"%s" (%s USD)\nMotivo: %s', v.titulo, v.total_usd, trim(p_motivo)), 'admin:tratos', true);
end $$;

-- El comprador puede cancelar mientras no haya pagado (o mientras Level Up no haya confirmado el pago)
create or replace function public.venta_cancelar(p_venta bigint)
returns void language plpgsql security definer set search_path = public as $$
declare v ventas_cuentas;
begin
  select * into v from ventas_cuentas where id = p_venta for update;
  if not found or v.comprador is distinct from auth.uid() then raise exception 'NO_PERMITIDO'; end if;
  if v.estado <> 'pendiente_pago' then raise exception 'ESTADO_INVALIDO'; end if;
  perform _venta_cancelar(p_venta, 'El comprador canceló antes de que se confirmara el pago.', 'publicada');
end $$;

-- ---------------------------------------------------------------------
-- Funciones del VENDEDOR
-- ---------------------------------------------------------------------
create or replace function public.venta_entregar(p_venta bigint)
returns void language plpgsql security definer set search_path = public as $$
declare v ventas_cuentas;
begin
  select * into v from ventas_cuentas where id = p_venta for update;
  if not found or v.vendedor is distinct from auth.uid() then raise exception 'NO_PERMITIDO'; end if;
  if v.estado <> 'pagada' then raise exception 'ESTADO_INVALIDO'; end if;
  update ventas_cuentas set estado = 'entregada', entregada_en = now(), actualizado = now() where id = p_venta;
  perform _mensaje_sistema(p_venta, format(
    'El vendedor marcó los datos como entregados. COMPRADOR: graba la pantalla SIN CORTES desde que uses los datos (máx. 5 min después de este mensaje). Tienes %s h para tocar "Todo bien, finalizar" o "Tengo un problema"; si no, el trato se cierra solo.',
    _config_num('horas_revision', 24)));
  perform _notificar(v.comprador, 'entrega', format('Te entregaron los datos · T-%s', p_venta),
    format(E'El vendedor de "%s" escribió los datos en el chat del trato.\nGRABA LA PANTALLA SIN CORTES desde que los uses. Tienes %s h para finalizar o reclamar; si no, se cierra solo.',
      v.titulo, _config_num('horas_revision', 24)),
    'trato-' || p_venta, true);
end $$;

create or replace function public.retiro_solicitar(p_monto numeric, p_metodo text, p_datos text)
returns bigint language plpgsql security definer set search_path = public as $$
declare s saldos_vendedor; r_id bigint; comision numeric; monto numeric := round(p_monto, 2);
begin
  if auth.uid() is null then raise exception 'SIN_SESION'; end if;
  if p_metodo not in ('Pago Móvil', 'Binance', 'Zinli', 'Otro') then raise exception 'DATO_INVALIDO'; end if;
  if char_length(trim(coalesce(p_datos, ''))) not between 5 and 200 then raise exception 'DATO_INVALIDO'; end if;
  if monto is null or monto < _config_num('retiro_minimo', 5) then raise exception 'RETIRO_MINIMO'; end if;
  if exists (select 1 from retiros where vendedor = auth.uid() and estado = 'pendiente') then raise exception 'RETIRO_PENDIENTE'; end if;
  select * into s from saldos_vendedor where vendedor = auth.uid() for update;
  if not found or s.disponible < monto then raise exception 'SALDO_INSUFICIENTE'; end if;
  -- Lo de ventas recientes se libera después de `dias_liberacion` días (protege si el dueño anterior recupera la cuenta)
  if s.disponible - _ventas_por_liberar(auth.uid()) < monto then raise exception 'SALDO_RETENIDO'; end if;

  comision := round(monto * _config_num('comision_retiro', 4) / 100, 2);
  insert into retiros (vendedor, monto_usd, comision_usd, neto_usd, metodo, datos)
  values (auth.uid(), monto, comision, monto - comision, p_metodo, trim(p_datos))
  returning id into r_id;
  perform _mover_saldo(auth.uid(), -monto, 'retiro', null, r_id, format('Retiro R-%s (%s USD - %s USD de comisión)', r_id, monto, comision));
  perform _notificar_admins('retiro', format('Retiro pedido · R-%s', r_id),
    format('%s USD por %s (recibe %s USD). Se paga el lunes.', monto, p_metodo, monto - comision), 'admin:retiros', true, true);
  return r_id;
end $$;

-- ---------------------------------------------------------------------
-- RECARGAS DE SALDO (cualquier usuario): pagó por fuera y sube captura + referencia; un admin aprueba.
-- La captura se sube antes al bucket privado "comprobantes", en la carpeta <su id>/.
-- ---------------------------------------------------------------------
create or replace function public.recarga_crear(p_metodo text, p_monto numeric, p_referencia text, p_captura text)
returns bigint language plpgsql security definer set search_path = public as $$
declare
  o_id bigint; monto numeric := round(p_monto, 2); pagar numeric; bs numeric; tasa numeric;
  ref text := upper(regexp_replace(coalesce(p_referencia, ''), '\s', '', 'g'));
  nombre text;
begin
  if auth.uid() is null then raise exception 'SIN_SESION'; end if;
  -- Solo los métodos que configuraste en el admin
  if p_metodo = 'binance' and nullif(trim((select valor from mercado_config where clave = 'binance_pay_id')), '') is not null then nombre := 'Binance';
  elsif p_metodo = 'paypal' and nullif(trim((select valor from mercado_config where clave = 'paypal_correo')), '') is not null then nombre := 'PayPal';
  elsif p_metodo = 'pago_movil' and nullif(trim((select valor from mercado_config where clave = 'pm_telefono')), '') is not null then nombre := 'Pago Móvil';
  else raise exception 'METODO_NO_DISPONIBLE';
  end if;
  if monto is null or monto < _config_num('recarga_minima', 1) or monto > 2000 then raise exception 'RECARGA_MONTO'; end if;
  if ref !~ '^[A-Z0-9-]{4,40}$' then raise exception 'DATO_INVALIDO'; end if;
  if coalesce(p_captura, '') !~ ('^' || auth.uid()::text || '/[A-Za-z0-9_-]{8,64}\.(webp|jpg|jpeg|png)$')
     or not exists (select 1 from storage.objects where bucket_id = 'comprobantes' and name = p_captura) then
    raise exception 'CAPTURA_REQUERIDA';
  end if;
  if (select count(*) from ordenes_recarga where usuario = auth.uid() and estado = 'pendiente') >= 3 then
    raise exception 'DEMASIADAS_RECARGAS';
  end if;

  pagar := case when p_metodo = 'paypal' then round(monto * (1 + _config_num('paypal_recargo', 0) / 100), 2) else monto end;
  tasa := _config_num('tasa_bs', 0);
  bs := case when p_metodo = 'pago_movil' and tasa > 0 then round(monto * tasa, 2) end;
  begin
    insert into ordenes_recarga (usuario, metodo, monto_usd, monto_pagar, monto_bs, referencia, captura)
    values (auth.uid(), p_metodo, monto, pagar, bs, ref, p_captura)
    returning id into o_id;
  exception when unique_violation then
    raise exception 'REFERENCIA_USADA';
  end;
  perform _mensaje_recarga(o_id, format('Orden RC-%s recibida: %s USD por %s (referencia %s). Level Up la está verificando y te avisa aquí. Si tienes una duda, escríbela en este chat.',
    o_id, monto, nombre, ref));
  perform _notificar_admins('recarga', format('Recarga por aprobar · RC-%s', o_id),
    format('%s USD por %s (referencia %s). Revisa la captura y apruébala.', monto, nombre, ref), 'admin:recargas', true, true);
  return o_id;
end $$;

-- Chat de una orden de recarga (el dueño de la orden y los admins)
create or replace function public.recarga_mensaje(p_orden bigint, p_texto text)
returns bigint language plpgsql security definer set search_path = public as $$
declare o ordenes_recarga; rol text; m_id bigint; texto text := trim(coalesce(p_texto, ''));
begin
  select * into o from ordenes_recarga where id = p_orden;
  if not found then raise exception 'NO_PERMITIDO'; end if;
  rol := case when o.usuario = auth.uid() then 'cliente' when public.es_admin() then 'admin' end;
  if rol is null then raise exception 'NO_PERMITIDO'; end if;
  if char_length(texto) not between 1 and 1000 then raise exception 'DATO_INVALIDO'; end if;
  if (select count(*) from mensajes_recarga where autor = auth.uid() and creado > now() - interval '1 minute') >= 20 then
    raise exception 'DEMASIADOS_MENSAJES';
  end if;
  insert into mensajes_recarga (orden, autor, rol, texto) values (p_orden, auth.uid(), rol, texto) returning id into m_id;
  if rol = 'cliente' then
    update ordenes_recarga set msg_cliente = now() where id = p_orden;
    perform _notificar_admins('chat', 'Mensaje nuevo en una recarga', format('RC-%s · %s USD: el cliente te escribió en el chat.', p_orden, o.monto_usd),
      'admin:chats', true, true);
  else
    update ordenes_recarga set msg_admin = now() where id = p_orden;
    perform _notificar(o.usuario, 'mensaje', format('Level Up te respondió · RC-%s', p_orden),
      'Tienes un mensaje nuevo de Level Up sobre tu recarga.', 'recarga-' || p_orden, true, true);
  end if;
  return m_id;
end $$;

-- ---------------------------------------------------------------------
-- Chat del trato (comprador, vendedor y admins)
-- ---------------------------------------------------------------------
create or replace function public.mensaje_enviar(p_venta bigint, p_texto text)
returns bigint language plpgsql security definer set search_path = public as $$
declare v ventas_cuentas; rol text; m_id bigint; recientes int; texto text := trim(coalesce(p_texto, ''));
begin
  select * into v from ventas_cuentas where id = p_venta;
  if not found then raise exception 'NO_PERMITIDO'; end if;
  rol := _rol_en_venta(v);
  if rol is null then raise exception 'NO_PERMITIDO'; end if;
  if v.estado in ('cerrada', 'cancelada') and rol <> 'admin' then raise exception 'CHAT_CERRADO'; end if;
  if char_length(texto) not between 1 and 1000 then raise exception 'DATO_INVALIDO'; end if;
  select count(*) into recientes from mensajes_venta where autor = auth.uid() and creado > now() - interval '1 minute';
  if recientes >= 20 then raise exception 'DEMASIADOS_MENSAJES'; end if;
  insert into mensajes_venta (venta, autor, rol, texto) values (p_venta, auth.uid(), rol, texto) returning id into m_id;
  if rol = 'admin' and v.apelada_en is not null then
    update ventas_cuentas set apelada_en = null, apelada_por = null where id = p_venta;
  end if;
  -- Aviso a los demás del trato (sin copiar el texto: puede llevar datos de acceso). Uno por conversación sin leer.
  if rol <> 'comprador' then
    perform _notificar(v.comprador, 'mensaje', format('Mensaje nuevo · T-%s', p_venta),
      format('%s te escribió en el chat del trato "%s".', case rol when 'admin' then 'Level Up' else 'El vendedor' end, v.titulo),
      'trato-' || p_venta, true, true);
  end if;
  if rol <> 'vendedor' then
    perform _notificar(v.vendedor, 'mensaje', format('Mensaje nuevo · T-%s', p_venta),
      format('%s te escribió en el chat del trato "%s".', case rol when 'admin' then 'Level Up' else 'El comprador' end, v.titulo),
      'trato-' || p_venta, true, true);
  end if;
  return m_id;
end $$;

-- ---------------------------------------------------------------------
-- CHAT DE SOPORTE EN VIVO: una conversación por usuario con Level Up (botón de chat de la tienda).
-- Los mensajes llegan al instante con Supabase Realtime (ver el final del archivo).
-- ---------------------------------------------------------------------
create table if not exists public.soporte_chats (
  usuario       uuid primary key references auth.users (id) on delete cascade,
  ultimo_texto  text,
  ultimo_rol    text,
  msg_cliente   timestamptz,     -- último mensaje del cliente
  msg_admin     timestamptz,     -- última respuesta de Level Up
  actualizado   timestamptz not null default now()
);
create index if not exists soporte_chats_recientes on public.soporte_chats (actualizado desc);

create table if not exists public.mensajes_soporte (
  id       bigint generated always as identity primary key,
  usuario  uuid not null references auth.users (id) on delete cascade,   -- dueño de la conversación
  autor    uuid references auth.users (id) on delete set null,
  rol      text not null check (rol in ('cliente', 'admin', 'sistema')),
  texto    text not null check (char_length(texto) between 1 and 1000),
  creado   timestamptz not null default now()
);
create index if not exists mensajes_soporte_por_usuario on public.mensajes_soporte (usuario, id);

-- El cliente escribe en SU conversación (p_usuario = su id o null); un admin responde en la de p_usuario.
create or replace function public.soporte_mensaje(p_usuario uuid, p_texto text)
returns bigint language plpgsql security definer set search_path = public as $$
declare conv uuid := coalesce(p_usuario, auth.uid()); rol text; m_id bigint; texto text := trim(coalesce(p_texto, ''));
begin
  if auth.uid() is null then raise exception 'SIN_SESION'; end if;
  rol := case when conv = auth.uid() then 'cliente' when public.es_admin() then 'admin' end;
  if rol is null then raise exception 'NO_PERMITIDO'; end if;
  if char_length(texto) not between 1 and 1000 then raise exception 'DATO_INVALIDO'; end if;
  if (select count(*) from mensajes_soporte where autor = auth.uid() and creado > now() - interval '1 minute') >= 20 then
    raise exception 'DEMASIADOS_MENSAJES';
  end if;
  insert into mensajes_soporte (usuario, autor, rol, texto) values (conv, auth.uid(), rol, texto) returning id into m_id;
  insert into soporte_chats (usuario) values (conv) on conflict (usuario) do nothing;
  update soporte_chats
     set ultimo_texto = left(texto, 200), ultimo_rol = rol, actualizado = now(),
         msg_cliente = case when rol = 'cliente' then now() else msg_cliente end,
         msg_admin = case when rol = 'admin' then now() else msg_admin end
   where usuario = conv;
  if rol = 'admin' then
    perform _notificar(conv, 'soporte', 'Level Up te respondió', 'Tienes una respuesta nueva en el chat de soporte.', 'soporte', true, true);
  else
    perform _notificar_admins('chat', 'Mensaje nuevo en soporte', left(texto, 200), 'admin:chats', true, true);
  end if;
  return m_id;
end $$;

-- Bandeja del admin: todas las conversaciones (soporte, recargas y tratos) ordenadas por el último mensaje.
-- sin_responder = el último en escribir fue el cliente (en tratos: solo si hay un reclamo abierto y Level Up no fue el último).
create or replace function public.admin_bandeja(p_limite int default 80)
returns table (tipo text, ref bigint, usuario uuid, titulo text, ultimo_texto text, ultimo_rol text, ultimo_en timestamptz, sin_responder boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  perform _exigir_admin();
  return query
  select * from (
    select 'soporte'::text, null::bigint, s.usuario, 'Soporte'::text, s.ultimo_texto, s.ultimo_rol, s.actualizado,
           coalesce(s.msg_cliente > coalesce(s.msg_admin, '-infinity'::timestamptz), false)
      from soporte_chats s
    union all
    select 'recarga', o.id, o.usuario, format('Recarga RC-%s · %s USD', o.id, o.monto_usd), m.texto, m.rol, m.creado,
           coalesce(o.msg_cliente > coalesce(o.msg_admin, '-infinity'::timestamptz), false)
      from ordenes_recarga o
      join lateral (select x.texto, x.rol, x.creado from mensajes_recarga x where x.orden = o.id and x.rol <> 'sistema' order by x.id desc limit 1) m on true
    union all
    select 'trato', v.id, v.comprador, format('Trato T-%s · %s', v.id, v.titulo), m.texto, m.rol, m.creado,
           (v.apelada_en is not null or v.estado = 'en_reclamo') and m.rol <> 'admin'
      from ventas_cuentas v
      join lateral (select x.texto, x.rol, x.creado from mensajes_venta x where x.venta = v.id and (x.rol <> 'sistema' or x.texto like 'APELACIÓN:%') order by x.id desc limit 1) m on true
  ) b
  order by 7 desc
  limit least(greatest(coalesce(p_limite, 80), 1), 200);
end $$;

-- ---------------------------------------------------------------------
-- PERFILES PÚBLICOS: nombre visible (único) y una descripción corta. El correo nunca se muestra.
-- ---------------------------------------------------------------------
create table if not exists public.perfiles (
  usuario      uuid primary key references auth.users (id) on delete cascade,
  nombre       text not null,
  descripcion  text not null default '' check (char_length(descripcion) <= 160),
  creado       timestamptz not null default now(),
  actualizado  timestamptz not null default now()
);
create unique index if not exists perfiles_nombre_unico on public.perfiles (lower(nombre));

create or replace function public.perfil_guardar(p_nombre text, p_descripcion text)
returns void language plpgsql security definer set search_path = public as $$
declare nombre text := regexp_replace(trim(coalesce(p_nombre, '')), '\s+', ' ', 'g');
begin
  if auth.uid() is null then raise exception 'SIN_SESION'; end if;
  -- Letras (con acentos), números, espacio, punto, guion y guion bajo; de 3 a 24
  if char_length(nombre) not between 3 and 24 or nombre !~ '^[[:alnum:]áéíóúüñÁÉÍÓÚÜÑ ._-]+$' then raise exception 'NOMBRE_INVALIDO'; end if;
  if lower(nombre) ~ '(level ?up|admin|soporte|moderador)' and not public.es_admin() then raise exception 'NOMBRE_RESERVADO'; end if;
  insert into perfiles (usuario, nombre, descripcion) values (auth.uid(), nombre, left(trim(coalesce(p_descripcion, '')), 160))
  on conflict (usuario) do update set nombre = excluded.nombre, descripcion = excluded.descripcion, actualizado = now();
exception when unique_violation then
  raise exception 'NOMBRE_USADO';
end $$;

-- Perfil público de un usuario: nombre, estrellas, ventas, desde cuándo, opiniones y cuentas publicadas
create or replace function public.mercado_perfil(p_usuario uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'usuario', p_usuario,
    'nombre', (select nombre from perfiles where usuario = p_usuario),
    'descripcion', (select descripcion from perfiles where usuario = p_usuario),
    'miembro_desde', (select created_at from auth.users where id = p_usuario),
    'ventas', coalesce((select ventas from saldos_vendedor where vendedor = p_usuario), 0),
    'compras', (select count(*) from ventas_cuentas where comprador = p_usuario and estado = 'cerrada'),
    'estrellas', (select round(avg(estrellas), 1) from calificaciones where vendedor = p_usuario),
    'opiniones', (select count(*) from calificaciones where vendedor = p_usuario),
    'reparto', (select coalesce(jsonb_object_agg(estrellas, n), '{}'::jsonb) from (select estrellas, count(*) n from calificaciones where vendedor = p_usuario group by estrellas) x),
    'ultimas', (select coalesce(jsonb_agg(jsonb_build_object('estrellas', c.estrellas, 'comentario', c.comentario, 'creado', c.creado,
                                                              'comprador', coalesce(pf.nombre, 'Comprador')) order by c.creado desc), '[]'::jsonb)
                  from (select * from calificaciones where vendedor = p_usuario order by creado desc limit 10) c
                  left join perfiles pf on pf.usuario = c.comprador),
    'publicadas', (select count(*) from cuentas_venta where vendedor = p_usuario and estado = 'publicada')
  ) where exists (select 1 from auth.users where id = p_usuario);
$$;

-- DIRECTORIO DE VENDEDORES (público): solo quien tiene cuentas a la venta o ya vendió alguna.
-- p_orden: 'estrellas' (mejor calificados), 'ventas' (más ventas) o 'recientes'.
create or replace function public.mercado_vendedores(p_texto text default '', p_orden text default 'estrellas')
returns table (usuario uuid, nombre text, descripcion text, ventas int, estrellas numeric, opiniones int, publicadas int, miembro_desde timestamptz)
language sql stable security definer set search_path = public as $$
  with vendedores as (
    select u.id,
           coalesce((select s.ventas from saldos_vendedor s where s.vendedor = u.id), 0) as ventas,
           (select count(*)::int from cuentas_venta c where c.vendedor = u.id and c.estado = 'publicada') as publicadas,
           (select round(avg(k.estrellas), 1) from calificaciones k where k.vendedor = u.id) as estrellas,
           (select count(*)::int from calificaciones k where k.vendedor = u.id) as opiniones,
           u.created_at
      from auth.users u
     where (exists (select 1 from cuentas_venta c where c.vendedor = u.id and c.estado in ('publicada', 'reservada', 'vendida'))
            or exists (select 1 from saldos_vendedor s where s.vendedor = u.id and s.ventas > 0))
       and coalesce(u.email, '') not like '%@levelup.invalid'    -- cuentas borradas por su dueño
  )
  select v.id, pf.nombre, coalesce(pf.descripcion, ''), v.ventas, v.estrellas, v.opiniones, v.publicadas, v.created_at
    from vendedores v
    left join perfiles pf on pf.usuario = v.id
   where coalesce(trim(p_texto), '') = ''
      or lower(coalesce(pf.nombre, '')) like '%' || replace(replace(lower(trim(p_texto)), '%', ''), '_', '\_') || '%'
   order by
     case when p_orden = 'ventas' then v.ventas end desc nulls last,
     case when p_orden = 'recientes' then v.created_at end desc nulls last,
     case when coalesce(p_orden, 'estrellas') = 'estrellas' then coalesce(v.estrellas, 0) end desc nulls last,
     v.opiniones desc, v.ventas desc, v.publicadas desc
   limit 60;
$$;

-- APELACIÓN: el comprador o el vendedor pide que Level Up entre al chat del trato (uno a la vez)
create or replace function public.venta_apelar(p_venta bigint, p_motivo text)
returns void language plpgsql security definer set search_path = public as $$
declare v ventas_cuentas; rol text; motivo text := left(trim(coalesce(p_motivo, '')), 300);
begin
  select * into v from ventas_cuentas where id = p_venta for update;
  if not found then raise exception 'NO_PERMITIDO'; end if;
  rol := case when v.comprador = auth.uid() then 'comprador' when v.vendedor = auth.uid() then 'vendedor' end;
  if rol is null then raise exception 'NO_PERMITIDO'; end if;
  if v.estado in ('cerrada', 'cancelada') then raise exception 'CHAT_CERRADO'; end if;
  if v.apelada_en is not null then raise exception 'APELACION_ACTIVA'; end if;
  if char_length(motivo) < 5 then raise exception 'DATO_INVALIDO'; end if;
  update ventas_cuentas set apelada_en = now(), apelada_por = rol, actualizado = now() where id = p_venta;
  perform _mensaje_sistema(p_venta, format('APELACIÓN: el %s llamó a Level Up. Motivo: %s. Un administrador entrará a este chat; mientras tanto no entreguen ni cambien nada.', rol, motivo));
  perform _notificar_admins('apelacion', format('Te llamaron al trato T-%s', p_venta),
    format(E'El %s de "%s" pide ayuda: %s', rol, v.titulo, motivo), 'admin:tratos', true);
  perform _notificar(case when rol = 'comprador' then v.vendedor else v.comprador end, 'mensaje', format('Level Up fue llamado · T-%s', p_venta),
    format('El %s llamó a Level Up al chat del trato "%s". Un administrador entrará en breve.', rol, v.titulo), 'trato-' || p_venta, true, true);
end $$;

-- El comprador califica al vendedor cuando el trato se cerró (una sola vez)
create or replace function public.venta_calificar(p_venta bigint, p_estrellas int, p_comentario text)
returns void language plpgsql security definer set search_path = public as $$
declare v ventas_cuentas;
begin
  select * into v from ventas_cuentas where id = p_venta;
  if not found or v.comprador is distinct from auth.uid() then raise exception 'NO_PERMITIDO'; end if;
  if v.estado <> 'cerrada' then raise exception 'ESTADO_INVALIDO'; end if;
  if p_estrellas is null or p_estrellas not between 1 and 5 then raise exception 'DATO_INVALIDO'; end if;
  insert into calificaciones (venta, vendedor, comprador, estrellas, comentario)
  values (p_venta, v.vendedor, v.comprador, p_estrellas, left(trim(coalesce(p_comentario, '')), 300));
exception when unique_violation then
  raise exception 'YA_CALIFICADO';
end $$;

-- Reputación pública: ventas cerradas y estrellas de cada vendedor (sin datos personales)
drop function if exists public.mercado_reputacion(uuid[]);
create or replace function public.mercado_reputacion(p_vendedores uuid[])
returns table (vendedor uuid, ventas int, estrellas numeric, opiniones int, nombre text) language sql stable security definer set search_path = public as $$
  select u.v, coalesce(s.ventas, 0), round(avg(c.estrellas), 1), count(c.venta)::int, pf.nombre
    from unnest(p_vendedores[1:100]) as u(v)
    left join saldos_vendedor s on s.vendedor = u.v
    left join calificaciones c on c.vendedor = u.v
    left join perfiles pf on pf.usuario = u.v
   group by u.v, s.ventas, pf.nombre;
$$;

-- Últimas opiniones de un vendedor (públicas, sin datos del comprador)
create or replace function public.mercado_opiniones(p_vendedor uuid)
returns table (estrellas smallint, comentario text, creado timestamptz) language sql stable security definer set search_path = public as $$
  select c.estrellas, c.comentario, c.creado from calificaciones c where c.vendedor = p_vendedor order by c.creado desc limit 5;
$$;

-- ---------------------------------------------------------------------
-- Funciones de ADMIN
-- ---------------------------------------------------------------------
create or replace function public._exigir_admin()
returns void language plpgsql stable security definer set search_path = public as $$
begin
  if not public.es_admin() then raise exception 'SOLO_ADMIN'; end if;
end $$;

create or replace function public.admin_moderar_cuenta(p_cuenta bigint, p_aprobar boolean, p_motivo text default null)
returns void language plpgsql security definer set search_path = public as $$
declare c cuentas_venta;
begin
  perform _exigir_admin();
  perform set_config('mercado.sistema', '1', true);
  if p_aprobar then
    update cuentas_venta set estado = 'publicada', motivo_rechazo = null where id = p_cuenta and estado in ('revision', 'rechazada', 'pausada');
  else
    update cuentas_venta set estado = 'rechazada', motivo_rechazo = left(coalesce(nullif(trim(p_motivo), ''), 'No cumple las reglas'), 200)
     where id = p_cuenta and estado in ('revision', 'publicada', 'pausada');
  end if;
  if not found then raise exception 'ESTADO_INVALIDO'; end if;
  select * into c from cuentas_venta where id = p_cuenta;
  if p_aprobar then
    perform _notificar(c.vendedor, 'moderacion', format('Tu cuenta FF-%s ya está a la venta', c.id),
      format('Aprobamos "%s" y ya aparece en el mercado por %s USD. Te avisamos apenas alguien la compre.', c.titulo, c.precio_usd),
      'cuenta-' || c.id, true);
  else
    perform _notificar(c.vendedor, 'moderacion', format('Tu cuenta FF-%s no se publicó', c.id),
      format(E'Revisamos "%s" y no la pudimos publicar.\nMotivo: %s', c.titulo, c.motivo_rechazo), 'panel', true);
  end if;
end $$;

-- A favor del vendedor: se cierra y cobra. A favor del comprador: se cancela, lo pagado vuelve a su saldo y la cuenta queda rechazada.
create or replace function public.admin_resolver(p_venta bigint, p_favor text, p_nota text)
returns void language plpgsql security definer set search_path = public as $$
declare v ventas_cuentas;
begin
  perform _exigir_admin();
  select * into v from ventas_cuentas where id = p_venta for update;
  if not found or v.estado not in ('pagada', 'entregada', 'en_reclamo') then raise exception 'ESTADO_INVALIDO'; end if;
  if p_favor = 'vendedor' then
    update ventas_cuentas set resolucion = 'Resuelto a favor del vendedor: ' || coalesce(nullif(trim(p_nota), ''), 'sin nota') where id = p_venta;
    perform _venta_cerrar(p_venta, null);
  elsif p_favor = 'comprador' then
    perform _venta_cancelar(p_venta, 'Resuelto a favor del comprador (reembolso): ' || coalesce(nullif(trim(p_nota), ''), 'sin nota'), 'rechazada');
  else
    raise exception 'DATO_INVALIDO';
  end if;
end $$;

-- Cancelar cualquier trato abierto. Si se pagó con saldo, vuelve solo al saldo del comprador.
create or replace function public.admin_cancelar(p_venta bigint, p_motivo text, p_devolver_al_mercado boolean default true)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform _exigir_admin();
  perform _venta_cancelar(p_venta, 'Cancelado por Level Up: ' || coalesce(nullif(trim(p_motivo), ''), 'sin motivo'),
                          case when p_devolver_al_mercado then 'publicada' else 'pausada' end);
end $$;

create or replace function public.admin_resolver_retiro(p_retiro bigint, p_pagado boolean, p_texto text)
returns void language plpgsql security definer set search_path = public as $$
declare r retiros;
begin
  perform _exigir_admin();
  select * into r from retiros where id = p_retiro for update;
  if not found or r.estado <> 'pendiente' then raise exception 'ESTADO_INVALIDO'; end if;
  if p_pagado then
    update retiros set estado = 'pagado', referencia = left(trim(coalesce(p_texto, '')), 80), resuelto = now() where id = p_retiro;
    perform _notificar(r.vendedor, 'retiro', format('Te pagamos el retiro R-%s', r.id),
      format('Enviamos %s USD por %s. Referencia: %s.', r.neto_usd, r.metodo, coalesce(nullif(left(trim(coalesce(p_texto, '')), 80), ''), '—')), 'saldo', true);
  else
    update retiros set estado = 'rechazado', motivo = left(trim(coalesce(p_texto, '')), 200), resuelto = now() where id = p_retiro;
    perform _mover_saldo(r.vendedor, r.monto_usd, 'retiro_devuelto', null, r.id, format('Retiro R-%s rechazado: %s', r.id, coalesce(nullif(trim(p_texto), ''), 'sin motivo')));
    perform _notificar(r.vendedor, 'retiro', format('Retiro R-%s rechazado', r.id),
      format(E'Motivo: %s\nLos %s USD volvieron a tu saldo. Revisa tus datos de cobro y pídelo otra vez.', coalesce(nullif(trim(p_texto), ''), 'sin motivo'), r.monto_usd), 'saldo', true);
  end if;
end $$;

create or replace function public.admin_ajustar_saldo(p_vendedor uuid, p_monto numeric, p_detalle text)
returns numeric language plpgsql security definer set search_path = public as $$
begin
  perform _exigir_admin();
  perform _notificar(p_vendedor, 'ajuste', format('Ajuste de saldo: %s%s USD', case when p_monto > 0 then '+' else '' end, round(p_monto, 2)),
    left(coalesce(nullif(trim(p_detalle), ''), 'Ajuste de Level Up'), 200), 'saldo', false);
  return _mover_saldo(p_vendedor, round(p_monto, 2), 'ajuste', null, null, left(coalesce(p_detalle, 'Ajuste'), 200));
end $$;

-- Aprobar una recarga: suma el monto (o el que indiques, si llegó otro) a la parte recargada del saldo
create or replace function public.admin_recarga_aprobar(p_orden bigint, p_monto numeric default null)
returns void language plpgsql security definer set search_path = public as $$
declare o ordenes_recarga; monto numeric;
begin
  perform _exigir_admin();
  select * into o from ordenes_recarga where id = p_orden for update;
  if not found or o.estado <> 'pendiente' then raise exception 'ESTADO_INVALIDO'; end if;
  monto := round(coalesce(p_monto, o.monto_usd), 2);
  if monto <= 0 or monto > 5000 then raise exception 'DATO_INVALIDO'; end if;
  update ordenes_recarga set estado = 'aprobada', acreditado_usd = monto, resuelto = now() where id = p_orden;
  perform _mover_recargado(o.usuario, monto, 'recarga', null, o.id, format('Recarga RC-%s', o.id));
  perform _mensaje_recarga(p_orden, format('Recarga aprobada: %s USD ya están en tu saldo. ¡Ya puedes comprar!', monto)
    || case when monto <> o.monto_usd then format(' (Pediste %s USD; acreditamos lo que llegó.)', o.monto_usd) else '' end);
  perform _notificar(o.usuario, 'recarga', format('Recarga aprobada: +%s USD', monto),
    format('Tu recarga RC-%s ya está en tu saldo. ¡Ya puedes comprar cuentas!', o.id)
    || case when monto <> o.monto_usd then format(' (Pediste %s USD; acreditamos lo que llegó.)', o.monto_usd) else '' end,
    'recarga-' || o.id, true);
end $$;

create or replace function public.admin_recarga_rechazar(p_orden bigint, p_motivo text)
returns void language plpgsql security definer set search_path = public as $$
declare o ordenes_recarga; motivo text := left(coalesce(nullif(trim(p_motivo), ''), 'El pago no llegó'), 200);
begin
  perform _exigir_admin();
  select * into o from ordenes_recarga where id = p_orden for update;
  if not found or o.estado <> 'pendiente' then raise exception 'ESTADO_INVALIDO'; end if;
  update ordenes_recarga set estado = 'rechazada', nota = motivo, resuelto = now() where id = p_orden;
  perform _mensaje_recarga(p_orden, 'Recarga rechazada: ' || motivo || '. Si crees que es un error, respóndenos en este chat.');
  perform _notificar(o.usuario, 'recarga', format('Recarga RC-%s rechazada', o.id),
    format(E'Motivo: %s\nSi crees que es un error, respóndenos en el chat de la recarga.', motivo), 'recarga-' || o.id, true);
end $$;

-- Eliminar una orden (y su chat). Si estaba aprobada y p_revertir, descuenta del saldo lo acreditado.
-- Devuelve la ruta de la captura para que el panel borre el archivo.
create or replace function public.admin_recarga_eliminar(p_orden bigint, p_revertir boolean default false)
returns text language plpgsql security definer set search_path = public as $$
declare o ordenes_recarga; s saldos_vendedor;
begin
  perform _exigir_admin();
  select * into o from ordenes_recarga where id = p_orden for update;
  if not found then raise exception 'ESTADO_INVALIDO'; end if;
  if o.estado = 'aprobada' and p_revertir then
    select * into s from saldos_vendedor where vendedor = o.usuario for update;
    if not found or s.recargado < o.acreditado_usd then raise exception 'SALDO_GASTADO'; end if;
    perform _mover_recargado(o.usuario, -o.acreditado_usd, 'recarga_revertida', null, null, format('Recarga RC-%s anulada por Level Up', o.id));
  end if;
  delete from ordenes_recarga where id = p_orden;
  return o.captura;
end $$;

create or replace function public.admin_config(p_clave text, p_valor text)
returns void language plpgsql security definer set search_path = public as $$
declare numericas text[] := array['comision_retiro', 'retiro_minimo', 'garantia_usd', 'horas_pago', 'horas_revision', 'tasa_bs', 'recarga_minima', 'paypal_recargo',
                                  'horas_entrega', 'dias_liberacion'];
begin
  perform _exigir_admin();
  if not (p_clave = any (numericas) or p_clave in ('instrucciones_pago', 'binance_pay_id', 'binance_nombre', 'paypal_correo', 'paypal_nombre',
                                                   'pm_banco', 'pm_telefono', 'pm_cedula', 'pm_titular',
                                                   'correo_remitente', 'correo_nombre', 'sitio_url')) then
    raise exception 'DATO_INVALIDO';
  end if;
  if p_clave = any (numericas) and nullif(trim(p_valor), '') is not null and trim(p_valor) !~ '^[0-9]+(\.[0-9]+)?$' then
    raise exception 'DATO_INVALIDO';
  end if;
  if p_clave in ('horas_entrega', 'dias_liberacion') and coalesce(nullif(trim(p_valor), ''), '0')::numeric > 720 then raise exception 'DATO_INVALIDO'; end if;
  if p_clave = 'correo_remitente' and nullif(trim(p_valor), '') is not null and trim(p_valor) !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'DATO_INVALIDO'; end if;
  if p_clave = 'sitio_url' and trim(coalesce(p_valor, '')) !~ '^https://[A-Za-z0-9.-]+(:[0-9]+)?/?$' then raise exception 'DATO_INVALIDO'; end if;
  insert into mercado_config (clave, valor)
  values (p_clave, left(trim(coalesce(p_valor, '')), case when p_clave = 'instrucciones_pago' then 600 else 120 end))
  on conflict (clave) do update set valor = excluded.valor;
end $$;

-- Correo de prueba al admin que lo pide: devuelve 'enviado' o el motivo (sin_config, sin_correo, error)
create or replace function public.admin_correo_prueba()
returns text language plpgsql security definer set search_path = public as $$
declare para text;
begin
  perform _exigir_admin();
  select email into para from auth.users where id = auth.uid();
  return _enviar_correo(para, 'Correo de prueba de Level Up',
    E'Si lees esto, los correos automáticos funcionan.\nTus clientes recibirán avisos de ventas, entregas, recargas y retiros.', 'admin:sistema');
end $$;

-- Notificación de prueba al admin que la pide (a todos sus dispositivos con los avisos activados).
-- Devuelve 'pendiente' (pedida a la función), 'sin_dispositivo' o 'sin_config'.
create or replace function public.admin_push_prueba()
returns text language plpgsql security definer set search_path = public as $$
begin
  perform _exigir_admin();
  perform _notificar(auth.uid(), 'prueba', 'Notificación de prueba',
    'Si ves esto en tu celular o computadora, las notificaciones de Level Up funcionan.', 'admin:sistema');
  return (select push from notificaciones where usuario = auth.uid() order by id desc limit 1);
end $$;

-- Buscar cuentas registradas por correo (vacío = las más nuevas) con su saldo y actividad
drop function if exists public.admin_buscar_usuarios(text);
create or replace function public.admin_buscar_usuarios(p_texto text)
returns table (id uuid, email text, nombre text, creado timestamptz, ultimo_acceso timestamptz, disponible numeric, recargado numeric,
               ventas int, estrellas numeric, recargas int, tratos int, publicaciones int)
language plpgsql stable security definer set search_path = public as $$
declare t text := lower(trim(coalesce(p_texto, '')));
begin
  perform _exigir_admin();
  return query
  select u.id, u.email::text, pf.nombre, u.created_at, u.last_sign_in_at,
         coalesce(s.disponible, 0), coalesce(s.recargado, 0), coalesce(s.ventas, 0),
         (select round(avg(c.estrellas), 1) from calificaciones c where c.vendedor = u.id),
         (select count(*)::int from ordenes_recarga o where o.usuario = u.id),
         (select count(*)::int from ventas_cuentas v where v.comprador = u.id or v.vendedor = u.id),
         (select count(*)::int from cuentas_venta cv where cv.vendedor = u.id)
    from auth.users u
    left join saldos_vendedor s on s.vendedor = u.id
    left join perfiles pf on pf.usuario = u.id
   where t = '' or lower(u.email) like '%' || replace(replace(t, '%', ''), '_', '\_') || '%'
         or lower(coalesce(pf.nombre, '')) like '%' || replace(replace(t, '%', ''), '_', '\_') || '%'
   order by u.created_at desc
   limit 100;
end $$;

-- Ajustar la parte RECARGADA del saldo (la de ventas se ajusta con admin_ajustar_saldo)
create or replace function public.admin_ajustar_recargado(p_usuario uuid, p_monto numeric, p_detalle text)
returns numeric language plpgsql security definer set search_path = public as $$
begin
  perform _exigir_admin();
  if p_monto is null or p_monto = 0 or abs(p_monto) > 5000 then raise exception 'DATO_INVALIDO'; end if;
  perform _notificar(p_usuario, 'ajuste', format('Ajuste de saldo: %s%s USD', case when p_monto > 0 then '+' else '' end, round(p_monto, 2)),
    left(coalesce(nullif(trim(p_detalle), ''), 'Ajuste de Level Up'), 200), 'saldo', false);
  return _mover_recargado(p_usuario, round(p_monto, 2), 'ajuste', null, null, left(coalesce(nullif(trim(p_detalle), ''), 'Ajuste de Level Up'), 200));
exception when check_violation then
  raise exception 'SALDO_GASTADO';
end $$;

-- ESTADO DEL SISTEMA para el panel: tamaño de la base y de los archivos, conteos, dinero y salud
create or replace function public.admin_estado()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare hay_clave boolean := false;
begin
  perform _exigir_admin();
  if to_regclass('vault.secrets') is not null then
    execute 'select exists (select 1 from vault.secrets where name = $1)' into hay_clave using 'brevo_api_key';
  end if;
  return jsonb_build_object(
    'correo', jsonb_build_object(
      'pg_net', to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)') is not null,
      'vault', to_regclass('vault.decrypted_secrets') is not null,
      'clave', hay_clave,
      'remitente', (select nullif(trim(valor), '') from mercado_config where clave = 'correo_remitente'),
      'ultimas_24h', (select coalesce(jsonb_object_agg(correo, n), '{}'::jsonb)
                        from (select correo, count(*) n from notificaciones where correo is not null and creado > now() - interval '1 day' group by correo) x)),
    'push', jsonb_build_object(
      'pg_net', to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)') is not null,
      'url', (select nullif(trim(valor), '') from mercado_config where clave = 'push_url'),
      'dispositivos', (select count(*) from push_suscripciones),
      'usuarios', (select count(distinct usuario) from push_suscripciones),
      'ultimas_24h', (select coalesce(jsonb_object_agg(push, n), '{}'::jsonb)
                        from (select push, count(*) n from notificaciones where push is not null and creado > now() - interval '1 day' group by push) x)),
    'errores_24h', (select coalesce(sum(veces), 0) from errores_cliente where ultimo > now() - interval '1 day'),
    'errores', (select coalesce(jsonb_agg(to_jsonb(e) - 'usuario' order by e.ultimo desc), '[]'::jsonb)
                  from (select * from errores_cliente order by ultimo desc limit 15) e),
    'sin_entregar_vencidos', (select count(*) from ventas_cuentas where estado = 'pagada' and apelada_en is null
                                and _config_num('horas_entrega', 12) > 0
                                and coalesce(pagada_en, creado) < now() - make_interval(mins => (_config_num('horas_entrega', 12) * 60)::int)),
    'hora_servidor', now(),
    'version_postgres', split_part(version(), ' ', 2),
    'bd_bytes', pg_database_size(current_database()),
    'pg_cron', exists (select 1 from pg_extension where extname = 'pg_cron'),
    'realtime', (select coalesce(jsonb_agg(tablename order by tablename), '[]'::jsonb) from pg_publication_tables
                  where pubname = 'supabase_realtime' and schemaname = 'public'),
    'usuarios', (select count(*) from auth.users),
    'usuarios_7d', (select count(*) from auth.users where created_at > now() - interval '7 days'),
    'tablas', jsonb_build_object(
      'Publicaciones', (select count(*) from cuentas_venta),
      'Tratos', (select count(*) from ventas_cuentas),
      'Mensajes de tratos', (select count(*) from mensajes_venta),
      'Recargas', (select count(*) from ordenes_recarga),
      'Mensajes de recargas', (select count(*) from mensajes_recarga),
      'Mensajes de soporte', (select count(*) from mensajes_soporte),
      'Movimientos de saldo', (select count(*) from movimientos_vendedor),
      'Retiros', (select count(*) from retiros),
      'Calificaciones', (select count(*) from calificaciones),
      'Avisos', (select count(*) from notificaciones),
      'Errores de la web', (select count(*) from errores_cliente)),
    'archivos', (select coalesce(jsonb_object_agg(bucket_id, jsonb_build_object('archivos', n, 'bytes', b)), '{}'::jsonb)
                   from (select o.bucket_id, count(*) n, coalesce(sum((o.metadata ->> 'size')::bigint), 0) b
                           from storage.objects o where o.bucket_id in ('cuentas-fotos', 'comprobantes') group by o.bucket_id) x),
    'dinero', jsonb_build_object(
      'saldo_recargado', (select coalesce(sum(recargado), 0) from saldos_vendedor),
      'saldo_ventas', (select coalesce(sum(disponible), 0) from saldos_vendedor),
      'retenido_en_tratos', (select coalesce(sum(total_usd), 0) from ventas_cuentas where estado in ('pagada', 'entregada', 'en_reclamo')),
      'retiros_por_pagar', (select coalesce(sum(neto_usd), 0) from retiros where estado = 'pendiente'),
      'comisiones_cobradas', (select coalesce(sum(comision_usd), 0) from retiros where estado = 'pagado'),
      'garantias_cobradas', (select coalesce(sum(total_usd - precio_usd), 0) from ventas_cuentas where estado = 'cerrada'),
      'ventas_por_liberar', (select coalesce(sum(_ventas_por_liberar(vendedor)), 0) from saldos_vendedor where disponible > 0)),
    -- Si esto no es 0, el mantenimiento automático no está corriendo
    'tratos_vencidos', (select count(*) from ventas_cuentas where estado = 'entregada'
                          and entregada_en < now() - make_interval(hours => _config_num('horas_revision', 24)::int)),
    'pendientes', jsonb_build_object(
      'recargas', (select count(*) from ordenes_recarga where estado = 'pendiente'),
      'revision', (select count(*) from cuentas_venta where estado = 'revision'),
      'reclamos', (select count(*) from ventas_cuentas where estado = 'en_reclamo'),
      'apelaciones', (select count(*) from ventas_cuentas where apelada_en is not null and estado not in ('cerrada', 'cancelada')))
  );
end $$;

-- LIMPIEZA de lo viejo. p_que: 'chats_tratos', 'recargas_rechazadas', 'capturas_aprobadas', 'publicaciones', 'soporte', 'huerfanos',
-- 'avisos' (avisos leídos) y 'errores' (errores de la web).
-- Nunca toca dinero: saldos, movimientos, retiros, tratos y recargas aprobadas se conservan siempre.
-- Con p_ejecutar = false solo cuenta. Con true borra y devuelve las rutas de archivos para que el panel los borre del Storage.
create or replace function public.admin_limpiar(p_dias int, p_que text[], p_ejecutar boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  corte timestamptz;
  conteos jsonb := '{}'::jsonb;
  fotos text[] := '{}';
  capturas text[] := '{}';
  tmp text[];
  n bigint;
begin
  perform _exigir_admin();
  if p_dias is null or p_dias < 7 then raise exception 'DATO_INVALIDO'; end if;
  corte := now() - make_interval(days => p_dias);
  perform set_config('mercado.sistema', '1', true);

  -- (Primero, antes de borrar nada) Archivos que ninguna publicación ni recarga usa (subidas que fallaron), de hace más de 1 día
  if 'huerfanos' = any (p_que) then
    select count(*) into n from storage.objects o
     where o.created_at < now() - interval '1 day' and (
       (o.bucket_id = 'cuentas-fotos' and not exists (select 1 from cuentas_venta c where o.name = any (c.fotos)))
       or (o.bucket_id = 'comprobantes' and not exists (select 1 from ordenes_recarga r where r.captura = o.name)));
    conteos := conteos || jsonb_build_object('huerfanos', n);
    if p_ejecutar then
      fotos := fotos || coalesce((select array_agg(o.name) from storage.objects o where o.bucket_id = 'cuentas-fotos' and o.created_at < now() - interval '1 day'
                                    and not exists (select 1 from cuentas_venta c where o.name = any (c.fotos))), '{}');
      capturas := capturas || coalesce((select array_agg(o.name) from storage.objects o where o.bucket_id = 'comprobantes' and o.created_at < now() - interval '1 day'
                                    and not exists (select 1 from ordenes_recarga r where r.captura = o.name)), '{}');
    end if;
  end if;

  if 'chats_tratos' = any (p_que) then
    select count(*) into n from mensajes_venta m join ventas_cuentas v on v.id = m.venta
     where v.estado in ('cerrada', 'cancelada') and coalesce(v.cerrada_en, v.actualizado) < corte;
    conteos := conteos || jsonb_build_object('chats_tratos', n);
    if p_ejecutar then
      delete from mensajes_venta m using ventas_cuentas v
       where v.id = m.venta and v.estado in ('cerrada', 'cancelada') and coalesce(v.cerrada_en, v.actualizado) < corte;
    end if;
  end if;

  if 'recargas_rechazadas' = any (p_que) then
    select count(*), coalesce(array_agg(captura) filter (where captura <> ''), '{}') into n, tmp
      from ordenes_recarga where estado = 'rechazada' and resuelto < corte;
    capturas := capturas || tmp;
    conteos := conteos || jsonb_build_object('recargas_rechazadas', n);
    if p_ejecutar then delete from ordenes_recarga where estado = 'rechazada' and resuelto < corte; end if;
  end if;

  if 'capturas_aprobadas' = any (p_que) then
    select count(*), coalesce(array_agg(captura), '{}') into n, tmp
      from ordenes_recarga where estado = 'aprobada' and resuelto < corte and captura <> '';
    conteos := conteos || jsonb_build_object('capturas_aprobadas', n);
    capturas := capturas || tmp;
    if p_ejecutar then update ordenes_recarga set captura = '' where estado = 'aprobada' and resuelto < corte and captura <> ''; end if;
  end if;

  if 'publicaciones' = any (p_que) then
    select count(*), coalesce((select array_agg(f) from cuentas_venta c2, unnest(c2.fotos) f
                                where c2.estado in ('rechazada', 'vendida') and c2.actualizado < corte), '{}')
      into n, tmp
      from cuentas_venta where estado in ('rechazada', 'vendida') and actualizado < corte;
    conteos := conteos || jsonb_build_object('publicaciones', n);
    fotos := fotos || tmp;
    if p_ejecutar then delete from cuentas_venta where estado in ('rechazada', 'vendida') and actualizado < corte; end if;
  end if;

  if 'soporte' = any (p_que) then
    select count(*) into n from mensajes_soporte where creado < corte;
    conteos := conteos || jsonb_build_object('soporte', n);
    if p_ejecutar then
      delete from mensajes_soporte where creado < corte;
      delete from soporte_chats s where s.actualizado < corte and not exists (select 1 from mensajes_soporte m where m.usuario = s.usuario);
    end if;
  end if;

  if 'avisos' = any (p_que) then
    select count(*) into n from notificaciones where leida and creado < corte;
    conteos := conteos || jsonb_build_object('avisos', n);
    if p_ejecutar then delete from notificaciones where leida and creado < corte; end if;
  end if;

  if 'errores' = any (p_que) then
    select count(*) into n from errores_cliente where ultimo < corte;
    conteos := conteos || jsonb_build_object('errores', n);
    if p_ejecutar then delete from errores_cliente where ultimo < corte; end if;
  end if;

  fotos := array(select distinct x from unnest(fotos) x);
  capturas := array(select distinct x from unnest(capturas) x);
  return jsonb_build_object('conteos', conteos,
    'archivos', case when p_ejecutar then jsonb_build_object('cuentas-fotos', to_jsonb(fotos[1:2000]), 'comprobantes', to_jsonb(capturas[1:2000]))
                     else '{}'::jsonb end);
end $$;

-- Correos de comprador/vendedor para el panel (auth.users no es accesible desde la API)
create or replace function public.admin_correos(p_ids uuid[])
returns table (id uuid, email text) language plpgsql stable security definer set search_path = public as $$
begin
  perform _exigir_admin();
  return query select u.id, u.email::text from auth.users u where u.id = any (p_ids[1:200]);
end $$;

-- ---------------------------------------------------------------------
-- BORRAR MI CUENTA (lo pide el propio usuario desde Mi panel)
-- Sin tratos ni retiros: se borra todo (Auth incluido). Con historial: se borra lo personal (perfil, publicaciones,
-- soporte, avisos, acceso) y se conservan los tratos y movimientos de dinero, que la otra parte y la contabilidad necesitan.
-- Devuelve las rutas de archivos para que la página los borre del Storage.
-- ---------------------------------------------------------------------
create or replace function public.cuenta_eliminar_revisar()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare s saldos_vendedor; abiertos int; total numeric; motivo text;
begin
  if auth.uid() is null then raise exception 'SIN_SESION'; end if;
  select * into s from saldos_vendedor where vendedor = auth.uid();
  total := coalesce(s.disponible, 0) + coalesce(s.recargado, 0);
  select count(*) into abiertos from ventas_cuentas
   where (comprador = auth.uid() or vendedor = auth.uid()) and estado not in ('cerrada', 'cancelada');
  motivo := case
    when public.es_admin() then 'Eres administrador. Otro admin debe quitarte de mercado_admins antes de borrar tu cuenta.'
    when abiertos > 0 then format('Tienes %s trato(s) abierto(s). Termínalos antes de borrar tu cuenta.', abiertos)
    when exists (select 1 from retiros where vendedor = auth.uid() and estado = 'pendiente') then 'Tienes un retiro pendiente. Espera a que te lo paguemos.'
    when exists (select 1 from ordenes_recarga where usuario = auth.uid() and estado = 'pendiente') then 'Tienes una recarga en revisión. Espera a que la aprobemos o rechacemos.'
    when total > 0 then format('Todavía tienes %s USD de saldo. Úsalo o retíralo (o escríbenos al chat de soporte) antes de borrar tu cuenta.', total)
  end;
  return jsonb_build_object('puede', motivo is null, 'motivo', motivo,
    'historial', exists (select 1 from ventas_cuentas where comprador = auth.uid() or vendedor = auth.uid())
                 or exists (select 1 from retiros where vendedor = auth.uid()));
end $$;

create or replace function public.cuenta_eliminar(p_confirmacion text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); revision jsonb; fotos text[]; capturas text[] := '{}'; historial boolean;
begin
  if uid is null then raise exception 'SIN_SESION'; end if;
  if upper(trim(coalesce(p_confirmacion, ''))) <> 'ELIMINAR' then raise exception 'DATO_INVALIDO'; end if;
  revision := cuenta_eliminar_revisar();
  if not (revision ->> 'puede')::boolean then raise exception 'NO_SE_PUEDE_BORRAR'; end if;
  historial := (revision ->> 'historial')::boolean;
  perform set_config('mercado.sistema', '1', true);
  fotos := array(select o.name from storage.objects o where o.bucket_id = 'cuentas-fotos' and o.name like uid::text || '/%');

  if historial then
    delete from cuentas_venta where vendedor = uid;          -- los tratos se quedan (cuenta = null) y su contacto se borra
    delete from perfiles where usuario = uid;
    delete from preferencias where usuario = uid;
    delete from push_suscripciones where usuario = uid;
    delete from notificaciones where usuario = uid;
    delete from mensajes_soporte where usuario = uid;
    delete from soporte_chats where usuario = uid;
    capturas := array(select captura from ordenes_recarga where usuario = uid and estado = 'rechazada' and captura <> '');
    delete from ordenes_recarga where usuario = uid and estado = 'rechazada';
    -- Sin acceso y sin datos personales en Auth (el registro queda solo para que los tratos sigan cuadrando)
    begin execute 'delete from auth.identities where user_id = $1' using uid; exception when others then null; end;
    begin execute 'delete from auth.sessions where user_id = $1' using uid; exception when others then null; end;
    begin execute 'delete from auth.refresh_tokens where user_id = $1' using uid::text; exception when others then null; end;
    execute 'update auth.users set email = $2, phone = null, encrypted_password = '''', raw_user_meta_data = ''{}''::jsonb,
                                   banned_until = ''infinity''::timestamptz where id = $1'
      using uid, 'borrado-' || replace(uid::text, '-', '') || '@levelup.invalid';
  else
    capturas := array(select o.name from storage.objects o where o.bucket_id = 'comprobantes' and o.name like uid::text || '/%');
    begin execute 'update storage.objects set owner = null where owner = $1' using uid; exception when others then null; end;
    delete from auth.users where id = uid;                     -- todo lo demás se borra en cascada
  end if;
  return jsonb_build_object('anonimizada', historial,
    'archivos', jsonb_build_object('cuentas-fotos', to_jsonb(coalesce(fotos, '{}')), 'comprobantes', to_jsonb(coalesce(capturas, '{}'))));
end $$;

-- ---------------------------------------------------------------------
-- RLS: el navegador solo LEE. Todo cambio pasa por las funciones de arriba.
-- ---------------------------------------------------------------------
alter table public.mercado_admins enable row level security;
alter table public.mercado_config enable row level security;
alter table public.cuentas_venta enable row level security;
alter table public.cuentas_contacto enable row level security;
alter table public.ventas_cuentas enable row level security;
alter table public.mensajes_venta enable row level security;
alter table public.saldos_vendedor enable row level security;
alter table public.retiros enable row level security;
alter table public.movimientos_vendedor enable row level security;
alter table public.ordenes_recarga enable row level security;
alter table public.mensajes_recarga enable row level security;
alter table public.soporte_chats enable row level security;
alter table public.calificaciones enable row level security;
alter table public.perfiles enable row level security;
alter table public.mensajes_soporte enable row level security;
alter table public.notificaciones enable row level security;
alter table public.preferencias enable row level security;
alter table public.errores_cliente enable row level security;
alter table public.push_suscripciones enable row level security;   -- sin políticas: solo por funciones

drop policy if exists "soy admin" on public.mercado_admins;
create policy "soy admin" on public.mercado_admins for select to authenticated using (usuario = auth.uid());

drop policy if exists "config publica" on public.mercado_config;
create policy "config publica" on public.mercado_config for select using (true);

drop policy if exists "ver publicadas o propias" on public.cuentas_venta;
create policy "ver publicadas o propias" on public.cuentas_venta for select
  using (estado = 'publicada' or vendedor = auth.uid() or public.es_admin());
drop policy if exists "publicar propias" on public.cuentas_venta;
create policy "publicar propias" on public.cuentas_venta for insert to authenticated
  with check (vendedor = auth.uid());
drop policy if exists "editar propias" on public.cuentas_venta;
create policy "editar propias" on public.cuentas_venta for update to authenticated
  using (vendedor = auth.uid()) with check (vendedor = auth.uid());
drop policy if exists "borrar propias" on public.cuentas_venta;
create policy "borrar propias" on public.cuentas_venta for delete to authenticated
  using (vendedor = auth.uid() and estado not in ('vendida', 'reservada'));

drop policy if exists "contacto propio" on public.cuentas_contacto;
create policy "contacto propio" on public.cuentas_contacto for all to authenticated
  using (vendedor = auth.uid())
  with check (vendedor = auth.uid() and exists (select 1 from cuentas_venta c where c.id = cuenta and c.vendedor = auth.uid()));
drop policy if exists "contacto admin" on public.cuentas_contacto;
create policy "contacto admin" on public.cuentas_contacto for select to authenticated using (public.es_admin());

drop policy if exists "tratos propios" on public.ventas_cuentas;
create policy "tratos propios" on public.ventas_cuentas for select to authenticated
  using (comprador = auth.uid() or vendedor = auth.uid() or public.es_admin());

drop policy if exists "mensajes de mis tratos" on public.mensajes_venta;
create policy "mensajes de mis tratos" on public.mensajes_venta for select to authenticated
  using (public.es_admin() or exists (select 1 from ventas_cuentas v where v.id = venta and (v.comprador = auth.uid() or v.vendedor = auth.uid())));

drop policy if exists "saldo propio" on public.saldos_vendedor;
create policy "saldo propio" on public.saldos_vendedor for select to authenticated using (vendedor = auth.uid() or public.es_admin());
drop policy if exists "retiros propios" on public.retiros;
create policy "retiros propios" on public.retiros for select to authenticated using (vendedor = auth.uid() or public.es_admin());
drop policy if exists "movimientos propios" on public.movimientos_vendedor;
create policy "movimientos propios" on public.movimientos_vendedor for select to authenticated using (vendedor = auth.uid() or public.es_admin());
drop policy if exists "recargas propias" on public.ordenes_recarga;
create policy "recargas propias" on public.ordenes_recarga for select to authenticated using (usuario = auth.uid() or public.es_admin());
drop policy if exists "mensajes de mis recargas" on public.mensajes_recarga;
create policy "mensajes de mis recargas" on public.mensajes_recarga for select to authenticated
  using (public.es_admin() or exists (select 1 from ordenes_recarga o where o.id = orden and o.usuario = auth.uid()));
drop policy if exists "perfiles publicos" on public.perfiles;
create policy "perfiles publicos" on public.perfiles for select using (true);
drop policy if exists "calificaciones propias" on public.calificaciones;
create policy "calificaciones propias" on public.calificaciones for select to authenticated using (comprador = auth.uid() or vendedor = auth.uid() or public.es_admin());
drop policy if exists "soporte propio" on public.soporte_chats;
create policy "soporte propio" on public.soporte_chats for select to authenticated using (usuario = auth.uid() or public.es_admin());
drop policy if exists "mensajes de soporte propios" on public.mensajes_soporte;
create policy "mensajes de soporte propios" on public.mensajes_soporte for select to authenticated using (usuario = auth.uid() or public.es_admin());
drop policy if exists "avisos propios" on public.notificaciones;
create policy "avisos propios" on public.notificaciones for select to authenticated using (usuario = auth.uid());
drop policy if exists "preferencias propias" on public.preferencias;
create policy "preferencias propias" on public.preferencias for select to authenticated using (usuario = auth.uid());
drop policy if exists "errores admin" on public.errores_cliente;
create policy "errores admin" on public.errores_cliente for select to authenticated using (public.es_admin());

-- Permisos de tabla (además del RLS)
grant select on public.cuentas_venta, public.mercado_config to anon, authenticated;
grant insert, update, delete on public.cuentas_venta to authenticated;
grant select, insert, update, delete on public.cuentas_contacto to authenticated;
grant select on public.ventas_cuentas, public.mensajes_venta, public.saldos_vendedor, public.retiros,
               public.movimientos_vendedor, public.mercado_admins, public.ordenes_recarga, public.mensajes_recarga to authenticated;
revoke insert, update, delete on public.ventas_cuentas, public.mensajes_venta, public.saldos_vendedor, public.retiros,
               public.movimientos_vendedor, public.mercado_admins, public.mercado_config,
               public.ordenes_recarga, public.mensajes_recarga from anon, authenticated;
revoke select on public.ordenes_recarga, public.mensajes_recarga from anon;
grant select on public.soporte_chats, public.mensajes_soporte to authenticated;
revoke insert, update, delete on public.soporte_chats, public.mensajes_soporte from anon, authenticated;
revoke select on public.soporte_chats, public.mensajes_soporte from anon;
revoke execute on function public.soporte_mensaje(uuid, text), public.admin_bandeja(int) from public, anon;
grant execute on function public.soporte_mensaje(uuid, text), public.admin_bandeja(int) to authenticated;
grant select on public.calificaciones to authenticated;
revoke insert, update, delete on public.calificaciones from anon, authenticated;
revoke select on public.calificaciones from anon;
revoke execute on function public.venta_apelar(bigint, text), public.venta_calificar(bigint, int, text),
  public.admin_buscar_usuarios(text), public.admin_ajustar_recargado(uuid, numeric, text) from public, anon;
grant execute on function public.venta_apelar(bigint, text), public.venta_calificar(bigint, int, text),
  public.admin_buscar_usuarios(text), public.admin_ajustar_recargado(uuid, numeric, text) to authenticated;
grant execute on function public.mercado_opiniones(uuid) to anon, authenticated;
grant select on public.perfiles to anon, authenticated;
revoke insert, update, delete on public.perfiles from anon, authenticated;
revoke execute on function public.perfil_guardar(text, text) from public, anon;
grant execute on function public.perfil_guardar(text, text) to authenticated;
grant execute on function public.mercado_perfil(uuid) to anon, authenticated;
grant execute on function public.mercado_vendedores(text, text) to anon, authenticated;
revoke execute on function public.admin_estado(), public.admin_limpiar(int, text[], boolean) from public, anon;
grant execute on function public.admin_estado(), public.admin_limpiar(int, text[], boolean) to authenticated;
-- Avisos, preferencias, saldo retirable, borrar cuenta y errores de la web
grant select on public.notificaciones, public.preferencias, public.errores_cliente to authenticated;
revoke all on public.notificaciones, public.preferencias, public.errores_cliente from anon;
revoke insert, update, delete, truncate on public.notificaciones, public.preferencias, public.errores_cliente from authenticated;
revoke execute on function public.notificaciones_leer(text), public.preferencias_guardar(boolean), public.mi_saldo(),
  public.cuenta_eliminar_revisar(), public.cuenta_eliminar(text), public.admin_correo_prueba() from public, anon;
grant execute on function public.notificaciones_leer(text), public.preferencias_guardar(boolean), public.mi_saldo(),
  public.cuenta_eliminar_revisar(), public.cuenta_eliminar(text), public.admin_correo_prueba() to authenticated;
grant execute on function public.error_registrar(text, text, text, text) to anon, authenticated;
-- Notificaciones push
revoke all on public.push_suscripciones from anon, authenticated;
revoke execute on function public._enviar_push(bigint, uuid) from public, anon, authenticated;
revoke execute on function public.push_guardar(text, text, text, text), public.push_borrar(text), public.admin_push_prueba() from public, anon;
grant execute on function public.push_guardar(text, text, text, text), public.push_borrar(text), public.admin_push_prueba() to authenticated;
revoke execute on function public.push_tomar(bigint), public.push_resultado(bigint, int, text[]) from public, anon, authenticated;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant execute on function public.push_tomar(bigint), public.push_resultado(bigint, int, text[]) to service_role;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- SEGURIDAD EXTRA
-- ---------------------------------------------------------------------
-- Quien no inició sesión no tiene NINGÚN permiso sobre las tablas privadas (antes el RLS ya le devolvía vacío;
-- ahora ni siquiera puede consultarlas). Solo ve publicaciones publicadas y la configuración.
revoke all on public.ventas_cuentas, public.mensajes_venta, public.saldos_vendedor, public.retiros, public.movimientos_vendedor,
              public.mercado_admins, public.cuentas_contacto, public.ordenes_recarga, public.mensajes_recarga,
              public.soporte_chats, public.mensajes_soporte, public.calificaciones from anon;
revoke insert, update, delete on public.cuentas_venta, public.mercado_config from anon;
-- Nadie (fuera del panel de Supabase) puede vaciar tablas ni crear disparadores
revoke truncate, references, trigger on all tables in schema public from anon, authenticated;
-- Las funciones nuevas que se creen en el futuro NO quedan abiertas al público por defecto
alter default privileges in schema public revoke execute on functions from public;
-- Los disparadores no se llaman desde la API
revoke execute on function public.cuentas_venta_reglas() from public, anon, authenticated;

-- Funciones internas: nadie las llama desde la API
revoke execute on function public._mensaje_sistema(bigint, text) from public, anon, authenticated;
revoke execute on function public._mover_saldo(uuid, numeric, text, bigint, bigint, text) from public, anon, authenticated;
revoke execute on function public._venta_cerrar(bigint, text) from public, anon, authenticated;
revoke execute on function public._venta_cancelar(bigint, text, text) from public, anon, authenticated;
revoke execute on function public._rol_en_venta(public.ventas_cuentas) from public, anon, authenticated;
revoke execute on function public._exigir_admin() from public, anon, authenticated;
revoke execute on function public._config_num(text, numeric) from public, anon, authenticated;
revoke execute on function public._mover_recargado(uuid, numeric, text, bigint, bigint, text) from public, anon, authenticated;
revoke execute on function public._mensaje_recarga(bigint, text) from public, anon, authenticated;
revoke execute on function public._enviar_correo(text, text, text, text), public._html(text),
  public._notificar(uuid, text, text, text, text, boolean, boolean), public._notificar_admins(text, text, text, text, boolean, boolean),
  public._ventas_por_liberar(uuid) from public, anon, authenticated;
-- Las de usuario y admin requieren sesión (las de admin comprueban además es_admin())
revoke execute on function public.venta_crear(bigint, boolean),
  public.venta_finalizar(bigint), public.venta_reclamar(bigint, text, text), public.venta_cancelar(bigint),
  public.venta_entregar(bigint), public.retiro_solicitar(numeric, text, text), public.mensaje_enviar(bigint, text),
  public.admin_moderar_cuenta(bigint, boolean, text), public.admin_resolver(bigint, text, text),
  public.admin_cancelar(bigint, text, boolean), public.admin_resolver_retiro(bigint, boolean, text),
  public.admin_ajustar_saldo(uuid, numeric, text), public.admin_config(text, text), public.admin_correos(uuid[]),
  public.recarga_crear(text, numeric, text, text), public.recarga_mensaje(bigint, text),
  public.admin_recarga_aprobar(bigint, numeric), public.admin_recarga_rechazar(bigint, text), public.admin_recarga_eliminar(bigint, boolean)
  from public, anon;
grant execute on function public.venta_crear(bigint, boolean),
  public.venta_finalizar(bigint), public.venta_reclamar(bigint, text, text), public.venta_cancelar(bigint),
  public.venta_entregar(bigint), public.retiro_solicitar(numeric, text, text), public.mensaje_enviar(bigint, text),
  public.admin_moderar_cuenta(bigint, boolean, text), public.admin_resolver(bigint, text, text),
  public.admin_cancelar(bigint, text, boolean), public.admin_resolver_retiro(bigint, boolean, text),
  public.admin_ajustar_saldo(uuid, numeric, text), public.admin_config(text, text), public.admin_correos(uuid[]),
  public.recarga_crear(text, numeric, text, text), public.recarga_mensaje(bigint, text),
  public.admin_recarga_aprobar(bigint, numeric), public.admin_recarga_rechazar(bigint, text), public.admin_recarga_eliminar(bigint, boolean)
  to authenticated;
grant execute on function public.mercado_mantenimiento(), public.mercado_reputacion(uuid[]), public.es_admin() to anon, authenticated;

-- ---------------------------------------------------------------------
-- Fotos: bucket público, 1 MB por foto (la página las comprime a WebP antes de subir).
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('cuentas-fotos', 'cuentas-fotos', true, 1048576, array['image/webp', 'image/jpeg', 'image/png'])
on conflict (id) do update set public = true, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

-- Cuántos archivos tiene el usuario que llama en su carpeta de un bucket (p_horas = 0: todos; si no, los de las últimas p_horas)
create or replace function public._mis_archivos(p_bucket text, p_horas int)
returns bigint language sql stable security definer set search_path = public as $f$
  select count(*) from storage.objects o
   where o.bucket_id = p_bucket and o.name like auth.uid()::text || '/%'
     and (p_horas = 0 or o.created_at > now() - make_interval(hours => p_horas));
$f$;
revoke execute on function public._mis_archivos(text, int) from public, anon;
grant execute on function public._mis_archivos(text, int) to authenticated;
-- Cada usuario sube solo a su carpeta y como máximo 80 fotos en total (evita que alguien llene tu Storage)
drop policy if exists "cuentas-fotos subir propias" on storage.objects;
create policy "cuentas-fotos subir propias" on storage.objects for insert to authenticated
  with check (bucket_id = 'cuentas-fotos' and (storage.foldername(name))[1] = auth.uid()::text
              and public._mis_archivos('cuentas-fotos', 0) < 80);
drop policy if exists "cuentas-fotos borrar admin" on storage.objects;
create policy "cuentas-fotos borrar admin" on storage.objects for delete to authenticated
  using (bucket_id = 'cuentas-fotos' and public.es_admin());
drop policy if exists "cuentas-fotos borrar propias" on storage.objects;
create policy "cuentas-fotos borrar propias" on storage.objects for delete to authenticated
  using (bucket_id = 'cuentas-fotos' and (storage.foldername(name))[1] = auth.uid()::text);

-- ---------------------------------------------------------------------
-- Comprobantes de recarga: bucket PRIVADO (solo el dueño y los admins los ven, con enlaces firmados).
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('comprobantes', 'comprobantes', false, 2097152, array['image/webp', 'image/jpeg', 'image/png'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "comprobantes subir propios" on storage.objects;
create policy "comprobantes subir propios" on storage.objects for insert to authenticated
  with check (bucket_id = 'comprobantes' and (storage.foldername(name))[1] = auth.uid()::text
              and public._mis_archivos('comprobantes', 24) < 20);
drop policy if exists "comprobantes ver propios o admin" on storage.objects;
create policy "comprobantes ver propios o admin" on storage.objects for select to authenticated
  using (bucket_id = 'comprobantes' and ((storage.foldername(name))[1] = auth.uid()::text or public.es_admin()));
-- El dueño solo borra una captura que no quedó en ninguna orden (subida fallida); los admins, cualquiera
drop policy if exists "comprobantes borrar" on storage.objects;
create policy "comprobantes borrar" on storage.objects for delete to authenticated
  using (bucket_id = 'comprobantes' and (public.es_admin() or (
    (storage.foldername(name))[1] = auth.uid()::text
    and not exists (select 1 from public.ordenes_recarga o where o.captura = name))));

-- ---------------------------------------------------------------------
-- Chat EN VIVO: estas tablas avisan al navegador apenas cambian (Supabase Realtime respeta el RLS de arriba:
-- cada quien solo recibe lo que puede leer).
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['mensajes_venta', 'mensajes_recarga', 'mensajes_soporte', 'ordenes_recarga', 'notificaciones'] loop
      if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
        execute format('alter publication supabase_realtime add table public.%I', t);
      end if;
    end loop;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Tarea automática cada 10 min (si activas pg_cron en Database → Extensions; si no, la página
-- y las funciones llaman a mercado_mantenimiento() igual).
-- ---------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('mercado-mantenimiento', '*/10 * * * *', 'select public.mercado_mantenimiento()');
  end if;
end $$;
