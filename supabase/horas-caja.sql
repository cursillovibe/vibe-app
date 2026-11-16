-- =====================================================================
--  Entrada y salida (oficina y profes) + caja chica de la oficina (16/11/2026)
--  Se puede volver a correr. También está al final de schema.sql.
-- =====================================================================

-- hora de Paraguay (UTC-3 todo el año) ↔ timestamptz
create or replace function public.ts_py(f date, h time) returns timestamptz
language sql immutable as $$ select ((f + h) + interval '3 hours') at time zone 'UTC' $$;
create or replace function public.hora_py(t timestamptz) returns text
language sql immutable as $$ select to_char(t at time zone 'UTC' - interval '3 hours', 'FMHH24:MI') $$;

-- ---------- entrada y salida -------------------------------------------
-- Una fila por persona, día y turno. La oficina marca en sus turnos (Mañana, Tarde, Noche);
-- los profes en los turnos en que tienen clase (Mañana, Tarde).
-- Si alguien se olvida o marca mal, corrige la hora (hasta 7 días atrás): queda a la vista que se corrigió,
-- la hora original del botón y el motivo. La dirección corrige o borra cualquiera.
create table if not exists public.marcaciones (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references public.perfiles(id) on delete cascade,
  fecha           date not null,
  turno           text not null check (turno in ('Mañana','Tarde','Noche')),
  entrada         timestamptz,
  salida          timestamptz,
  entrada_marcada timestamptz,      -- cuándo tocó "Marcar entrada" (null si la cargó después)
  salida_marcada  timestamptz,
  corregido_por   uuid references auth.users(id) on delete set null,
  corregido_en    timestamptz,
  motivo          text check (motivo is null or length(motivo) <= 300),
  creado          timestamptz not null default now(),
  unique (user_id, fecha, turno),
  constraint marcaciones_orden check (salida is null or (entrada is not null and salida > entrada))
);
create index if not exists marcaciones_fecha_idx on public.marcaciones(fecha);

-- ¿Esa persona tiene ese día y turno algo que marcar? (turno de oficina o clase en el horario / cambio pedido)
create or replace function public.debe_marcar(uid uuid, f date, t text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from perfiles p where p.id = uid and p.activo and (
      (p.rol = 'oficina' and exists (select 1 from oficina_turnos o
                                     where o.user_id = uid and o.fecha = f and o.turno = t and o.estado <> 'rechazado'))
   or (p.rol = 'profe' and (
          exists (select 1 from clases c join profesores pr on pr.id = c.profesor_id or pr.id = c.dictada_por
                  where pr.user_id = uid and c.fecha = f and c.turno = t)
       or exists (select 1 from cambios x join profesores pr on pr.id = x.profesor_id
                  where pr.user_id = uid and x.fecha = f and x.turno = t and x.estado <> 'rechazado')))))
$$;

create or replace function public.turno_txt(t text) returns text
language sql immutable as $$ select case t when 'Mañana' then 'a la mañana' when 'Tarde' then 'a la tarde' else 'a la noche' end $$;

-- Marcar entrada o salida AHORA (botón). La entrada de la oficina también marca el turno (cuenta para el pago).
create or replace function public.marcar_hora(t text, tipo text) returns timestamptz
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); f date := public.hoy_py(); m marcaciones; ahora timestamptz := now();
begin
  if uid is null then raise exception 'Iniciá sesión de nuevo'; end if;
  if tipo not in ('entrada', 'salida') then raise exception 'Tipo no válido'; end if;
  if t not in ('Mañana', 'Tarde', 'Noche') then raise exception 'Turno no válido'; end if;
  if not public.debe_marcar(uid, f, t) then
    raise exception 'Hoy no tenés % % en el horario', case when public.mi_rol() = 'profe' then 'clase' else 'turno' end, public.turno_txt(t);
  end if;
  select * into m from marcaciones where user_id = uid and fecha = f and turno = t for update;
  if tipo = 'entrada' then
    if m.entrada is not null then raise exception 'Ya marcaste tu entrada a las %. Si está mal, tocá Corregir.', public.hora_py(m.entrada); end if;
    insert into marcaciones (user_id, fecha, turno, entrada, entrada_marcada) values (uid, f, t, ahora, ahora)
    on conflict (user_id, fecha, turno) do update set entrada = excluded.entrada, entrada_marcada = excluded.entrada_marcada;
    update oficina_turnos set marcado_en = coalesce(marcado_en, ahora)
     where user_id = uid and fecha = f and turno = t and estado <> 'rechazado' and marcado_en is null;
  else
    if m.entrada is null then raise exception 'Primero marcá tu entrada. Si te olvidaste, cargala con Corregir.'; end if;
    if m.salida is not null then raise exception 'Ya marcaste tu salida a las %. Si está mal, tocá Corregir.', public.hora_py(m.salida); end if;
    update marcaciones set salida = ahora, salida_marcada = ahora where id = m.id;
  end if;
  return ahora;
end $$;

-- Corregir o cargar las horas de un día (la persona: hasta 7 días atrás; la dirección: cualquiera).
create or replace function public.corregir_hora(f date, t text, e time, s time, motivo text, uid uuid default null) returns void
language plpgsql security definer set search_path = public as $$
declare yo uuid := auth.uid(); quien uuid := coalesce(uid, auth.uid()); adm boolean := public.es_admin();
        m marcaciones; te timestamptz; tsal timestamptz; mot text := nullif(left(btrim(coalesce(motivo, '')), 300), '');
begin
  if yo is null then raise exception 'Iniciá sesión de nuevo'; end if;
  if quien <> yo and not adm then raise exception 'Solo la dirección corrige las horas de otra persona'; end if;
  if t not in ('Mañana', 'Tarde', 'Noche') then raise exception 'Turno no válido'; end if;
  if f > public.hoy_py() then raise exception 'No se pueden cargar horas de un día que todavía no llegó'; end if;
  if not adm and f < public.hoy_py() - 7 then raise exception 'Podés corregir tus horas de los últimos 7 días. Para algo más viejo, avisale a la dirección.'; end if;
  select * into m from marcaciones where user_id = quien and fecha = f and turno = t for update;
  if m.id is null and not public.debe_marcar(quien, f, t) then
    raise exception 'Ese día no hay % % en el horario', case when (select rol from perfiles where id = quien) = 'profe' then 'clase' else 'turno' end, public.turno_txt(t);
  end if;
  if e is null then raise exception 'Poné la hora de entrada'; end if;
  te := public.ts_py(f, e); tsal := case when s is not null then public.ts_py(f, s) end;
  -- lo que no cambió (al minuto) queda igual, con sus segundos
  if m.entrada is not null and date_trunc('minute', m.entrada) = te then te := m.entrada; end if;
  if m.salida is not null and tsal is not null and date_trunc('minute', m.salida) = tsal then tsal := m.salida; end if;
  if tsal is not null and tsal <= te then raise exception 'La salida tiene que ser después de la entrada'; end if;
  if te > now() + interval '2 minutes' or tsal > now() + interval '2 minutes' then raise exception 'No podés poner una hora que todavía no pasó'; end if;
  if m.id is not null and m.entrada is not distinct from te and m.salida is not distinct from tsal then
    if mot is not null and mot is distinct from m.motivo then update marcaciones set motivo = mot where id = m.id; end if;
    return;
  end if;
  insert into marcaciones (user_id, fecha, turno, entrada, salida, corregido_por, corregido_en, motivo)
  values (quien, f, t, te, tsal, yo, now(), mot)
  on conflict (user_id, fecha, turno) do update
    set entrada = excluded.entrada, salida = excluded.salida, corregido_por = excluded.corregido_por,
        corregido_en = excluded.corregido_en, motivo = coalesce(excluded.motivo, marcaciones.motivo);
  update oficina_turnos set marcado_en = coalesce(marcado_en, te)
   where user_id = quien and fecha = f and turno = t and estado <> 'rechazado' and marcado_en is null;
end $$;

-- La dirección borra una marcación (y el turno de oficina deja de contar como marcado)
create or replace function public.borrar_marcacion(mid uuid) returns void
language plpgsql security definer set search_path = public as $$
declare m marcaciones;
begin
  if not public.es_admin() then raise exception 'Solo la dirección borra horas'; end if;
  delete from marcaciones where id = mid returning * into m;
  if m.id is null then raise exception 'Esa marcación ya no existe'; end if;
  update oficina_turnos set marcado_en = null where user_id = m.user_id and fecha = m.fecha and turno = m.turno and marcado_en is not null;
end $$;

-- Compatibilidad: "Marcar turno" (versión anterior de la app) = marcar la entrada
create or replace function public.marcar_turno(tid uuid) returns timestamptz
language plpgsql security definer set search_path = public as $$
declare tt text; r timestamptz;
begin
  if not public.es_staff() then raise exception 'Sin permiso'; end if;
  select turno into tt from oficina_turnos where id = tid and user_id = auth.uid() and fecha = public.hoy_py() and estado <> 'rechazado';
  if tt is null then raise exception 'Solo podés marcar tus turnos y el mismo día'; end if;
  select entrada into r from marcaciones where user_id = auth.uid() and fecha = public.hoy_py() and turno = tt;
  if r is not null then return r; end if;
  return public.marcar_hora(tt, 'entrada');
end $$;

alter table public.marcaciones enable row level security;
drop policy if exists marc_ver on public.marcaciones;
create policy marc_ver on public.marcaciones for select to authenticated using (user_id = auth.uid() or public.es_admin());
drop policy if exists marc_borrar on public.marcaciones;
create policy marc_borrar on public.marcaciones for delete to authenticated using (public.es_admin());
revoke all on public.marcaciones from anon, authenticated;
grant select, delete on public.marcaciones to authenticated;

-- ---------- caja chica -------------------------------------------------
-- La plata que la oficina aparta de las cuotas para los gastos de todos los días (hojas, impresiones, marcadores…).
-- ingreso: lo que se aparta de las cuotas (o algún aporte) · gasto: lo que se paga con esa plata
-- arqueo: alguien cuenta la plata de la caja; la diferencia con la app queda anotada y el saldo pasa a ser lo contado.
-- La oficina y la dirección anotan; cada una corrige lo suyo el mismo día; solo la dirección borra.
create table if not exists public.caja_movs (
  id          uuid primary key default gen_random_uuid(),
  tipo        text not null check (tipo in ('ingreso','gasto','arqueo')),
  fecha       date not null default public.hoy_py(),
  monto       bigint not null default 0,      -- ingreso y gasto: > 0 · arqueo: contado − saldo de la app
  categoria   text check (categoria is null or categoria in ('cuotas','aporte','impresion','pizarra','libreria','limpieza','retiro','otros')),
  concepto    text not null check (length(btrim(concepto)) between 1 and 200),
  detalle     text check (detalle is null or length(detalle) <= 1000),
  alumnos     int check (alumnos is null or alumnos between 1 and 5000),
  por_alumno  int check (por_alumno is null or por_alumno between 1 and 10000000),
  contado     bigint check (contado is null or contado >= 0),
  saldo_antes bigint,
  creado_por  uuid references auth.users(id) on delete set null,
  creado      timestamptz not null default now(),
  editado_por uuid references auth.users(id) on delete set null,
  editado     timestamptz,
  constraint caja_monto_chk check ((tipo = 'arqueo' and contado is not null) or (tipo <> 'arqueo' and monto > 0 and monto <= 100000000))
);
create index if not exists caja_movs_fecha_idx on public.caja_movs(fecha, creado);

create or replace function public.caja_sellar() returns trigger
language plpgsql security definer set search_path = public as $$
declare s bigint;
begin
  if auth.uid() is null then return new; end if;   -- cambios del sistema (p. ej. borrar una cuenta)
  new.concepto := btrim(coalesce(new.concepto, '')); new.detalle := nullif(btrim(coalesce(new.detalle, '')), '');
  if tg_op = 'INSERT' then
    perform pg_advisory_xact_lock(hashtext('caja_movs'));
    new.creado_por := auth.uid(); new.creado := now(); new.editado_por := null; new.editado := null;
  else
    if old.tipo = 'arqueo' then raise exception 'Un arqueo no se edita. Si hubo un error, contá la caja de nuevo.'; end if;
    if new.tipo is distinct from old.tipo then raise exception 'No se puede cambiar el tipo de movimiento'; end if;
    new.creado_por := old.creado_por; new.creado := old.creado;
    if (new.fecha, new.monto, new.categoria, new.concepto, new.detalle, new.alumnos, new.por_alumno)
       is distinct from (old.fecha, old.monto, old.categoria, old.concepto, old.detalle, old.alumnos, old.por_alumno) then
      new.editado_por := auth.uid(); new.editado := now();
    else new.editado_por := old.editado_por; new.editado := old.editado; end if;
  end if;
  if new.fecha > public.hoy_py() then raise exception 'La fecha no puede ser de un día que todavía no llegó'; end if;
  if new.tipo = 'ingreso' then
    new.categoria := coalesce(new.categoria, 'cuotas');
    if new.categoria not in ('cuotas', 'aporte') then raise exception 'Tipo de ingreso no válido'; end if;
    if new.categoria <> 'cuotas' then new.alumnos := null; new.por_alumno := null; end if;
    new.contado := null; new.saldo_antes := null;
  elsif new.tipo = 'gasto' then
    new.categoria := coalesce(new.categoria, 'otros');
    if new.categoria not in ('impresion', 'pizarra', 'libreria', 'limpieza', 'retiro', 'otros') then raise exception 'Tipo de gasto no válido'; end if;
    new.alumnos := null; new.por_alumno := null; new.contado := null; new.saldo_antes := null;
  else
    if new.contado is null or new.contado < 0 then raise exception 'Poné cuánta plata hay en la caja'; end if;
    select coalesce(sum(case tipo when 'gasto' then -monto else monto end), 0) into s from caja_movs;
    new.saldo_antes := s; new.monto := new.contado - s; new.categoria := null; new.alumnos := null; new.por_alumno := null;
  end if;
  return new;
end $$;
drop trigger if exists caja_sellar on public.caja_movs;
create trigger caja_sellar before insert or update on public.caja_movs for each row execute function public.caja_sellar();

alter table public.caja_movs enable row level security;
drop policy if exists caja_ver on public.caja_movs;
create policy caja_ver on public.caja_movs for select to authenticated using (public.es_staff());
drop policy if exists caja_crear on public.caja_movs;
create policy caja_crear on public.caja_movs for insert to authenticated with check (public.es_staff());
drop policy if exists caja_editar on public.caja_movs;
create policy caja_editar on public.caja_movs for update to authenticated
  using (public.es_admin() or (public.es_oficina() and creado_por = auth.uid() and (creado at time zone 'UTC' - interval '3 hours')::date = public.hoy_py()))
  with check (public.es_staff());
drop policy if exists caja_borrar on public.caja_movs;
create policy caja_borrar on public.caja_movs for delete to authenticated using (public.es_admin());
revoke all on public.caja_movs from anon;
grant select, insert, update, delete on public.caja_movs to authenticated;

grant execute on function public.marcar_hora(text, text), public.corregir_hora(date, text, time, time, text, uuid),
  public.borrar_marcacion(uuid), public.marcar_turno(uuid) to authenticated;
revoke execute on function public.marcar_hora(text, text), public.corregir_hora(date, text, time, time, text, uuid),
  public.borrar_marcacion(uuid), public.debe_marcar(uuid, date, text), public.caja_sellar() from public, anon;
revoke execute on function public.debe_marcar(uuid, date, text), public.caja_sellar() from authenticated;

-- ---------- registro de actividad: entrada/salida y caja chica ---------
-- "entrada 8:10 → 7:55" (null si no cambió)
create or replace function public.act_hora_cambio(o jsonb, n jsonb, k text) returns text
language sql stable as $$
  select case when (o ->> k) is not distinct from (n ->> k) then null
              else k || ' ' || case when o is not null then coalesce(public.hora_py((o ->> k)::timestamptz), '—') || ' → ' else '' end
                   || coalesce(public.hora_py((n ->> k)::timestamptz), '—') end
$$;

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
                      'entrada_marcada', 'salida_marcada', 'corregido_por', 'corregido_en'];
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
    "entrada":"Entrada","salida":"Salida","tipo":"Movimiento","alumnos":"Alumnos","por_alumno":"Por alumno","contado":"Contado","saldo_antes":"Saldo según la app"}';
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

do $$
declare t text;
begin
  foreach t in array array['alumnos', 'pagos', 'asistencia', 'notas', 'examenes', 'grupos', 'links_inscripcion', 'oficina_turnos',
                           'tareas', 'cambios', 'perfiles', 'profesores', 'disponibilidad', 'oficina_disp', 'oficina_montos', 'config',
                           'marcaciones', 'caja_movs'] loop
    execute format('drop trigger if exists zz_actividad on public.%I', t);
    execute format('create trigger zz_actividad after insert or update or delete on public.%I for each row execute function public.actividad_anotar()', t);
  end loop;
end $$;

revoke execute on function public.actividad_anotar(), public.tareas_sellar(), public.act_valor(text, jsonb),
  public.act_hora_cambio(jsonb, jsonb, text) from public, anon, authenticated;

-- en vivo: tareas y caja chica (oficina), actividad y horas (dirección)
do $$
declare t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['tareas', 'actividad', 'marcaciones', 'caja_movs'] loop
      if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
        execute format('alter publication supabase_realtime add table public.%I', t);
      end if;
    end loop;
  end if;
end $$;
