// Edge Function de Supabase: manda las notificaciones push de Level Up.
//
// - POST { id }  → la llama la base de datos (pg_net, desde _notificar) cuando se crea un aviso.
//                  Toma el aviso con push_tomar (una sola vez), lo manda a los dispositivos de su dueño
//                  y guarda el resultado con push_resultado (borra los dispositivos que ya no existen).
// - GET          → devuelve la clave PÚBLICA VAPID, que la tienda necesita para activar los avisos.
//
// Secretos de la función (Supabase → Edge Functions → Secrets), NUNCA en el código:
//   VAPID_PUBLICA, VAPID_PRIVADA  (se generan con: npx web-push generate-vapid-keys)
//   VAPID_CONTACTO                (opcional, ej. mailto:tucorreo@gmail.com)
// SUPABASE_URL y SUPABASE_SERVICE_ROLE_KEY los pone Supabase solo.
//
// Debe desplegarse SIN "Verify JWT" (la llama la base de datos y la tienda sin sesión). Es seguro:
// con un id cualquiera solo se manda (una vez) un aviso que ya existía, y solo a su dueño.
import webpush from 'npm:web-push@3.6.7';
import { createClient } from 'npm:@supabase/supabase-js@2';

// Se limpian espacios, comillas y saltos de línea que a veces se pegan al copiar las claves
const limpiar = (v: string | undefined) => String(v ?? '').replace(/^(VAPID_[A-Z]+\s*[:=]\s*)/i, '').replace(/[\s"']/g, '');
const PUBLICA = limpiar(Deno.env.get('VAPID_PUBLICA'));
const PRIVADA = limpiar(Deno.env.get('VAPID_PRIVADA'));
const CONTACTO = /^(mailto:|https:)/.test(String(Deno.env.get('VAPID_CONTACTO') ?? '').trim()) ? String(Deno.env.get('VAPID_CONTACTO')).trim() : 'mailto:soporte@levelup.app';
const CORS = { 'access-control-allow-origin': '*', 'access-control-allow-methods': 'GET, POST, OPTIONS', 'access-control-allow-headers': 'content-type, authorization, apikey' };
const responder = (datos: unknown, estado = 200) => new Response(JSON.stringify(datos), { status: estado, headers: { ...CORS, 'content-type': 'application/json' } });

// Si las claves están mal, la función NO se cae: lo dice al abrir su dirección (GET)
let problema = '';
if (!PUBLICA || !PRIVADA) problema = 'Faltan los secretos VAPID_PUBLICA y/o VAPID_PRIVADA.';
else {
  try { webpush.setVapidDetails(CONTACTO, PUBLICA, PRIVADA); }
  catch (e) { problema = `Las claves VAPID no son válidas (${(e as Error).message}). Vuelve a copiarlas sin espacios.`; }
}
const URL_BD = Deno.env.get('SUPABASE_URL') ?? '';
const CLAVE_BD = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
if (!problema && (!URL_BD || !CLAVE_BD)) problema = 'Supabase no entregó SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY a la función.';
const db = URL_BD && CLAVE_BD ? createClient(URL_BD, CLAVE_BD, { auth: { persistSession: false } }) : null;

type Suscripcion = { endpoint: string; keys: { p256dh: string; auth: string } };

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: CORS });
  if (req.method === 'GET') return responder(problema ? { publica: null, problema } : { publica: PUBLICA });
  if (req.method !== 'POST') return responder({ error: 'metodo' }, 405);
  if (problema) return responder({ error: problema }, 500);

  let id = 0;
  try { id = Number((await req.json())?.id); } catch { /* cuerpo inválido */ }
  if (!Number.isSafeInteger(id) || id <= 0) return responder({ error: 'id' }, 400);

  const { data: aviso, error } = await db!.rpc('push_tomar', { p_id: id });
  if (error) return responder({ error: error.message }, 500);
  if (!aviso) return responder({ omitido: true });   // ya se mandó, es viejo o no existe

  const carga = JSON.stringify({ titulo: aviso.titulo, texto: aviso.texto, ruta: aviso.ruta, etiqueta: aviso.etiqueta });
  let enviados = 0;
  const caducadas: string[] = [];
  await Promise.all((aviso.suscripciones as Suscripcion[]).map(async (s) => {
    try {
      await webpush.sendNotification(s, carga, { TTL: 60 * 60 * 24, urgency: 'high', topic: String(aviso.etiqueta).replace(/[^A-Za-z0-9_-]/g, '').slice(0, 32) });
      enviados += 1;
    } catch (e) {
      const codigo = (e as { statusCode?: number }).statusCode;
      // 404/410: el dispositivo ya no existe. 401/403: la suscripción es de otras claves VAPID (hay que volver a activar).
      if (codigo === 404 || codigo === 410 || codigo === 401 || codigo === 403) caducadas.push(s.endpoint);
      else console.error('push', codigo, (e as Error).message);
    }
  }));
  await db!.rpc('push_resultado', { p_id: id, p_enviados: enviados, p_caducadas: caducadas });
  return responder({ enviados, caducadas: caducadas.length });
});
