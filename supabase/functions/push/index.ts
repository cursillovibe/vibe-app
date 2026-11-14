// VIBE App · función "push": avisos por notificación al celular (web push).
//   tipo "clave":     devuelve la clave pública para que el celular se anote (la crea sola la primera vez).
//   tipo "prueba":    manda un aviso de prueba a los celulares de quien lo pide.
//   tipo "publicado": la dirección publicó el horario → avisa a profes y alumnos.
//   tipo "auto":      lo llama el cron cada 15 minutos. Manda el recordatorio de la noche, el de la mañana
//                     y el de disponibilidad (mié a sáb), cada uno una sola vez por día y solo en su horario.
// No usa secretos propios: las claves VAPID se generan solas y quedan en config_privada (solo la base las lee).
// Se despliega con "Verify JWT" apagado (igual que invitar y notificar): el código valida usuario y rol.
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';
import * as webpush from 'jsr:@negrel/webpush@0.3.0';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

const b64u = (b: Uint8Array) => btoa(String.fromCharCode(...b)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const unb64u = (s: string) => {
  const p = s.replace(/-/g, '+').replace(/_/g, '/');
  return Uint8Array.from(atob(p + '='.repeat((4 - (p.length % 4)) % 4)), (c) => c.charCodeAt(0));
};

// Paraguay está en UTC-3 todo el año
function ahoraPY() {
  const d = new Date(Date.now() - 3 * 3600e3);
  return { ymd: d.toISOString().slice(0, 10), dow: d.getUTCDay(), min: d.getUTCHours() * 60 + d.getUTCMinutes(), hora: d.toISOString().slice(11, 16) };
}
const masDias = (ymd: string, n: number) => { const d = new Date(ymd + 'T12:00:00Z'); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
const aMin = (v: unknown, def: string) => {
  const m = /^(\d{1,2}):(\d{2})$/.exec(String(v ?? '')) || /^(\d{1,2}):(\d{2})$/.exec(def)!;
  return +m[1] * 60 + +m[2];
};

// deno-lint-ignore no-explicit-any
type Db = any;
type Vapid = { publicKey: JsonWebKey; privateKey: JsonWebKey };
type Msg = { endpoint: string; keys: { p256dh: string; auth: string }; titulo: string; cuerpo: string };

// Claves VAPID: se crean una sola vez y se guardan en config_privada
async function claves(db: Db): Promise<{ v: Vapid; publica: string }> {
  let { data } = await db.from('config_privada').select('valor').eq('clave', 'vapid').maybeSingle();
  if (!data) {
    const par = (await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify'])) as CryptoKeyPair;
    const pub = await crypto.subtle.exportKey('jwk', par.publicKey), priv = await crypto.subtle.exportKey('jwk', par.privateKey);
    const valor = { publicKey: { kty: 'EC', crv: 'P-256', x: pub.x, y: pub.y }, privateKey: { kty: 'EC', crv: 'P-256', x: priv.x, y: priv.y, d: priv.d } };
    await db.from('config_privada').insert({ clave: 'vapid', valor }); // si dos llamadas la crean a la vez, queda la primera
    ({ data } = await db.from('config_privada').select('valor').eq('clave', 'vapid').single());
  }
  const v = (data as { valor: Vapid }).valor;
  return { v, publica: b64u(new Uint8Array([4, ...unb64u(v.publicKey.x!), ...unb64u(v.publicKey.y!)])) };
}

async function mandar(db: Db, v: Vapid, msgs: Msg[], url: string, tag: string, ttl: number) {
  const r = { enviados: 0, fallidos: 0, vencidos: 0, errores: [] as string[] };
  if (!msgs.length) return r;
  const vapidKeys = await webpush.importVapidKeys(
    { publicKey: { ...v.publicKey, ext: true }, privateKey: { ...v.privateKey, ext: true } }, { extractable: false });
  const app = await webpush.ApplicationServer.new({ contactInformation: 'mailto:informacion@vibe.com.py', vapidKeys });
  const muertos: string[] = [];
  for (let i = 0; i < msgs.length; i += 20) {
    await Promise.all(msgs.slice(i, i + 20).map(async (m) => {
      try {
        await app.subscribe({ endpoint: m.endpoint, keys: m.keys }).pushTextMessage(JSON.stringify({ title: m.titulo, body: m.cuerpo, url, tag }), { ttl, urgency: webpush.Urgency.High });
        r.enviados++;
      } catch (e) {
        // 404/410: el celular desinstaló la app o venció el permiso · 401/403: suscripción de otra clave. Se borra.
        if (e instanceof webpush.PushMessageError && [401, 403, 404, 410].includes(e.response.status)) { muertos.push(m.endpoint); r.vencidos++; }
        else { r.fallidos++; if (r.errores.length < 5) r.errores.push(e instanceof webpush.PushMessageError ? `HTTP ${e.response.status}` : String(e)); }
      }
    }));
  }
  if (muertos.length) await db.from('push_subs').delete().in('endpoint', muertos);
  return r;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  try {
    const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
    let body: Record<string, unknown> = {};
    try { body = await req.json(); } catch { /* sin cuerpo = auto */ }
    const tipo = String(body.tipo || 'auto');
    const appUrl = Deno.env.get('APP_URL') || 'https://cursillovibe.github.io/vibe-app/';
    const quien = async () => {
      const t = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '');
      if (!t) return null;
      const { data } = await db.auth.getUser(t);
      return data?.user ?? null;
    };

    if (tipo === 'clave') return json({ publica: (await claves(db)).publica });

    if (tipo === 'prueba') {
      const u = await quien();
      if (!u) return json({ error: 'Tenés que iniciar sesión.' }, 401);
      const { data: subs } = await db.from('push_subs').select('endpoint, keys').eq('user_id', u.id);
      const msgs = (subs || []).map((s) => ({ ...s, titulo: 'Avisos de VIBE activados ✅', cuerpo: 'Así te van a llegar los recordatorios de tus clases.' })) as Msg[];
      return json({ ok: true, ...(await mandar(db, (await claves(db)).v, msgs, appUrl, 'prueba', 3600)) });
    }

    if (tipo === 'publicado') {
      const u = await quien();
      if (!u) return json({ error: 'Tenés que iniciar sesión.' }, 401);
      const { data: p } = await db.from('perfiles').select('rol, activo').eq('id', u.id).maybeSingle();
      if (!p || p.rol !== 'admin' || !p.activo) return json({ error: 'Solo la dirección avisa que salió el horario.' }, 403);
      const { data: msgs, error } = await db.rpc('push_mensajes', { tipo: 'publicado', f: null, sem: body.sem, actualizado: !!body.actualizado });
      if (error) throw error;
      return json({ ok: true, ...(await mandar(db, (await claves(db)).v, (msgs || []) as Msg[], appUrl, 'horario', 24 * 3600)) });
    }

    // auto (cron): qué toca mandar ahora, según los horarios de Ajustes
    const t = ahoraPY();
    const { data: c } = await db.from('config').select('valor').eq('clave', 'general').maybeSingle();
    const cfg = ((c?.valor as Record<string, unknown>)?.push || {}) as Record<string, unknown>;
    const tareas: { tipo: string; f: string; ttl: number }[] = [];
    const noche = aMin(cfg.noche, '20:00'), manana = aMin(cfg.manana, '06:30');
    if (t.min >= noche && t.min < noche + 120) tareas.push({ tipo: 'noche', f: masDias(t.ymd, 1), ttl: 4 * 3600 });
    if (t.min >= manana && t.min < manana + 120) tareas.push({ tipo: 'manana', f: t.ymd, ttl: 4 * 3600 });
    const DISP: Record<number, number> = { 3: 17 * 60, 4: 13 * 60, 5: 13 * 60, 6: 11 * 60 }; // mié 17:00, jue y vie 13:00, sáb 11:00
    if (DISP[t.dow] !== undefined && t.min >= DISP[t.dow] && t.min < DISP[t.dow] + 120) tareas.push({ tipo: 'disp', f: t.ymd, ttl: 6 * 3600 });
    const hechos = [];
    for (const x of tareas) {
      const clave = x.tipo + '|' + x.f;
      const { data: nuevo } = await db.rpc('push_tomar', { k: clave });
      if (!nuevo) continue; // ya se mandó hoy
      const { data: msgs, error } = await db.rpc('push_mensajes', { tipo: x.tipo, f: x.f, sem: null, actualizado: false });
      if (error) { await db.from('push_log').delete().eq('clave', clave); throw error; } // se reintenta en 15 minutos
      hechos.push({ tipo: x.tipo, fecha: x.f, ...(await mandar(db, (await claves(db)).v, (msgs || []) as Msg[], appUrl, x.tipo === 'disp' ? 'disp' : 'clase', x.ttl)) });
    }
    return json({ ok: true, hora: t.hora, hechos });
  } catch (e) {
    return json({ ok: false, error: e instanceof Error ? e.message : String(e) }, 500);
  }
});
