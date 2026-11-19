-- =====================================================================
--  Pedir acceso sin invitación (18/11/2026)
--  Desde la pantalla de entrada, un alumno crea su cuenta solo (sin link ni invitación):
--  pone nombre, apellido, cédula, celular y el grupo en el que está o se quiere inscribir.
--  - Si ya estaba cargado por la oficina (misma cédula, sin cuenta), queda como "coincidencia"
--    y la oficina confirma que es él/ella: se une la cuenta a su ficha (con sus pagos, notas, asistencia).
--  - Si no, completa su ficha en la app y la oficina le asigna el grupo (el que pidió viene elegido).
--  Nunca entra solo a un grupo: el grupo pedido queda aparte (grupo_pedido) hasta que la oficina lo asigna.
--  Se puede volver a correr. También está al final de schema.sql.
-- =====================================================================

alter table public.alumnos add column if not exists grupo_pedido uuid references public.grupos(id) on delete set null;
alter table public.alumnos add column if not exists coincide_id uuid references public.alumnos(id) on delete set null;
alter table public.alumnos add column if not exists pidio_acceso timestamptz;

-- Grupos que se pueden elegir al pedir acceso (solo nombre y curso; se ve sin cuenta)
create or replace function public.grupos_para_inscribir()
returns table (id uuid, nombre text, programa text)
language sql stable security definer set search_path = public as $$
  select g.id, g.nombre, g.programa from grupos g where g.activo is not false order by g.orden nulls last, g.nombre
$$;
grant execute on function public.grupos_para_inscribir() to anon, authenticated;

-- Alta de usuarios: igual que antes + el pedido de acceso sin invitación
create or replace function public.nuevo_usuario() returns trigger
language plpgsql security definer set search_path = public as $$
declare r text := 'alumno'; l links_inscripcion%rowtype; m jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
        ci_n text; gid uuid; prog text; igual uuid;
begin
  if exists (select 1 from config_privada where clave = 'admins' and valor ? lower(new.email)) then
    r := 'admin';
  elsif exists (select 1 from profesores where lower(email) = lower(new.email) and activo) then
    r := 'profe';   -- está en el plantel: entra como profe
  end if;
  insert into perfiles (id, email, nombre, rol)
  values (new.id, lower(new.email), left(btrim(coalesce(m->>'nombre', '') || ' ' || coalesce(m->>'apellido', '')), 120), r)
  on conflict (id) do nothing;
  update alumnos set user_id = new.id where lower(email) = lower(new.email) and user_id is null;
  update profesores set user_id = new.id where lower(email) = lower(new.email) and user_id is null;
  -- se registró con un link de inscripción: se crea su ficha con el curso del link
  if r = 'alumno' and coalesce(m->>'codigo', '') <> '' then
    select * into l from links_inscripcion where codigo = lower(m->>'codigo') and activo;
    if found and not exists (select 1 from alumnos where user_id = new.id or lower(email) = lower(new.email)) then
      insert into alumnos (email, user_id, programa, grupo_id, link_id, estado)
      values (lower(new.email), new.id, l.programa, l.grupo_id, l.id, 'invitado');
    end if;
  -- pidió acceso sin invitación: ficha con sus datos básicos y el grupo que pidió (sin entrar al grupo)
  elsif r = 'alumno' and m->>'pedido' = '1' and not exists (select 1 from alumnos where user_id = new.id or lower(email) = lower(new.email)) then
    begin
      ci_n := nullif(left(regexp_replace(coalesce(m->>'ci', ''), '\D', '', 'g'), 15), '');
      if coalesce(m->>'grupo', '') ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
        select g.id, g.programa into gid, prog from grupos g where g.id = (m->>'grupo')::uuid and g.activo is not false;
      end if;
      if ci_n is not null then
        select a.id into igual from alumnos a
         where a.user_id is null and a.estado <> 'baja' and regexp_replace(coalesce(a.ci, ''), '\D', '', 'g') = ci_n
         order by (a.grupo_id is not null) desc, a.creado desc limit 1;
      end if;
      insert into alumnos (email, user_id, nombre, apellido, ci, tel, programa, grupo_pedido, coincide_id, pidio_acceso, estado)
      values (lower(new.email), new.id, left(btrim(coalesce(m->>'nombre', '')), 80), left(btrim(coalesce(m->>'apellido', '')), 80), ci_n,
              nullif(left(btrim(coalesce(m->>'tel', '')), 30), ''), prog, gid, igual, now(), 'invitado');
    exception when others then
      raise warning 'pedido de acceso: %', sqlerrm;   -- la cuenta se crea igual; la oficina lo ve sin ficha
    end;
  end if;
  return new;
end $$;

-- La oficina confirma que el pedido es de un alumno que ya estaba cargado: une la cuenta a su ficha
create or replace function public.unir_alumno(nuevo uuid, existente uuid) returns void
language plpgsql security definer set search_path = public as $$
declare n alumnos; e alumnos;
begin
  if not public.es_staff() then raise exception 'Solo la oficina o la dirección'; end if;
  perform set_config('vibe.unir', '1', true);
  select * into n from alumnos where id = nuevo for update;
  select * into e from alumnos where id = existente for update;
  if n.id is null or e.id is null then raise exception 'No encontré a uno de los dos alumnos'; end if;
  if n.id = e.id then raise exception 'Es el mismo alumno'; end if;
  if n.user_id is null then raise exception 'El pedido no tiene cuenta'; end if;
  if e.user_id is not null then raise exception 'Ese alumno ya tiene otra cuenta en la app'; end if;
  if exists (select 1 from pagos where alumno_id = n.id) or exists (select 1 from asistencia where alumno_id = n.id)
     or exists (select 1 from notas where alumno_id = n.id) then
    raise exception 'El pedido ya tiene pagos, asistencia o notas: no se puede unir solo';
  end if;
  delete from alumnos where id = n.id;   -- libera la cuenta y el correo
  update alumnos set
    user_id = n.user_id, email = coalesce(email, n.email),
    nombre = coalesce(nullif(nombre, ''), n.nombre), apellido = coalesce(nullif(apellido, ''), n.apellido),
    ci = coalesce(ci, n.ci), tel = coalesce(tel, n.tel), fecha_nac = coalesce(fecha_nac, n.fecha_nac),
    ciudad = coalesce(ciudad, n.ciudad), colegio = coalesce(colegio, n.colegio),
    encargado = coalesce(encargado, n.encargado), encargado_tel = coalesce(encargado_tel, n.encargado_tel),
    programa = coalesce(programa, n.programa), ficha = n.ficha || ficha,   -- lo que ya tenía la oficina manda
    ficha_completa = ficha_completa or n.ficha_completa, ficha_fecha = coalesce(ficha_fecha, n.ficha_fecha),
    pidio_acceso = n.pidio_acceso, coincide_id = null
  where id = e.id;
  update perfiles set nombre = (select btrim(x.nombre || ' ' || x.apellido) from alumnos x where x.id = e.id) where id = n.user_id;
  perform set_config('vibe.unir', '', true);
end $$;
grant execute on function public.unir_alumno(uuid, uuid) to authenticated;
revoke execute on function public.unir_alumno(uuid, uuid) from public, anon;

-- registro de actividad: unir un pedido queda como una sola línea
create or replace function public.actividad_anotar() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  t text := tg_table_name;
  o jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end;
  n jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end;
  r jsonb;
  acc text := case tg_op when 'INSERT' then 'crear' when 'UPDATE' then 'editar' else 'borrar' end;
  ign text[] := array['id', 'creado', 'act', 'por', 'registrado_por', 'nro', 'ficha_fecha', 'aviso_enviado', 'resuelto_por', 'resuelto_en',
                      'hecha_por', 'hecha_en', 'creado_por', 'editado_por', 'editado', 'enviado_en', 'actualizado', 'generado', 'clave',
                      'entrada_marcada', 'salida_marcada', 'corregido_por', 'corregido_en', 'pago_id', 'coincide_id', 'pidio_acceso'];
  lbl jsonb := '{
    "nombre":"Nombre","apellido":"Apellido","ci":"Cédula","fecha_nac":"Fecha de nacimiento","tel":"Teléfono","ciudad":"Ciudad",
    "colegio":"Colegio","encargado":"Encargado","encargado_tel":"Tel. del encargado","programa":"Curso","ficha":"Ficha",
    "ficha_completa":"Ficha completa","grupo_id":"Grupo","estado":"Estado","descuento":"Descuento %","cuota_especial":"Cuota especial",
    "mat_exonerada":"Matrícula exonerada","obs":"Observaciones","email":"Correo","user_id":"Persona","link_id":"Link de inscripción",
    "alumno_id":"Alumno","item":"Ítem","concepto":"Concepto","monto":"Monto","fecha":"Fecha","metodo":"Forma de pago",
    "horario":"Horario","inicio":"Inicio","fin":"Fin","activo":"Activo","plan":"Plan de pagos","dias":"Días","prioridad":"Prioridad",
    "orden":"Orden","descripcion":"Descripción","materia":"Materia","maximo":"Puntaje máximo","codigo":"Código","titulo":"Título",
    "turno":"Turno","motivo":"Motivo","marcado_en":"Marcado","detalle":"Detalle","categoria":"Categoría","urgente":"Urgente",
    "vence":"Fecha límite","para":"Para","hecha":"Hecha","nota_cierre":"Nota","rol":"Rol","profesor_id":"Profe","profe_antes":"Profe antes",
    "monto_turno":"Pago por turno","valor":"Ajustes","enviado":"Enviada","semana_id":"Semana","tema":"Tema","nota":"Nota","marca":"Marca",
    "entrada":"Entrada","salida":"Salida","tipo":"Movimiento","alumnos":"Alumnos","por_alumno":"Por alumno","contado":"Contado","saldo_antes":"Saldo según la app","para_caja":"Para la caja chica","grupo_pedido":"Grupo pedido"}';
  k text; k2 text; vo jsonb; vn jsonb; ch jsonb := '{}'::jsonb; campos text;
  quien text; mirol text; nom text; res text; al uuid; cl text; prev bigint; nomal text; g text; f text;
begin
  if uid is null then return null; end if;   -- cambios de la base o del sistema: no se anotan
  -- al unir un pedido de acceso con el alumno que ya estaba cargado, el pedido se borra: no se anota como "borró al alumno"
  if tg_table_name = 'alumnos' and tg_op = 'DELETE' and current_setting('vibe.unir', true) = '1' then return null; end if;
  select coalesce(nullif(p.nombre, ''), p.email), p.rol into quien, mirol from perfiles p where p.id = uid;
  r := coalesce(n, o);

  -- listas y notas: una fila por lista / examen y persona, se van sumando las marcas de ese rato
  if t in ('asistencia', 'notas') then
    k := case t when 'asistencia' then 'marca' else 'nota' end;
    vo := case when o is not null then o -> k end; vn := case when n is not null then n -> k end;
    if tg_op = 'UPDATE' and vo is not distinct from vn then return null; end if;
    al := (r ->> 'alumno_id')::uuid;
    nomal := coalesce((select nullif(btrim(nombre || ' ' || apellido), '') from alumnos where id = al), al::text);
    cl := case t when 'asistencia' then (r ->> 'grupo_id') || '|' || (r ->> 'fecha') || '|' || coalesce(r ->> 'turno', 'Mañana') else r ->> 'examen_id' end;
    select a.id into prev from actividad a
      where a.tabla = t and a.clave = cl and a.user_id = uid and (a.accion = 'borrar') = (tg_op = 'DELETE')
        and coalesce(a.hasta, a.cuando) > now() - interval '20 minutes'
      order by a.id desc limit 1;
    if prev is null then
      insert into actividad (user_id, quien, rol, tabla, accion, clave, resumen, cambios, hasta)
      values (uid, quien, mirol, t, acc, cl, '…', jsonb_build_object(nomal, jsonb_build_array(vo, vn)), now()) returning id into prev;
    else
      update actividad a set hasta = now(),
        cambios = case when a.cambios ? nomal then jsonb_set(a.cambios, array[nomal], jsonb_build_array(a.cambios -> nomal -> 0, vn))
                       else a.cambios || jsonb_build_object(nomal, jsonb_build_array(vo, vn)) end
      where a.id = prev;
    end if;
    if t = 'asistencia' then
      g := (select nombre from grupos where id = (r ->> 'grupo_id')::uuid);
      update actividad a set resumen =
        (case a.accion when 'crear' then 'Llamó lista de ' when 'editar' then 'Corrigió la lista de ' else 'Borró la lista de ' end)
        || coalesce(g, 'un grupo') || ' · ' || to_char((r ->> 'fecha')::date, 'DD/MM') || ' ' || lower(coalesce(r ->> 'turno', 'Mañana')) || ': '
        || (select count(*) from jsonb_object_keys(a.cambios)) || ' alumno' || case when (select count(*) from jsonb_object_keys(a.cambios)) = 1 then '' else 's' end
        || coalesce(' (' || (select string_agg(c || ' ' || m, ' · ' order by array_position(array['P','T','A','J'], m))
                             from (select v -> 1 ->> 0 as m, count(*) as c from jsonb_each(a.cambios) e(kk, v) where v -> 1 ->> 0 is not null group by 1) s) || ')', '')
      where a.id = prev;
    else
      select e.nombre, gg.nombre into nom, g from examenes e left join grupos gg on gg.id = e.grupo_id where e.id = (r ->> 'examen_id')::uuid;
      update actividad a set resumen =
        (case a.accion when 'crear' then 'Cargó notas de ' when 'editar' then 'Corrigió notas de ' else 'Borró notas de ' end)
        || coalesce(nom, 'un examen') || coalesce(' (' || g || ')', '') || ': '
        || (select count(*) from jsonb_object_keys(a.cambios)) || ' alumno' || case when (select count(*) from jsonb_object_keys(a.cambios)) = 1 then '' else 's' end
      where a.id = prev;
    end if;
    return null;
  end if;

  -- la marca del turno de oficina sale de la entrada/salida, que ya queda anotada en "marcaciones": no se repite
  if t = 'oficina_turnos' and tg_op = 'UPDATE' and (o - 'marcado_en') = (n - 'marcado_en') then return null; end if;

  -- qué cambió
  if tg_op = 'UPDATE' then
    for k in select jsonb_object_keys(n) loop
      continue when k = any(ign);
      vo := o -> k; vn := n -> k;
      continue when vo is not distinct from vn;
      if jsonb_typeof(vo) = 'object' and jsonb_typeof(vn) = 'object' then
        for k2 in select x from (select jsonb_object_keys(vo) x union select jsonb_object_keys(vn)) s loop
          if (vo -> k2) is distinct from (vn -> k2) then ch := ch || jsonb_build_object(k || '.' || k2, jsonb_build_array(vo -> k2, vn -> k2)); end if;
        end loop;
      else
        ch := ch || jsonb_build_object(k, jsonb_build_array(public.act_valor(k, vo), public.act_valor(k, vn)));
      end if;
    end loop;
    if ch = '{}'::jsonb then return null; end if;
  else
    for k in select jsonb_object_keys(r) loop
      continue when k = any(ign) or jsonb_typeof(r -> k) in ('null', 'object', 'array') or r ->> k = '';
      continue when jsonb_typeof(r -> k) = 'boolean' and r ->> k = 'false';
      continue when t = 'alumnos' and k = 'descuento' and r ->> k = '0';
      ch := ch || jsonb_build_object(k, case when tg_op = 'INSERT' then jsonb_build_array(null, public.act_valor(k, r -> k))
                                             else jsonb_build_array(public.act_valor(k, r -> k), null) end);
    end loop;
  end if;
  select string_agg(coalesce(lbl ->> split_part(x, '.', 1), split_part(x, '.', 1))
                    || case when position('.' in x) > 0 and split_part(x, '.', 1) <> 'valor' then ' ' || split_part(x, '.', 2)
                            when split_part(x, '.', 1) = 'valor' then '' else '' end, ', ')
    into campos from (select distinct case when split_part(x0, '.', 1) = 'valor' then split_part(x0, '.', 2) else x0 end as x
                      from jsonb_object_keys(ch) x0) s;

  -- de quién / de qué se trata
  nom := case t
    when 'alumnos' then coalesce(nullif(btrim(coalesce(r ->> 'nombre', '') || ' ' || coalesce(r ->> 'apellido', '')), ''), r ->> 'email')
    when 'pagos' then (select nullif(btrim(nombre || ' ' || apellido), '') from alumnos where id = (r ->> 'alumno_id')::uuid)
    when 'grupos' then r ->> 'nombre'
    when 'examenes' then r ->> 'nombre'
    when 'links_inscripcion' then r ->> 'titulo'
    when 'tareas' then r ->> 'titulo'
    when 'caja_movs' then r ->> 'concepto'
    when 'perfiles' then coalesce(nullif(r ->> 'nombre', ''), r ->> 'email')
    when 'profesores' then r ->> 'nombre'
    when 'disponibilidad' then (select nombre from profesores where id = (r ->> 'profesor_id')::uuid)
    when 'cambios' then (select nombre from profesores where id = (r ->> 'profesor_id')::uuid)
    else (select coalesce(nullif(nombre, ''), email) from perfiles where id = nullif(r ->> 'user_id', '')::uuid) end;
  nom := coalesce(nom, '—');
  al := case t when 'alumnos' then (r ->> 'id')::uuid when 'pagos' then (r ->> 'alumno_id')::uuid end;
  f := case when r ? 'fecha' then to_char((r ->> 'fecha')::date, 'DD/MM') end;
  g := case when r ? 'grupo_id' then (select nombre from grupos where id = nullif(r ->> 'grupo_id', '')::uuid) end;

  res := case t
    when 'alumnos' then case
      when acc = 'crear' then 'Alumno nuevo: ' || nom
      when acc = 'borrar' then 'Borró al alumno ' || nom
      when ch ? 'user_id' and o ->> 'user_id' is null and current_setting('vibe.unir', true) = '1' then
        'Unió la cuenta de ' || coalesce(n ->> 'email', 'la app') || ' a ' || nom || ' (ya estaba cargado)'
      when ch ? 'estado' and n ->> 'estado' = 'baja' then 'Dio de baja a ' || nom
      when ch ? 'estado' and o ->> 'estado' = 'baja' then 'Volvió a activar a ' || nom
      when ch ? 'grupo_id' and o ->> 'grupo_id' is null then 'Asignó a ' || nom || ' al grupo ' || coalesce(g, '—')
      when ch ? 'grupo_id' then 'Cambió de grupo a ' || nom || ': ' || coalesce(ch -> 'grupo_id' ->> 0, '—') || ' → ' || coalesce(g, '—')
      else 'Editó a ' || nom || ' (' || campos || ')' end
    when 'pagos' then case acc
      when 'crear' then 'Cobró ' || act_gs((r ->> 'monto')::numeric) || ' a ' || nom || ' · ' || coalesce(r ->> 'concepto', '') || ' · ' || coalesce(r ->> 'metodo', '') || ' (recibo N° ' || coalesce(r ->> 'nro', '') || ')'
        || case when coalesce((r ->> 'para_caja')::numeric, 0) > 0 then ' · ' || act_gs((r ->> 'para_caja')::numeric) || ' para la caja chica' else '' end
      when 'borrar' then 'Anuló el pago de ' || nom || ': ' || act_gs((r ->> 'monto')::numeric) || ' · ' || coalesce(r ->> 'concepto', '') || ' (recibo N° ' || coalesce(r ->> 'nro', '') || ')'
      else 'Editó el pago de ' || nom || ' (recibo N° ' || coalesce(r ->> 'nro', '') || '): ' || campos end
    when 'examenes' then case acc when 'crear' then 'Creó el examen ' || nom || coalesce(' (' || g || ')', '')
      when 'borrar' then 'Borró el examen ' || nom || coalesce(' (' || g || ')', '') else 'Editó el examen ' || nom || ': ' || campos end
    when 'grupos' then case acc when 'crear' then 'Creó el grupo ' || nom when 'borrar' then 'Borró el grupo ' || nom else 'Editó el grupo ' || nom || ': ' || campos end
    when 'links_inscripcion' then case acc when 'crear' then 'Creó el link de inscripción ' || nom when 'borrar' then 'Borró el link de inscripción ' || nom
      else 'Editó el link de inscripción ' || nom || ': ' || campos end
    when 'oficina_turnos' then case
      when acc = 'crear' and r ->> 'estado' = 'pendiente' and (r ->> 'user_id')::uuid = uid then 'Pidió el turno ' || lower(r ->> 'turno') || ' del ' || f
      when acc = 'crear' then 'Asignó a ' || nom || ' el turno ' || lower(r ->> 'turno') || ' del ' || f
      when acc = 'borrar' then 'Quitó a ' || nom || ' del turno ' || lower(r ->> 'turno') || ' del ' || f
      when ch ? 'marcado_en' and n ->> 'marcado_en' is not null and (r ->> 'user_id')::uuid = uid then 'Marcó su turno ' || lower(r ->> 'turno') || ' del ' || f
      when ch ? 'marcado_en' and n ->> 'marcado_en' is not null then 'Marcó el turno ' || lower(r ->> 'turno') || ' de ' || nom || ' (' || f || ')'
      when ch ? 'estado' and n ->> 'estado' = 'asignado' then 'Aprobó el turno ' || lower(r ->> 'turno') || ' de ' || nom || ' (' || f || ')'
      when ch ? 'estado' and n ->> 'estado' = 'rechazado' then 'Rechazó el turno ' || lower(r ->> 'turno') || ' de ' || nom || ' (' || f || ')'
      else 'Editó el turno de ' || nom || ' (' || f || '): ' || campos end
    when 'tareas' then case
      when acc = 'crear' then 'Anotó la tarea: ' || nom
      when acc = 'borrar' then 'Borró la tarea: ' || nom
      when ch ? 'hecha' and (n ->> 'hecha')::boolean then 'Hizo la tarea: ' || nom
      when ch ? 'hecha' then 'Volvió a abrir la tarea: ' || nom
      else 'Editó la tarea ' || nom || ' (' || campos || ')' end
    when 'cambios' then case
      when acc = 'crear' then 'Pidió cambio de clase: ' || coalesce(g, '') || ' · ' || coalesce(f, '') || ' ' || lower(coalesce(r ->> 'turno', ''))
      when acc = 'borrar' then 'Borró el pedido de cambio de ' || nom
      when ch ? 'estado' and n ->> 'estado' = 'aprobado' then 'Aprobó el cambio de ' || nom || ': ' || coalesce(g, '') || ' · ' || coalesce(f, '')
      when ch ? 'estado' and n ->> 'estado' = 'rechazado' then 'Rechazó el cambio de ' || nom || ': ' || coalesce(g, '') || ' · ' || coalesce(f, '')
      else 'Editó el pedido de cambio de ' || nom || ': ' || campos end
    when 'perfiles' then case
      when acc = 'crear' then 'Creó la cuenta de ' || nom
      when acc = 'borrar' then 'Borró la cuenta de ' || nom
      when ch ? 'rol' then 'Cambió el rol de ' || nom || ': ' || coalesce(o ->> 'rol', '') || ' → ' || coalesce(n ->> 'rol', '')
      when ch ? 'activo' and not (n ->> 'activo')::boolean then 'Quitó el acceso a ' || nom
      when ch ? 'activo' then 'Devolvió el acceso a ' || nom
      else 'Editó la cuenta de ' || nom || ': ' || campos end
    when 'profesores' then case acc when 'crear' then 'Sumó al profe ' || nom || ' al plantel' when 'borrar' then 'Borró al profe ' || nom || ' del plantel'
      else 'Editó al profe ' || nom || ': ' || campos end
    when 'disponibilidad' then case
      when (select user_id from profesores where id = (r ->> 'profesor_id')::uuid) = uid then 'Cargó su disponibilidad (' || coalesce(act_valor('semana_id', r -> 'semana_id') #>> '{}', '') || ')'
      else 'Corrigió la disponibilidad de ' || nom || ' (' || coalesce(act_valor('semana_id', r -> 'semana_id') #>> '{}', '') || ')' end
    when 'oficina_disp' then case
      when (r ->> 'user_id')::uuid = uid then 'Cargó su disponibilidad de oficina (' || coalesce(act_valor('semana_id', r -> 'semana_id') #>> '{}', '') || ')'
      else 'Corrigió la disponibilidad de oficina de ' || nom || ' (' || coalesce(act_valor('semana_id', r -> 'semana_id') #>> '{}', '') || ')' end
    when 'marcaciones' then case
      when acc = 'borrar' then 'Borró las horas de ' || nom || ' del ' || f || ' (' || lower(r ->> 'turno') || ')'
      when (n ->> 'corregido_en') is not null and (n ->> 'corregido_en') is distinct from (o ->> 'corregido_en') then
        (case when acc = 'crear' then 'Cargó ' else 'Corrigió ' end)
        || case when (r ->> 'user_id')::uuid = uid then 'sus horas' else 'las horas de ' || nom end
        || ' del ' || f || ' (' || lower(r ->> 'turno') || '): '
        || coalesce(nullif(concat_ws(', ', public.act_hora_cambio(o, n, 'entrada'), public.act_hora_cambio(o, n, 'salida')), ''), 'sin cambios de hora')
        || coalesce(' · “' || nullif(n ->> 'motivo', '') || '”', '')
      when (n ->> 'salida_marcada') is not null and (o ->> 'salida_marcada') is null then
        'Marcó su salida: ' || public.hora_py((n ->> 'salida')::timestamptz) || ' (' || lower(r ->> 'turno') || ')'
      when (n ->> 'entrada_marcada') is not null and (o ->> 'entrada_marcada') is null then
        'Marcó su entrada: ' || public.hora_py((n ->> 'entrada')::timestamptz) || ' (' || lower(r ->> 'turno') || ')'
      else 'Editó las horas de ' || nom || ' (' || f || '): ' || coalesce(campos, '') end
    when 'caja_movs' then case
      when acc = 'crear' and r ->> 'pago_id' is not null then 'Apartó ' || act_gs((r ->> 'monto')::numeric) || ' para la caja chica: ' || nom
      when acc = 'crear' and r ->> 'tipo' = 'ingreso' and r ->> 'categoria' = 'cuotas' then
        'Apartó ' || act_gs((r ->> 'monto')::numeric) || ' de las cuotas para la caja chica'
        || coalesce(' (' || (r ->> 'alumnos') || ' alumno' || case when r ->> 'alumnos' = '1' then '' else 's' end || ' × ' || act_gs((r ->> 'por_alumno')::numeric) || ')', '')
      when acc = 'crear' and r ->> 'tipo' = 'ingreso' then 'Entró a la caja chica ' || act_gs((r ->> 'monto')::numeric) || ': ' || nom
      when acc = 'crear' and r ->> 'tipo' = 'gasto' then 'Pagó ' || act_gs((r ->> 'monto')::numeric) || ' de la caja chica: ' || nom
      when acc = 'crear' then 'Contó la caja chica: había ' || act_gs((r ->> 'contado')::numeric)
        || case when (r ->> 'monto')::bigint = 0 then ' (coincide con la app)' when (r ->> 'monto')::bigint < 0 then ' (faltaban ' || act_gs(-(r ->> 'monto')::numeric) || ')'
                else ' (sobraban ' || act_gs((r ->> 'monto')::numeric) || ')' end
      when acc = 'borrar' and r ->> 'tipo' = 'arqueo' then 'Borró de la caja chica el arqueo del ' || f
      when acc = 'borrar' then 'Borró de la caja chica: ' || act_gs((r ->> 'monto')::numeric) || ' · ' || nom || ' (' || f || ')'
      else 'Editó un movimiento de la caja chica (' || nom || '): ' || coalesce(campos, '') end
    when 'oficina_montos' then 'Cambió el pago por turno de ' || nom
    when 'config' then 'Cambió los ajustes: ' || coalesce(campos, '')
    else initcap(acc) || ' en ' || t end;

  insert into actividad (user_id, quien, rol, tabla, accion, clave, alumno_id, resumen, cambios)
  values (uid, quien, mirol, t, acc, coalesce(r ->> 'id', r ->> 'clave', r ->> 'user_id'), al, coalesce(res, initcap(acc) || ' en ' || t), ch);
  return null;
exception when others then
  -- el registro nunca debe trabar el trabajo de nadie
  raise warning 'actividad_anotar(%): %', t, sqlerrm;
  return null;
end $$;

