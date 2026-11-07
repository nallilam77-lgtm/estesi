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
--                    y el dinero queda RETENIDO por Level Up.
--   (pendiente_pago → solo tratos viejos, de antes del saldo: el comprador informaba el pago y un admin lo confirmaba.)
--   entregada      → el vendedor entregó los datos en el chat del trato. El comprador tiene `horas_revision`
--                    para "Finalizar" o "Tengo un problema" (con video); si no hace nada, se cierra solo.
--   en_reclamo     → un admin decide: a favor del vendedor (se cierra) o del comprador (se cancela y se reembolsa).
--   cerrada        → el precio COMPLETO pasa al saldo del vendedor y la cuenta queda "vendida".
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
  ('pm_banco', ''), ('pm_telefono', ''), ('pm_cedula', ''), ('pm_titular', '')
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
  return v_id;
end $$;

create or replace function public.venta_informar_pago(p_venta bigint, p_metodo text, p_referencia text)
returns void language plpgsql security definer set search_path = public as $$
declare v ventas_cuentas;
begin
  select * into v from ventas_cuentas where id = p_venta for update;
  if not found or v.comprador is distinct from auth.uid() then raise exception 'NO_PERMITIDO'; end if;
  if v.estado <> 'pendiente_pago' then raise exception 'ESTADO_INVALIDO'; end if;
  if p_metodo not in ('Pago Móvil', 'Binance', 'Zinli', 'Otro') then raise exception 'DATO_INVALIDO'; end if;
  if coalesce(p_referencia, '') !~ '^[A-Za-z0-9-]{4,40}$' then raise exception 'DATO_INVALIDO'; end if;
  update ventas_cuentas set metodo_pago = p_metodo, referencia_pago = p_referencia, pago_informado_en = now(), actualizado = now()
   where id = p_venta;
  perform _mensaje_sistema(p_venta, format('El comprador informó su pago por %s (referencia %s). Level Up lo está verificando.', p_metodo, p_referencia));
end $$;

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

  comision := round(monto * _config_num('comision_retiro', 4) / 100, 2);
  insert into retiros (vendedor, monto_usd, comision_usd, neto_usd, metodo, datos)
  values (auth.uid(), monto, comision, monto - comision, p_metodo, trim(p_datos))
  returning id into r_id;
  perform _mover_saldo(auth.uid(), -monto, 'retiro', null, r_id, format('Retiro R-%s (%s USD - %s USD de comisión)', r_id, monto, comision));
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
  else
    update ordenes_recarga set msg_admin = now() where id = p_orden;
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
           v.estado = 'en_reclamo' and m.rol <> 'admin'
      from ventas_cuentas v
      join lateral (select x.texto, x.rol, x.creado from mensajes_venta x where x.venta = v.id and x.rol <> 'sistema' order by x.id desc limit 1) m on true
  ) b
  order by 7 desc
  limit least(greatest(coalesce(p_limite, 80), 1), 200);
end $$;

-- Reputación pública: ventas cerradas de cada vendedor (sin datos personales)
create or replace function public.mercado_reputacion(p_vendedores uuid[])
returns table (vendedor uuid, ventas int) language sql stable security definer set search_path = public as $$
  select s.vendedor, s.ventas from saldos_vendedor s where s.vendedor = any (p_vendedores[1:100]);
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
end $$;

create or replace function public.admin_confirmar_pago(p_venta bigint)
returns void language plpgsql security definer set search_path = public as $$
declare v ventas_cuentas;
begin
  perform _exigir_admin();
  select * into v from ventas_cuentas where id = p_venta for update;
  if not found or v.estado <> 'pendiente_pago' then raise exception 'ESTADO_INVALIDO'; end if;
  update ventas_cuentas set estado = 'pagada', pagada_en = now(), actualizado = now() where id = p_venta;
  perform _mensaje_sistema(p_venta, format(
    'Level Up confirmó el pago de %s USD: el dinero queda RETENIDO hasta el cierre. VENDEDOR: entrega aquí el correo/usuario y la contraseña de la cuenta y luego toca "Ya entregué los datos".', v.total_usd));
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
  else
    update retiros set estado = 'rechazado', motivo = left(trim(coalesce(p_texto, '')), 200), resuelto = now() where id = p_retiro;
    perform _mover_saldo(r.vendedor, r.monto_usd, 'retiro_devuelto', null, r.id, format('Retiro R-%s rechazado: %s', r.id, coalesce(nullif(trim(p_texto), ''), 'sin motivo')));
  end if;
end $$;

create or replace function public.admin_ajustar_saldo(p_vendedor uuid, p_monto numeric, p_detalle text)
returns numeric language plpgsql security definer set search_path = public as $$
begin
  perform _exigir_admin();
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
declare numericas text[] := array['comision_retiro', 'retiro_minimo', 'garantia_usd', 'horas_pago', 'horas_revision', 'tasa_bs', 'recarga_minima', 'paypal_recargo'];
begin
  perform _exigir_admin();
  if not (p_clave = any (numericas) or p_clave in ('instrucciones_pago', 'binance_pay_id', 'binance_nombre', 'paypal_correo', 'paypal_nombre',
                                                   'pm_banco', 'pm_telefono', 'pm_cedula', 'pm_titular')) then
    raise exception 'DATO_INVALIDO';
  end if;
  if p_clave = any (numericas) and nullif(trim(p_valor), '') is not null and trim(p_valor) !~ '^[0-9]+(\.[0-9]+)?$' then
    raise exception 'DATO_INVALIDO';
  end if;
  update mercado_config set valor = left(trim(coalesce(p_valor, '')), case when p_clave = 'instrucciones_pago' then 600 else 120 end)
   where clave = p_clave;
end $$;

-- Correos de comprador/vendedor para el panel (auth.users no es accesible desde la API)
create or replace function public.admin_correos(p_ids uuid[])
returns table (id uuid, email text) language plpgsql stable security definer set search_path = public as $$
begin
  perform _exigir_admin();
  return query select u.id, u.email::text from auth.users u where u.id = any (p_ids[1:200]);
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
alter table public.mensajes_soporte enable row level security;

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
drop policy if exists "soporte propio" on public.soporte_chats;
create policy "soporte propio" on public.soporte_chats for select to authenticated using (usuario = auth.uid() or public.es_admin());
drop policy if exists "mensajes de soporte propios" on public.mensajes_soporte;
create policy "mensajes de soporte propios" on public.mensajes_soporte for select to authenticated using (usuario = auth.uid() or public.es_admin());

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
-- Las de usuario y admin requieren sesión (las de admin comprueban además es_admin())
revoke execute on function public.venta_crear(bigint, boolean), public.venta_informar_pago(bigint, text, text),
  public.venta_finalizar(bigint), public.venta_reclamar(bigint, text, text), public.venta_cancelar(bigint),
  public.venta_entregar(bigint), public.retiro_solicitar(numeric, text, text), public.mensaje_enviar(bigint, text),
  public.admin_moderar_cuenta(bigint, boolean, text), public.admin_confirmar_pago(bigint), public.admin_resolver(bigint, text, text),
  public.admin_cancelar(bigint, text, boolean), public.admin_resolver_retiro(bigint, boolean, text),
  public.admin_ajustar_saldo(uuid, numeric, text), public.admin_config(text, text), public.admin_correos(uuid[]),
  public.recarga_crear(text, numeric, text, text), public.recarga_mensaje(bigint, text),
  public.admin_recarga_aprobar(bigint, numeric), public.admin_recarga_rechazar(bigint, text), public.admin_recarga_eliminar(bigint, boolean)
  from public, anon;
grant execute on function public.venta_crear(bigint, boolean), public.venta_informar_pago(bigint, text, text),
  public.venta_finalizar(bigint), public.venta_reclamar(bigint, text, text), public.venta_cancelar(bigint),
  public.venta_entregar(bigint), public.retiro_solicitar(numeric, text, text), public.mensaje_enviar(bigint, text),
  public.admin_moderar_cuenta(bigint, boolean, text), public.admin_confirmar_pago(bigint), public.admin_resolver(bigint, text, text),
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

drop policy if exists "cuentas-fotos subir propias" on storage.objects;
create policy "cuentas-fotos subir propias" on storage.objects for insert to authenticated
  with check (bucket_id = 'cuentas-fotos' and (storage.foldername(name))[1] = auth.uid()::text);
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
  with check (bucket_id = 'comprobantes' and (storage.foldername(name))[1] = auth.uid()::text);
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
    foreach t in array array['mensajes_venta', 'mensajes_recarga', 'mensajes_soporte', 'ordenes_recarga'] loop
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
