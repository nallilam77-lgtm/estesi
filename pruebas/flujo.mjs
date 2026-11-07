// =========================================================================
// PRUEBA DEL FLUJO COMPLETO de supabase/cuentas.sql en un Postgres en memoria (PGlite).
// Simula lo mínimo de Supabase (auth.users, auth.uid(), storage, roles anon/authenticated, pg_net y Vault)
// y recorre: recarga → publicar → aprobar → comprar → chat → entregar → finalizar → retiro (con liberación),
// reembolso automático por no entregar, cierre automático, reclamo, avisos y correos, errores de la web,
// borrar cuenta y que el dinero cuadre al final. Corre el SQL DOS veces (debe ser re-ejecutable).
//
// Uso:  cd pruebas && npm install && npm test
// =========================================================================
import { PGlite } from '@electric-sql/pglite';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const SQL = readFileSync(fileURLToPath(new URL('../supabase/cuentas.sql', import.meta.url)), 'utf8');
const db = new PGlite();

let pasadas = 0;
const fallos = [];
function ok(condicion, texto) {
  if (condicion) { pasadas += 1; console.log(`  ✓ ${texto}`); } else { fallos.push(texto); console.log(`  ✗ ${texto}`); }
}
const igual = (a, b, texto) => ok(Number(a) === Number(b), `${texto} (esperado ${b}, salió ${a})`);
const titulo = (t) => console.log(`\n▶ ${t}`);

// ---------- Supabase simulado ----------
await db.exec(`
  create role anon nologin; create role authenticated nologin;
  create schema auth;
  create table auth.users (id uuid primary key default gen_random_uuid(), email text, phone text unique, encrypted_password text,
    raw_user_meta_data jsonb default '{}', banned_until timestamptz, created_at timestamptz default now(), last_sign_in_at timestamptz);
  create table auth.identities (id uuid primary key default gen_random_uuid(), user_id uuid references auth.users on delete cascade);
  create table auth.sessions (id uuid primary key default gen_random_uuid(), user_id uuid references auth.users on delete cascade);
  create table auth.refresh_tokens (id bigserial primary key, user_id varchar(255));
  create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
  create function auth.role() returns text language sql stable as $$ select nullif(current_setting('request.jwt.claim.role', true), '') $$;
  create schema storage;
  create table storage.buckets (id text primary key, name text, public boolean, file_size_limit bigint, allowed_mime_types text[]);
  create table storage.objects (id uuid primary key default gen_random_uuid(), bucket_id text, name text, owner uuid,
    created_at timestamptz default now(), metadata jsonb default '{}');
  create function storage.foldername(name text) returns text[] language sql immutable as $$
    select (string_to_array(name, '/'))[1:array_length(string_to_array(name, '/'), 1) - 1] $$;
  grant usage on schema auth, storage, public to anon, authenticated;
  grant execute on function auth.uid(), auth.role() to anon, authenticated;
  create publication supabase_realtime;
`);

titulo('Instalar el SQL (2 veces: debe ser re-ejecutable)');
await db.exec(SQL);
ok(true, 'primera ejecución sin errores');
await db.exec(SQL);
ok(true, 'segunda ejecución sin errores');

// ---------- Utilidades ----------
async function comoSuper() { await db.exec(`reset role; select set_config('request.jwt.claim.sub', '', false), set_config('request.jwt.claim.role', '', false);`); }
async function como(uid) {
  await comoSuper();
  const rol = uid ? 'authenticated' : 'anon';
  await db.exec(`select set_config('request.jwt.claim.sub', '${uid || ''}', false), set_config('request.jwt.claim.role', '${rol}', false); set role ${rol};`);
}
async function sql(q, params = []) { await comoSuper(); return (await db.query(q, params)).rows; }
async function rpc(uid, nombre, args = {}) {
  await como(uid);
  const claves = Object.keys(args);
  const lista = claves.map((k, i) => `${k} => $${i + 1}`).join(', ');
  try {
    const r = await db.query(`select public.${nombre}(${lista}) as r`, claves.map((k) => args[k]));
    return r.rows[0]?.r;
  } finally { await comoSuper(); }
}
async function falla(promesa, codigo, texto) {
  try { await promesa; ok(false, `${texto}: debía fallar con ${codigo}`); } catch (e) { ok(String(e.message).includes(codigo), `${texto} → ${codigo}${String(e.message).includes(codigo) ? '' : ` (salió: ${e.message})`}`); }
}
async function leer(uid, q, params = []) { await como(uid); try { return (await db.query(q, params)).rows; } finally { await comoSuper(); } }
const saldo = async (u) => (await sql('select disponible, recargado from saldos_vendedor where vendedor = $1', [u]))[0] || { disponible: 0, recargado: 0 };
const avisos = (u, tipo) => sql('select * from notificaciones where usuario = $1 and ($2::text is null or tipo = $2) order by id', [u, tipo ?? null]);

const [admin, vendedor, comprador, otro, nuevo] = (await sql(`
  insert into auth.users (email) values ('admin@levelup.test'), ('vende@test.com'), ('compra@test.com'), ('otro@test.com'), ('nuevo@test.com')
  returning id`)).map((r) => r.id);
await sql('insert into mercado_admins (usuario) values ($1)', [admin]);

async function publicar(titulo, precio) {
  const foto = `${vendedor}/${Math.random().toString(36).slice(2, 12)}.webp`;
  await sql(`insert into storage.objects (bucket_id, name, owner) values ('cuentas-fotos', $1, $2)`, [foto, vendedor]);
  const [c] = await leer(vendedor, `insert into cuentas_venta (titulo, nivel, region, vinculacion, precio_usd, fotos)
    values ($1, 70, 'LATAM', 'Google', $2, array[$3]) returning id, estado`, [titulo, precio, foto]);
  await rpc(admin, 'admin_moderar_cuenta', { p_cuenta: c.id, p_aprobar: true });
  return c;
}

// =========================================================================
titulo('Ajustes del admin');
await rpc(admin, 'admin_config', { p_clave: 'binance_pay_id', p_valor: '123456' });
await rpc(admin, 'admin_config', { p_clave: 'horas_entrega', p_valor: '12' });
await rpc(admin, 'admin_config', { p_clave: 'dias_liberacion', p_valor: '3' });
await falla(rpc(admin, 'admin_config', { p_clave: 'sitio_url', p_valor: 'javascript:alert(1)' }), 'DATO_INVALIDO', 'sitio_url inválido');
await falla(rpc(admin, 'admin_config', { p_clave: 'correo_remitente', p_valor: 'no-es-correo' }), 'DATO_INVALIDO', 'remitente inválido');
await falla(rpc(vendedor, 'admin_config', { p_clave: 'binance_pay_id', p_valor: 'x' }), 'SOLO_ADMIN', 'un usuario no cambia ajustes');

titulo('Recarga de saldo');
const captura = `${comprador}/captura0001.webp`;
await sql(`insert into storage.objects (bucket_id, name, owner) values ('comprobantes', $1, $2)`, [captura, comprador]);
const rc = await rpc(comprador, 'recarga_crear', { p_metodo: 'binance', p_monto: 50, p_referencia: 'REF1234', p_captura: captura });
ok(rc > 0, `orden RC-${rc} creada`);
igual((await avisos(admin, 'recarga')).length, 1, 'el admin recibe un aviso de recarga');
await rpc(admin, 'admin_recarga_aprobar', { p_orden: rc });
igual((await saldo(comprador)).recargado, 50, 'saldo recargado del comprador');
const [avRecarga] = await avisos(comprador, 'recarga');
ok(avRecarga && avRecarga.correo === 'sin_config', 'aviso de recarga aprobada (correo: sin_config porque no hay Brevo)');

titulo('Publicar y aprobar');
await rpc(vendedor, 'perfil_guardar', { p_nombre: 'Vendedor Uno', p_descripcion: '' });
const c1 = await publicar('Cuenta nivel 70 con Cobra', 20);
ok(c1.estado === 'revision', 'la publicación entra en revisión');
igual((await avisos(vendedor, 'moderacion')).length, 1, 'aviso al vendedor cuando se aprueba');

titulo('Comprar, chatear, entregar y finalizar');
const t1 = await rpc(comprador, 'venta_crear', { p_cuenta: c1.id, p_garantia: false });
igual((await saldo(comprador)).recargado, 30, 'se descuentan 20 USD del comprador');
const [avVenta] = await avisos(vendedor, 'venta');
ok(avVenta && avVenta.enlace === `trato-${t1}`, 'el vendedor recibe "¡Vendiste!" con enlace al trato');
await rpc(comprador, 'mensaje_enviar', { p_venta: t1, p_texto: 'Hola' });
await rpc(comprador, 'mensaje_enviar', { p_venta: t1, p_texto: '¿Estás?' });
igual((await avisos(vendedor, 'mensaje')).length, 1, 'dos mensajes seguidos = un solo aviso (agrupado)');
ok(!(await avisos(vendedor, 'mensaje'))[0].texto.includes('Hola'), 'el aviso NO copia el texto del chat (puede llevar contraseñas)');
igual((await leer(otro, 'select * from notificaciones')).length, 0, 'otro usuario no ve avisos ajenos (RLS)');
await falla(leer(null, 'select * from notificaciones'), 'permission denied', 'sin sesión no se leen avisos');
await rpc(vendedor, 'notificaciones_leer', { p_enlace: `trato-${t1}` });
igual((await sql('select count(*) n from notificaciones where usuario = $1 and not leida and enlace = $2', [vendedor, `trato-${t1}`]))[0].n, 0, 'marcar leídos los avisos de un trato');
await rpc(comprador, 'mensaje_enviar', { p_venta: t1, p_texto: 'Otro' });
igual((await avisos(vendedor, 'mensaje')).length, 2, 'tras leer, un mensaje nuevo vuelve a avisar');
await rpc(vendedor, 'venta_entregar', { p_venta: t1 });
igual((await avisos(comprador, 'entrega')).length, 1, 'aviso de entrega al comprador');
await rpc(comprador, 'venta_finalizar', { p_venta: t1 });
igual((await saldo(vendedor)).disponible, 20, 'el vendedor cobra el precio completo');
igual((await avisos(vendedor, 'cobro')).length, 1, 'aviso de cobro al vendedor');
igual((await avisos(comprador, 'calificar')).length, 1, 'aviso para calificar al comprador');

titulo('Liberación del saldo de ventas');
let ms = await rpc(vendedor, 'mi_saldo');
igual(ms.retirable, 0, 'recién vendido: retirable 0');
igual(ms.por_liberar, 20, 'por liberar: 20');
await falla(rpc(vendedor, 'retiro_solicitar', { p_monto: 10, p_metodo: 'Binance', p_datos: 'vende@binance' }), 'SALDO_RETENIDO', 'no se retira antes de los días de liberación');
await sql(`update ventas_cuentas set cerrada_en = now() - interval '4 days' where id = $1`, [t1]);
ms = await rpc(vendedor, 'mi_saldo');
igual(ms.retirable, 20, 'pasados los días: retirable 20');
const r1 = await rpc(vendedor, 'retiro_solicitar', { p_monto: 10, p_metodo: 'Binance', p_datos: 'vende@binance' });
ok(r1 > 0, `retiro R-${r1} pedido`);
igual((await avisos(admin, 'retiro')).length, 1, 'aviso de retiro al admin');
await rpc(admin, 'admin_resolver_retiro', { p_retiro: r1, p_pagado: true, p_texto: 'REF-99' });
igual((await avisos(vendedor, 'retiro')).length, 1, 'aviso de retiro pagado');
await rpc(admin, 'admin_config', { p_clave: 'dias_liberacion', p_valor: '0' });
igual((await rpc(vendedor, 'mi_saldo')).por_liberar, 0, 'con 0 días no se retiene nada');
await rpc(admin, 'admin_config', { p_clave: 'dias_liberacion', p_valor: '3' });

titulo('Reembolso automático si el vendedor no entrega');
const c2 = await publicar('Cuenta nivel 70 con Angelical', 10);
const t2 = await rpc(comprador, 'venta_crear', { p_cuenta: c2.id, p_garantia: false });
igual((await saldo(comprador)).recargado, 20, 'comprador paga 10');
await rpc(null, 'mercado_mantenimiento');
ok((await sql('select estado from ventas_cuentas where id = $1', [t2]))[0].estado === 'pagada', 'antes del plazo sigue abierto');
await sql(`update ventas_cuentas set pagada_en = now() - interval '13 hours' where id = $1`, [t2]);
await rpc(null, 'mercado_mantenimiento');
ok((await sql('select estado from ventas_cuentas where id = $1', [t2]))[0].estado === 'cancelada', 'pasado el plazo se cancela solo');
igual((await saldo(comprador)).recargado, 30, 'el comprador recupera sus 10 USD');
ok((await sql('select estado from cuentas_venta where id = $1', [c2.id]))[0].estado === 'pausada', 'la publicación queda pausada');
ok((await avisos(comprador, 'cancelado')).length === 1 && (await avisos(vendedor, 'cancelado')).length === 1, 'avisos de cancelación a las dos partes');

titulo('Con apelación NO se cancela solo');
await leer(vendedor, `update cuentas_venta set estado = 'publicada' where id = $1`, [c2.id]);
const t3 = await rpc(comprador, 'venta_crear', { p_cuenta: c2.id, p_garantia: false });
await rpc(comprador, 'venta_apelar', { p_venta: t3, p_motivo: 'El vendedor no responde' });
igual((await avisos(admin, 'apelacion')).length, 1, 'aviso de apelación al admin');
await sql(`update ventas_cuentas set pagada_en = now() - interval '20 hours' where id = $1`, [t3]);
await rpc(null, 'mercado_mantenimiento');
ok((await sql('select estado from ventas_cuentas where id = $1', [t3]))[0].estado === 'pagada', 'apelado: espera al admin');
igual((await rpc(admin, 'admin_estado')).sin_entregar_vencidos, 0, 'admin_estado no lo cuenta como vencido (está apelado)');

titulo('Cierre automático tras la revisión');
await rpc(vendedor, 'venta_entregar', { p_venta: t3 });
await sql(`update ventas_cuentas set entregada_en = now() - interval '25 hours' where id = $1`, [t3]);
await rpc(null, 'mercado_mantenimiento');
ok((await sql('select estado from ventas_cuentas where id = $1', [t3]))[0].estado === 'cerrada', 'se cierra solo y el vendedor cobra');

titulo('Reclamo resuelto a favor del comprador');
const c3 = await publicar('Cuenta nivel 70 con M1887', 5);
const t4 = await rpc(comprador, 'venta_crear', { p_cuenta: c3.id, p_garantia: true });
await rpc(vendedor, 'venta_entregar', { p_venta: t4 });
await rpc(comprador, 'venta_reclamar', { p_venta: t4, p_motivo: 'La cuenta no tiene la skin', p_video: 'https://drive.google.com/x' });
igual((await avisos(admin, 'reclamo')).length, 1, 'aviso de reclamo al admin');
igual((await avisos(vendedor, 'reclamo')).length, 1, 'aviso de reclamo al vendedor');
const antes = await saldo(comprador);
await rpc(admin, 'admin_resolver', { p_venta: t4, p_favor: 'comprador', p_nota: 'El video lo muestra' });
igual(Number((await saldo(comprador)).recargado), Number(antes.recargado) + 6, 'reembolso completo (precio + garantía)');

titulo('Errores de la web');
await rpc(null, 'error_registrar', { p_pagina: 'index.html', p_mensaje: 'TypeError: x is null', p_detalle: 'stack', p_navegador: 'UA' });
await rpc(null, 'error_registrar', { p_pagina: 'index.html', p_mensaje: 'TypeError: x is null', p_detalle: 'stack', p_navegador: 'UA' });
const errores = await sql('select * from errores_cliente');
ok(errores.length === 1 && errores[0].veces === 2, 'el mismo error se suma (veces = 2)');
await falla(leer(null, 'select * from errores_cliente'), 'permission denied', 'sin sesión no se leen errores');
igual((await leer(vendedor, 'select * from errores_cliente')).length, 0, 'un usuario no ve errores');
igual((await rpc(admin, 'admin_estado')).errores_24h, 2, 'admin_estado cuenta los errores');

titulo('Correos (pg_net + Vault simulados)');
igual((await sql(`select count(*) n from notificaciones where correo = 'sin_config'`))[0].n > 0 ? 1 : 0, 1, 'sin Brevo los avisos quedan como sin_config');
await comoSuper();
await db.exec(`
  create schema net; create table net.enviados (id bigserial primary key, url text, body jsonb, headers jsonb);
  create function net.http_post(url text, body jsonb, params jsonb, headers jsonb, timeout_milliseconds integer) returns bigint
    language sql as $$ insert into net.enviados (url, body, headers) values (url, body, headers) returning id $$;
  create schema vault; create table vault.secrets (name text, secret text, created_at timestamptz default now());
  create view vault.decrypted_secrets as select name, secret as decrypted_secret, created_at from vault.secrets;
  insert into vault.secrets (name, secret) values ('brevo_api_key', 'xkeysib-prueba');`);
igual(await rpc(admin, 'admin_correo_prueba') === 'sin_config' ? 1 : 0, 1, 'sin remitente: sin_config');
await rpc(admin, 'admin_config', { p_clave: 'correo_remitente', p_valor: 'hola@levelup.test' });
ok(await rpc(admin, 'admin_correo_prueba') === 'enviado', 'correo de prueba enviado');
const [prueba] = await sql('select * from net.enviados order by id desc limit 1');
ok(prueba.url === 'https://api.brevo.com/v3/smtp/email' && prueba.body.to[0].email === 'admin@levelup.test' && prueba.headers['api-key'] === 'xkeysib-prueba',
  'el correo va a Brevo, al admin y con la clave de Vault');
await rpc(admin, 'soporte_mensaje', { p_usuario: comprador, p_texto: 'Hola, <b>¿todo bien?</b>' });
const [avSop] = await avisos(comprador, 'soporte');
ok(avSop?.correo === 'enviado', 'respuesta de soporte → correo enviado');
const [ultimo] = await sql('select body from net.enviados order by id desc limit 1');
ok(!ultimo.body.htmlContent.includes('<b>'), 'el HTML del correo no deja pasar etiquetas del texto');
await rpc(admin, 'soporte_mensaje', { p_usuario: comprador, p_texto: 'Otro' });
igual((await avisos(comprador, 'soporte')).length, 1, 'segunda respuesta sin leer: no se repite aviso ni correo');
await rpc(comprador, 'notificaciones_leer', {});
await rpc(comprador, 'preferencias_guardar', { p_correos: false });
await rpc(admin, 'soporte_mensaje', { p_usuario: comprador, p_texto: 'Tercera' });
ok((await avisos(comprador, 'soporte')).pop().correo === 'apagado', 'si el usuario apaga los correos, no se le escribe');
const est = await rpc(admin, 'admin_estado');
ok(est.correo.pg_net && est.correo.vault && est.correo.clave && est.correo.remitente === 'hola@levelup.test', 'admin_estado muestra el correo configurado');

titulo('Borrar cuenta');
let rev = await rpc(nuevo, 'cuenta_eliminar_revisar');
ok(rev.puede && !rev.historial, 'un usuario sin historial puede borrar su cuenta');
await falla(rpc(nuevo, 'cuenta_eliminar', { p_confirmacion: 'si' }), 'DATO_INVALIDO', 'hay que escribir ELIMINAR');
await rpc(nuevo, 'perfil_guardar', { p_nombre: 'Nuevo', p_descripcion: '' });
const res = await rpc(nuevo, 'cuenta_eliminar', { p_confirmacion: 'eliminar' });
ok(!res.anonimizada, 'borrado completo');
igual((await sql('select count(*) n from auth.users where id = $1', [nuevo]))[0].n, 0, 'ya no existe en Auth');
igual((await sql('select count(*) n from perfiles where usuario = $1', [nuevo]))[0].n, 0, 'su perfil se borró en cascada');
rev = await rpc(comprador, 'cuenta_eliminar_revisar');
ok(!rev.puede && rev.motivo.includes('saldo'), 'con saldo no se puede: hay que usarlo o retirarlo primero');
await falla(rpc(comprador, 'cuenta_eliminar', { p_confirmacion: 'ELIMINAR' }), 'NO_SE_PUEDE_BORRAR', 'cuenta_eliminar respeta la revisión');
await falla(rpc(admin, 'cuenta_eliminar', { p_confirmacion: 'ELIMINAR' }), 'NO_SE_PUEDE_BORRAR', 'un admin no se borra a sí mismo');
const sc = await saldo(comprador);
await rpc(admin, 'admin_ajustar_recargado', { p_usuario: comprador, p_monto: -Number(sc.recargado), p_detalle: 'Devuelto por fuera' });
rev = await rpc(comprador, 'cuenta_eliminar_revisar');
ok(rev.puede && rev.historial, 'sin saldo y con tratos: se puede (se anonimiza)');
const res2 = await rpc(comprador, 'cuenta_eliminar', { p_confirmacion: 'ELIMINAR' });
ok(res2.anonimizada, 'anonimizada');
const [u] = await sql('select email, banned_until from auth.users where id = $1', [comprador]);
ok(u.email.endsWith('@levelup.invalid') && u.banned_until, 'sin correo real y sin acceso');
igual((await sql('select count(*) n from ventas_cuentas where comprador = $1', [comprador]))[0].n, 4, 'los tratos se conservan para la otra parte');

titulo('Limpieza y estado');
const vista = await rpc(admin, 'admin_limpiar', { p_dias: 7, p_que: ['avisos', 'errores'], p_ejecutar: false });
ok('avisos' in vista.conteos && 'errores' in vista.conteos, 'admin_limpiar cuenta avisos y errores');

titulo('El dinero cuadra');
const descuadres = await sql(`
  select s.vendedor, s.disponible + s.recargado as saldo, coalesce(sum(m.monto), 0) as movimientos
    from saldos_vendedor s left join movimientos_vendedor m on m.vendedor = s.vendedor
   group by s.vendedor, s.disponible, s.recargado having s.disponible + s.recargado <> coalesce(sum(m.monto), 0)`);
igual(descuadres.length, 0, 'el saldo de cada usuario = suma de sus movimientos');
const [g] = await sql(`select
    (select coalesce(sum(acreditado_usd), 0) from ordenes_recarga where estado = 'aprobada')
  + (select coalesce(sum(monto), 0) from movimientos_vendedor where tipo = 'ajuste') as entro,
    (select coalesce(sum(disponible + recargado), 0) from saldos_vendedor)
  + (select coalesce(sum(total_usd), 0) from ventas_cuentas where estado in ('pagada', 'entregada', 'en_reclamo'))
  + (select coalesce(sum(monto_usd), 0) from retiros where estado <> 'rechazado')
  + (select coalesce(sum(total_usd - precio_usd), 0) from ventas_cuentas where estado = 'cerrada') as esta`);
igual(g.esta, g.entro, 'todo lo que entró = saldos + retenido + retiros + garantías');

titulo('Re-ejecutar el SQL con datos');
await comoSuper();
await db.exec(SQL);
ok(true, 'tercera ejecución sin errores y con datos');
ok((await rpc(vendedor, 'mi_saldo')).disponible >= 0, 'todo sigue funcionando');

console.log(`\n${fallos.length ? '✗' : '✓'} ${pasadas} comprobaciones bien, ${fallos.length} mal`);
if (fallos.length) { console.log(fallos.map((f) => `  - ${f}`).join('\n')); process.exit(1); }
