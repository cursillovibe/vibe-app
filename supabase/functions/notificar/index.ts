// VIBE App · función "notificar"
// Cuando un alumno completa su ficha por primera vez, manda un correo a la oficina
// para que lo asignen a su grupo.
// Secretos: SMTP_USER (informacion@vibe.com.py), SMTP_PASS (contraseña de aplicación de Google),
// NOTIF_TO (a quién avisar; por defecto SMTP_USER) y APP_URL.
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';
import nodemailer from 'npm:nodemailer@6.9.14';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
const esc = (s: unknown) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!));

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  try {
    const url = Deno.env.get('SUPABASE_URL')!;
    const caller = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } } });
    const { data: { user } } = await caller.auth.getUser();
    if (!user) return json({ error: 'Tenés que iniciar sesión.' }, 401);

    const admin = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
    const { data: a } = await admin.from('alumnos').select('*').eq('user_id', user.id).single();
    if (!a || !a.ficha_completa || a.aviso_enviado) return json({ ok: true, omitido: true });

    const smtpUser = Deno.env.get('SMTP_USER');
    const smtpPass = Deno.env.get('SMTP_PASS');
    if (!smtpUser || !smtpPass) return json({ ok: false, error: 'Falta configurar el correo (SMTP_USER / SMTP_PASS).' }, 500);
    const para = Deno.env.get('NOTIF_TO') || smtpUser;
    const appUrl = Deno.env.get('APP_URL') ?? '';

    const nombre = [a.nombre, a.apellido].filter(Boolean).join(' ');
    const ETIQ: Record<string, string> = { nacionalidad: 'Nacionalidad', direccion: 'Dirección', vive_con: 'Vive con', trabaja: 'Trabaja', carrera: 'Carrera',
      bachiller: 'Bachillerato que quiere', colegio_destino: 'Colegio al que quiere entrar', padre_nombre: 'Padre', padre_tel: 'Cel. del padre',
      madre_nombre: 'Madre', madre_tel: 'Cel. de la madre', factura: 'Factura (RUC / razón social)', como_conocio: 'Cómo se enteró', recomendado_por: 'Recomendado por' };
    const filas: [string, unknown][] = [
      ['Curso', a.programa], ['Nombre', nombre], ['Cédula', a.ci], ['Correo', a.email], ['Celular', a.tel], ['Colegio', a.colegio], ['Ciudad', a.ciudad],
      ['Encargado', a.encargado], ['Cel. encargado', a.encargado_tel],
      ...Object.entries(a.ficha ?? {}).map(([k, v]) => [ETIQ[k] ?? k.replace(/_/g, ' '), v] as [string, unknown]),
    ];
    const html = `<div style="font-family:Arial,sans-serif;max-width:560px">
      <div style="border-bottom:4px solid #FB8500;padding-bottom:10px;margin-bottom:16px"><b style="font-size:22px">VIBE</b></div>
      <p><b>${esc(nombre)}</b> completó su ficha de inscripción. Falta asignarle su grupo.</p>
      <table style="border-collapse:collapse;width:100%">${filas.filter(([, v]) => v !== null && v !== '' && v !== undefined)
        .map(([k, v]) => `<tr><td style="padding:6px 10px;color:#68625A;border-bottom:1px solid #eee;text-transform:capitalize">${esc(k)}</td><td style="padding:6px 10px;border-bottom:1px solid #eee">${esc(v)}</td></tr>`).join('')}</table>
      ${appUrl ? `<p style="margin-top:20px"><a href="${esc(appUrl)}" style="background:#FB8500;color:#17140F;padding:10px 16px;border-radius:8px;text-decoration:none;font-weight:bold">Abrir la app y asignar grupo</a></p>` : ''}
    </div>`;

    const transport = nodemailer.createTransport({ host: 'smtp.gmail.com', port: 465, secure: true, auth: { user: smtpUser, pass: smtpPass } });
    await transport.sendMail({ from: `"App VIBE" <${smtpUser}>`, to: para, subject: `Nueva inscripción: ${nombre}`, html });
    await admin.from('alumnos').update({ aviso_enviado: true }).eq('id', a.id);
    return json({ ok: true });
  } catch (e) {
    return json({ ok: false, error: e instanceof Error ? e.message : String(e) }, 500);
  }
});
