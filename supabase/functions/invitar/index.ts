// VIBE App · función "invitar"
// La oficina o la dirección invitan por correo a un alumno, un profe o alguien de oficina.
// Le llega un mail para crear su contraseña y entrar a la app.
// Secretos necesarios: APP_URL (dirección de la app). SUPABASE_URL, SUPABASE_ANON_KEY y
// SUPABASE_SERVICE_ROLE_KEY ya vienen cargados por Supabase.
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  try {
    const url = Deno.env.get('SUPABASE_URL')!;
    const anon = Deno.env.get('SUPABASE_ANON_KEY')!;
    const service = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const appUrl = Deno.env.get('APP_URL') ?? '';

    // ¿Quién está pidiendo la invitación?
    const caller = createClient(url, anon, { global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } } });
    const { data: { user } } = await caller.auth.getUser();
    if (!user) return json({ error: 'Tenés que iniciar sesión.' }, 401);

    const admin = createClient(url, service, { auth: { persistSession: false } });
    const { data: yo } = await admin.from('perfiles').select('rol, activo').eq('id', user.id).single();
    if (!yo?.activo || !['admin', 'oficina'].includes(yo.rol)) return json({ error: 'Solo la dirección o la oficina pueden invitar.' }, 403);

    const body = await req.json();
    const email = String(body.email ?? '').trim().toLowerCase();
    const tipo = String(body.tipo ?? 'alumno');          // alumno | profe | oficina
    const nombre = String(body.nombre ?? '').trim();
    const apellido = String(body.apellido ?? '').trim();
    const grupoId = body.grupo_id || null;
    const programa = String(body.programa ?? '').trim() || null;
    const soloReenviar = body.reenviar === true;   // reenviar el acceso sin tocar roles ni fichas
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return json({ error: 'El correo no es válido.' }, 400);
    if (!['alumno', 'profe', 'oficina'].includes(tipo)) return json({ error: 'Tipo de usuario no válido.' }, 400);
    if (tipo !== 'alumno' && yo.rol !== 'admin' && !soloReenviar) return json({ error: 'Solo la dirección puede sumar profes u oficina.' }, 403);

    // Alumno: la ficha se crea antes, así queda vinculada cuando se cree el usuario.
    if (tipo === 'alumno' && !soloReenviar) {
      const { data: existe } = await admin.from('alumnos').select('id').eq('email', email).maybeSingle();
      if (!existe) {
        const { error } = await admin.from('alumnos').insert({ email, nombre, apellido, grupo_id: grupoId, programa, estado: 'invitado' });
        if (error) return json({ error: 'No se pudo crear la ficha: ' + error.message }, 400);
      }
    }

    const { data: inv, error: invErr } = await admin.auth.admin.inviteUserByEmail(email, {
      redirectTo: appUrl || undefined,
      data: { nombre: [nombre, apellido].filter(Boolean).join(' ') },
    });

    let uid = inv?.user?.id ?? null;
    let yaTeniaCuenta = false;
    if (invErr) {
      // Ya tenía cuenta: le mandamos un correo para entrar / cambiar la contraseña.
      const { data: lista } = await admin.from('perfiles').select('id').eq('email', email).maybeSingle();
      if (!lista) return json({ error: 'No se pudo enviar la invitación: ' + invErr.message }, 400);
      uid = lista.id;
      yaTeniaCuenta = true;
      await admin.auth.resetPasswordForEmail(email, { redirectTo: appUrl || undefined });
    }

    if (uid && tipo !== 'alumno' && !soloReenviar) {
      await admin.from('perfiles').update({ rol: tipo, activo: true, ...(nombre ? { nombre: [nombre, apellido].filter(Boolean).join(' ') } : {}) }).eq('id', uid);
      const grupos: string[] = Array.isArray(body.grupos) ? body.grupos : [];
      if (tipo === 'profe' && grupos.length) {
        await admin.from('profe_grupos').upsert(grupos.map((g) => ({ profe_id: uid, grupo_id: g })), { onConflict: 'profe_id,grupo_id' });
      }
    }
    if (uid && tipo === 'alumno') {
      await admin.from('alumnos').update({ user_id: uid }).eq('email', email).is('user_id', null);
    }
    return json({ ok: true, ya_tenia_cuenta: yaTeniaCuenta });
  } catch (e) {
    return json({ error: 'Error inesperado: ' + (e instanceof Error ? e.message : String(e)) }, 500);
  }
});
