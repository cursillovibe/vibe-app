-- =====================================================================
--  Tareas de la oficina / librería y registro de actividad (15/11/2026)
--  Se puede volver a correr. También está al final de schema.sql.
-- =====================================================================

-- ---------- tareas ----------------------------------------------------
-- Lo que hay que hacer en la oficina y la librería (imprimir, fotocopias, compras, recordarle algo a Guido…).
-- Las anotan la dirección o la oficina; cualquiera de la oficina las marca como hechas; solo la dirección borra.
create table if not exists public.tareas (
  id           uuid primary key default gen_random_uuid(),
  titulo       text not null check (length(btrim(titulo)) between 1 and 200),
  detalle      text check (detalle is null or length(detalle) <= 2000),
  categoria    text not null default 'oficina' check (categoria in ('oficina','libreria','compras','recordar')),
  urgente      boolean not null default false,
  vence        date,
  para         uuid references auth.users(id) on delete set null,   -- null = cualquiera de la oficina
  hecha        boolean not null default false,
  hecha_por    uuid references auth.users(id) on delete set null,
  hecha_en     timestamptz,
  nota_cierre  text check (nota_cierre is null or length(nota_cierre) <= 1000),
  creado_por   uuid references auth.users(id) on delete set null,
  creado       timestamptz not null default now(),
  editado_por  uuid references auth.users(id) on delete set null,
  editado      timestamptz
);
create index if not exists tareas_estado_idx on public.tareas(hecha, hecha_en);

-- quién la anotó, quién la hizo y cuándo lo pone la base (no se puede falsear desde la app)
create or replace function public.tareas_sellar() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  -- cambios del sistema (sin usuario): se aceptan tal cual. Así, si se borra una cuenta, la base puede dejar en blanco quién anotó o hizo la tarea.
  if auth.uid() is null then return new; end if;
  if tg_op = 'INSERT' then
    new.creado_por := auth.uid(); new.creado := now(); new.editado_por := null; new.editado := null;
    if new.hecha then new.hecha_por := auth.uid(); new.hecha_en := now(); else new.hecha_por := null; new.hecha_en := null; new.nota_cierre := null; end if;
  else
    new.creado_por := old.creado_por; new.creado := old.creado;
    if new.hecha and not old.hecha then new.hecha_por := auth.uid(); new.hecha_en := now();
    elsif not new.hecha then new.hecha_por := null; new.hecha_en := null; new.nota_cierre := null;
    else new.hecha_por := old.hecha_por; new.hecha_en := old.hecha_en; end if;
    if (new.titulo, new.detalle, new.categoria, new.urgente, new.vence, new.para)
       is distinct from (old.titulo, old.detalle, old.categoria, old.urgente, old.vence, old.para) then
      new.editado_por := auth.uid(); new.editado := now();
    else new.editado_por := old.editado_por; new.editado := old.editado; end if;
  end if;
  return new;
end $$;
drop trigger if exists tareas_sellar on public.tareas;
create trigger tareas_sellar before insert or update on public.tareas for each row execute function public.tareas_sellar();

alter table public.tareas enable row level security;
drop policy if exists tareas_ver on public.tareas;
create policy tareas_ver on public.tareas for select to authenticated using (public.es_staff());
drop policy if exists tareas_crear on public.tareas;
create policy tareas_crear on public.tareas for insert to authenticated with check (public.es_staff());
drop policy if exists tareas_editar on public.tareas;
create policy tareas_editar on public.tareas for update to authenticated using (public.es_staff()) with check (public.es_staff());
drop policy if exists tareas_borrar on public.tareas;
create policy tareas_borrar on public.tareas for delete to authenticated using (public.es_admin());
grant select, insert, update, delete on public.tareas to authenticated;
revoke all on public.tareas from anon;

-- ---------- registro de actividad --------------------------------------
-- Cada cambio que hace alguien con su cuenta queda anotado: quién, cuándo, qué y qué cambió (antes → después).
-- Solo lo ve la dirección. Nadie lo puede editar ni borrar desde la app (ni la dirección).
-- Las listas y las notas se agrupan: una fila por lista / examen y persona (marcas de un mismo rato).
create table if not exists public.actividad (
  id         bigint generated always as identity primary key,
  cuando     timestamptz not null default now(),
  hasta      timestamptz,
  user_id    uuid,
  quien      text,
  rol        text,
  tabla      text not null,
  accion     text not null check (accion in ('crear','editar','borrar')),
  clave      text,
  alumno_id  uuid,
  resumen    text not null,
  cambios    jsonb not null default '{}'::jsonb
);
create index if not exists actividad_cuando_idx on public.actividad(cuando desc);
create index if not exists actividad_user_idx on public.actividad(user_id, cuando desc);
create index if not exists actividad_alumno_idx on public.actividad(alumno_id, cuando desc);
create index if not exists actividad_grupo_idx on public.actividad(tabla, clave, user_id, id desc);

alter table public.actividad enable row level security;
drop policy if exists actividad_ver on public.actividad;
create policy actividad_ver on public.actividad for select to authenticated using (public.es_admin());
revoke all on public.actividad from anon, authenticated;
grant select on public.actividad to authenticated;

-- nombre legible de un valor (ids → nombres)
create or replace function public.act_valor(col text, v jsonb) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s text := v #>> '{}'; x text;
begin
  if v is null or jsonb_typeof(v) = 'null' then return null; end if;
  if s !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then return v; end if;
  x := case col
    when 'grupo_id' then (select nombre from grupos where id = s::uuid)
    when 'alumno_id' then (select btrim(nombre || ' ' || apellido) from alumnos where id = s::uuid)
    when 'user_id' then (select coalesce(nullif(nombre, ''), email) from perfiles where id = s::uuid)
    when 'para' then (select coalesce(nullif(nombre, ''), email) from perfiles where id = s::uuid)
    when 'profe_id' then (select coalesce(nullif(nombre, ''), email) from perfiles where id = s::uuid)
    when 'profesor_id' then (select nombre from profesores where id = s::uuid)
    when 'profe_antes' then (select nombre from profesores where id = s::uuid)
    when 'link_id' then (select titulo from links_inscripcion where id = s::uuid)
    when 'examen_id' then (select nombre from examenes where id = s::uuid)
    when 'semana_id' then (select 'semana del ' || to_char(lunes, 'DD/MM') from semanas where id = s::uuid)
    else null end;
  return to_jsonb(coalesce(x, s));
end $$;

create or replace function public.act_gs(m numeric) returns text
language sql immutable as $$ select 'Gs. ' || replace(to_char(coalesce(m, 0), 'FM999,999,999,999'), ',', '.') $$;

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
                      'hecha_por', 'hecha_en', 'creado_por', 'editado_por', 'editado', 'enviado_en', 'actualizado', 'generado', 'clave'];
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
    "monto_turno":"Pago por turno","valor":"Ajustes","enviado":"Enviada","semana_id":"Semana","tema":"Tema","nota":"Nota","marca":"Marca"}';
  k text; k2 text; vo jsonb; vn jsonb; ch jsonb := '{}'::jsonb; campos text;
  quien text; mirol text; nom text; res text; al uuid; cl text; prev bigint; nomal text; g text; f text;
begin
  if uid is null then return null; end if;   -- cambios de la base o del sistema: no se anotan
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
      when ch ? 'estado' and n ->> 'estado' = 'baja' then 'Dio de baja a ' || nom
      when ch ? 'estado' and o ->> 'estado' = 'baja' then 'Volvió a activar a ' || nom
      when ch ? 'grupo_id' and o ->> 'grupo_id' is null then 'Asignó a ' || nom || ' al grupo ' || coalesce(g, '—')
      when ch ? 'grupo_id' then 'Cambió de grupo a ' || nom || ': ' || coalesce(ch -> 'grupo_id' ->> 0, '—') || ' → ' || coalesce(g, '—')
      else 'Editó a ' || nom || ' (' || campos || ')' end
    when 'pagos' then case acc
      when 'crear' then 'Cobró ' || act_gs((r ->> 'monto')::numeric) || ' a ' || nom || ' · ' || coalesce(r ->> 'concepto', '') || ' · ' || coalesce(r ->> 'metodo', '') || ' (recibo N° ' || coalesce(r ->> 'nro', '') || ')'
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

do $$
declare t text;
begin
  foreach t in array array['alumnos', 'pagos', 'asistencia', 'notas', 'examenes', 'grupos', 'links_inscripcion', 'oficina_turnos',
                           'tareas', 'cambios', 'perfiles', 'profesores', 'disponibilidad', 'oficina_disp', 'oficina_montos', 'config'] loop
    execute format('drop trigger if exists zz_actividad on public.%I', t);
    execute format('create trigger zz_actividad after insert or update or delete on public.%I for each row execute function public.actividad_anotar()', t);
  end loop;
end $$;

revoke execute on function public.actividad_anotar(), public.tareas_sellar(), public.act_valor(text, jsonb) from public, anon, authenticated;

-- en vivo: las tres de la oficina ven las tareas al instante; la dirección, la actividad
do $$
declare t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['tareas', 'actividad'] loop
      if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
        execute format('alter publication supabase_realtime add table public.%I', t);
      end if;
    end loop;
  end if;
end $$;
