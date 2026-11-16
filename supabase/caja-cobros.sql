-- =====================================================================
--  Caja chica desde el cobro (16/11/2026)
--  Al registrar un pago se puede poner cuánto se aparta para la caja de la oficina:
--  queda en el pago (para_caja) y la base anota la entrada en la caja chica en el mismo momento.
--  Si se anula el pago, esa entrada se borra sola. Se puede volver a correr. También está al final de schema.sql.
-- =====================================================================

alter table public.pagos add column if not exists para_caja bigint;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'pagos_para_caja_chk') then
    alter table public.pagos add constraint pagos_para_caja_chk check (para_caja is null or (para_caja > 0 and para_caja <= monto));
  end if;
end $$;
alter table public.caja_movs add column if not exists pago_id uuid references public.pagos(id) on delete cascade;
create unique index if not exists caja_movs_pago_idx on public.caja_movs(pago_id) where pago_id is not null;

-- el pago anota (o actualiza / saca) su parte en la caja chica
create or replace function public.pago_a_caja() returns trigger
language plpgsql security definer set search_path = public as $$
declare nom text;
begin
  if coalesce(new.para_caja, 0) > 0 then
    select nullif(btrim(coalesce(nombre, '') || ' ' || coalesce(apellido, '')), '') into nom from alumnos where id = new.alumno_id;
    insert into caja_movs (tipo, categoria, concepto, monto, fecha, alumnos, por_alumno, pago_id)
    values ('ingreso', 'cuotas', left('Cobro a ' || coalesce(nom, 'un alumno') || ' · ' || new.concepto || ' (recibo N° ' || new.nro || ')', 200),
            new.para_caja, least(new.fecha, public.hoy_py()), 1, new.para_caja, new.id)
    on conflict (pago_id) where pago_id is not null
      do update set monto = excluded.monto, fecha = excluded.fecha, por_alumno = excluded.por_alumno;
  elsif tg_op = 'UPDATE' then
    delete from caja_movs where pago_id = new.id;
  end if;
  return null;
end $$;
drop trigger if exists pagos_a_caja on public.pagos;
create trigger pagos_a_caja after insert or update of para_caja, fecha on public.pagos for each row execute function public.pago_a_caja();

-- lo que viene de un cobro no se edita desde la caja (se cambia con el pago)
create or replace function public.caja_de_cobro() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and old.pago_id is not null and pg_trigger_depth() < 2 then
    raise exception 'Esto viene de un cobro (recibo): se corrige anulando el pago.';
  end if;
  return new;
end $$;
drop trigger if exists caja_de_cobro on public.caja_movs;
create trigger caja_de_cobro before update on public.caja_movs for each row execute function public.caja_de_cobro();
revoke execute on function public.pago_a_caja(), public.caja_de_cobro() from public, anon, authenticated;

-- registro de actividad: el cobro dice cuánto fue a la caja
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
                      'entrada_marcada', 'salida_marcada', 'corregido_por', 'corregido_en', 'pago_id'];
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
    "entrada":"Entrada","salida":"Salida","tipo":"Movimiento","alumnos":"Alumnos","por_alumno":"Por alumno","contado":"Contado","saldo_antes":"Saldo según la app","para_caja":"Para la caja chica"}';
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

