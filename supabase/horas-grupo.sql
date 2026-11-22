-- Horas de clase de cada grupo: a qué hora empieza y termina la mañana y la tarde (Editar grupo → Horas de clase).
--   grupos.horas = {"Mañana": {"ini": "08:00", "fin": "12:00"}, "Tarde": {"ini": "14:00", "fin": "18:00"}}
--   Si un grupo no tiene horas cargadas: mañana 8:00 a 12:00 y tarde 13:30 a 17:30 (como siempre).
-- Se usan en: la imagen del horario (profes y alumnos), el mensaje a cada profe, los avisos al celular
-- (noche, mañana, marcar entrada y salida) y desde qué hora se puede evaluar la clase.
-- Se corre una vez en Supabase → SQL Editor (se puede volver a correr).

alter table public.grupos add column if not exists horas jsonb not null default '{}'::jsonb;

-- "00:00".."23:59": hora válida
create or replace function public.hora_ok(v text) returns boolean
language sql immutable as $$ select coalesce(v, '') ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' $$;

-- solo turnos Mañana / Tarde, cada uno con ini y fin válidos y el fin después del inicio
create or replace function public.horas_validas(h jsonb) returns boolean
language sql immutable as $$
  select jsonb_typeof(h) = 'object' and not exists (
    select 1 from jsonb_each(h) e
    where case when e.key not in ('Mañana', 'Tarde') or jsonb_typeof(e.value) <> 'object' then true
               when not public.hora_ok(e.value ->> 'ini') or not public.hora_ok(e.value ->> 'fin') then true
               else (e.value ->> 'ini')::time >= (e.value ->> 'fin')::time end)
$$;
alter table public.grupos drop constraint if exists grupos_horas_ok;
alter table public.grupos add constraint grupos_horas_ok check (public.horas_validas(horas));

-- hora de inicio (o de fin) de un turno según las horas del grupo; si no hay, las de siempre
create or replace function public.hora_turno(h jsonb, t text, fin boolean default false) returns time
language sql immutable as $$
  select case when public.hora_ok(h -> t ->> (case when fin then 'fin' else 'ini' end)) then (h -> t ->> (case when fin then 'fin' else 'ini' end))::time
              when t = 'Tarde' then (case when fin then time '17:30' else time '13:30' end)
              else (case when fin then time '12:00' else time '08:00' end) end
$$;

-- Se puede evaluar una clase desde que empieza (a la hora de su grupo) hasta el día siguiente a la noche
create or replace function public.eval_abierta(f date, t text, g uuid) returns boolean
language sql stable set search_path = public as $$
  select (now() at time zone 'UTC' - interval '3 hours') >= f + public.hora_turno((select gr.horas from grupos gr where gr.id = g), t)
     and public.hoy_py() <= f + 1
$$;
revoke execute on function public.eval_abierta(date, text, uuid) from public, anon;

-- Lo que ve el alumno al abrir el link: ahora con la hora de inicio de cada clase
create or replace function public.eval_info(tk text) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object('grupo', g.nombre, 'fecha', l.fecha, 'cerrada', public.hoy_py() > l.fecha + 1,
    'clases', coalesce((select json_agg(json_build_object('id', c.id, 'turno', c.turno, 'materia', c.materia, 'tema', c.tema,
                          'abierta', public.eval_abierta(c.fecha, c.turno, c.grupo_id), 'hora', to_char(public.hora_turno(g.horas, c.turno), 'FMHH24:MI'), 'lista', x.presentes > 0, 'llena', x.presentes > 0 and x.resp >= x.presentes)
                          order by (c.turno = 'Tarde'))
                        from clases c
                        cross join lateral (select (select count(*) from asistencia a where a.grupo_id = c.grupo_id and a.fecha = c.fecha
                                                      and a.turno = c.turno and a.marca in ('P', 'T')) as presentes,
                                                   (select count(*) from evaluaciones e where e.clase_id = c.id) as resp) x
                        where c.grupo_id = l.grupo_id and c.fecha = l.fecha
                          and ((c.materia is not null and c.materia <> 'examen') or (c.materia is null and c.dictada_por is not null))), '[]'::json))
  from eval_links l join grupos g on g.id = l.grupo_id where l.token = tk
$$;

-- Guardar una evaluación (igual que antes, con la hora del grupo)
create or replace function public.evaluar(tk text, cid uuid, general int, entendio int, puntual text, dudas text, termino text, comentario text)
returns void language plpgsql security definer set search_path = public as $$
declare l eval_links; c clases; tope int;
begin
  select * into l from eval_links where token = tk;
  if not found then raise exception 'Este link de evaluación no es válido'; end if;
  select * into c from clases where id = cid and grupo_id = l.grupo_id and fecha = l.fecha;
  if not found then raise exception 'Esa clase no corresponde a este link'; end if;
  if not public.eval_abierta(c.fecha, c.turno, c.grupo_id) then raise exception 'Esta clase todavía no empezó o ya cerró la evaluación'; end if;
  select count(*) into tope from asistencia a where a.grupo_id = c.grupo_id and a.fecha = c.fecha and a.turno = c.turno and a.marca in ('P', 'T');
  if tope = 0 then raise exception 'Todavía no se llamó lista de esta clase: la evaluación se habilita cuando el profe la llama'; end if;
  if (select count(*) from evaluaciones e where e.clase_id = cid) >= tope then raise exception 'Ya respondieron todos los presentes de esta clase'; end if;
  insert into evaluaciones (clase_id, general, entendio, puntual, dudas, termino, comentario)
  values (cid, general, entendio, nullif(puntual, ''), nullif(dudas, ''), nullif(termino, ''), nullif(left(btrim(coalesce(comentario, '')), 600), ''));
end $$;

-- Avisos de la noche y de la mañana: con la hora de inicio de cada grupo
create or replace function public.push_mensajes(tipo text, f date, sem uuid default null, actualizado boolean default false)
returns table (endpoint text, keys jsonb, titulo text, cuerpo text)
language plpgsql stable security definer set search_path = public as $$
declare cfg jsonb; w semanas; l date;
  dia text := (array['Domingo','Lunes','Martes','Miércoles','Jueves','Viernes','Sábado'])[extract(dow from f)::int + 1] || ' ' || to_char(f, 'FMDD/FMMM');
begin
  select coalesce(c.valor->'push', '{}'::jsonb) into cfg from config c where c.clave = 'general';
  cfg := coalesce(cfg, '{}'::jsonb);
  if tipo in ('noche', 'manana') then
    -- profes: sus clases de ese día (los exámenes no tienen profe)
    if coalesce((cfg->>(case when tipo = 'noche' then 'prNoche' else 'prManana' end))::boolean, true) then
      return query
      with cl as (
        select p.user_id,
          string_agg(public.mat_nombre(c.materia) || coalesce(' (' || nullif(btrim(c.tema), '') || ')', '') || ' en ' || g.nombre || ', '
                     || to_char(public.hora_turno(g.horas, c.turno), 'FMHH24:MI'), ' · ' order by public.hora_turno(g.horas, c.turno), g.orden, g.nombre) as txt
        from clases c
        join grupos g on g.id = c.grupo_id and g.activo
        join profesores p on p.id = c.profesor_id and p.activo and p.user_id is not null
        where c.fecha = f and coalesce(c.materia, '') not in ('', 'examen')
        group by p.user_id)
      select s.endpoint, s.keys,
        case when tipo = 'noche' then 'Mañana das clase 📚' else 'Hoy das clase ☀️' end,
        case when tipo = 'noche' then dia || ': ' || cl.txt || '. Acordate de llamar lista desde la app.'
             else cl.txt || '. ¡Buena clase! No te olvides de llamar lista.' end
      from cl join push_subs s on s.user_id = cl.user_id;
    end if;
    -- alumnos: las clases de su grupo (sin el nombre del profe)
    if coalesce((cfg->>(case when tipo = 'noche' then 'alNoche' else 'alManana' end))::boolean, true) then
      return query
      with cl as (
        select a.user_id, bool_or(c.materia = 'examen') as ex,
          string_agg(case when c.materia = 'examen' then 'Examen' else public.mat_nombre(c.materia) end
                     || coalesce(' (' || nullif(btrim(c.tema), '') || ')', '') || ' a las ' || to_char(public.hora_turno(g.horas, c.turno), 'FMHH24:MI'),
                     ' · ' order by public.hora_turno(g.horas, c.turno)) as txt
        from alumnos a
        join grupos g on g.id = a.grupo_id and g.activo
        join clases c on c.grupo_id = a.grupo_id and c.fecha = f and coalesce(c.materia, '') <> ''
        where a.estado = 'activo' and a.user_id is not null
        group by a.user_id)
      select s.endpoint, s.keys,
        case when tipo = 'noche' then (case when cl.ex then 'Mañana tenés examen 📝' else 'Mañana tenés clase 🎒' end)
             else (case when cl.ex then 'Hoy tenés examen 📝' else 'Hoy tenés clase ☀️' end) end,
        case when tipo = 'noche' then cl.txt || (case when cl.ex then '. Repasá, prepará tus materiales y descansá bien. ¡Vos podés!'
                                                     else '. Prepará tus cosas para mañana: cuaderno, calculadora y materiales.' end)
             else cl.txt || (case when cl.ex then '. ¡Éxitos! No te olvides tus materiales.' else '. No te olvides tus materiales. ¡Te esperamos!' end) end
      from cl join push_subs s on s.user_id = cl.user_id;
    end if;
    -- oficina: su turno de ese día (los que le asignó la dirección)
    if coalesce((cfg->>(case when tipo = 'noche' then 'ofNoche' else 'ofManana' end))::boolean, true) then
      return query
      with ot as (
        select t.user_id, string_agg('de la ' || lower(t.turno), ' y ' order by array_position(array['Mañana', 'Tarde', 'Noche'], t.turno)) as ts
        from oficina_turnos t join perfiles pf on pf.id = t.user_id and pf.activo
        where t.fecha = f and t.estado = 'asignado'
        group by t.user_id)
      select s.endpoint, s.keys,
        case when tipo = 'noche' then 'Mañana te toca la oficina 🏢' else 'Hoy te toca la oficina ☀️' end,
        case when tipo = 'noche' then dia || ': turno ' || ot.ts || '. Acordate de marcar tu turno en la app cuando llegues.'
             else 'Turno ' || ot.ts || '. No te olvides de marcar tu turno en la app. ¡Buen día!' end
      from ot join push_subs s on s.user_id = ot.user_id;
    end if;
  elsif tipo = 'oficina' then
    -- turnos de la semana para cada persona de la oficina (lo manda la dirección desde Turnos oficina)
    return query
      select s.endpoint, s.keys,
        case when actualizado then 'Se actualizaron tus turnos 🏢' else 'Tus turnos en la oficina 🏢' end,
        'Semana del ' || to_char(f, 'FMDD/FMMM') || ' al ' || to_char(f + 6, 'FMDD/FMMM') || ': '
          || coalesce(x.ts || '. Miralos en Mis turnos.', 'esta semana no tenés turnos asignados.')
      from (select pf.id as user_id,
              (select string_agg(lower(left((array['Dom','Lun','Mar','Mié','Jue','Vie','Sáb'])[extract(dow from t.fecha)::int + 1], 3)) || ' ' || lower(t.turno), ' · '
                                 order by t.fecha, array_position(array['Mañana', 'Tarde', 'Noche'], t.turno))
               from oficina_turnos t where t.user_id = pf.id and t.fecha between f and f + 6 and t.estado = 'asignado') as ts
            from perfiles pf where pf.rol = 'oficina' and pf.activo) x
      join push_subs s on s.user_id = x.user_id;
  elsif tipo = 'publicado' then
    select * into w from semanas where id = sem;
    if not found then return; end if;
    return query
      select s.endpoint, s.keys,
        case when actualizado then 'Se actualizó el horario 📅' else 'Salió el horario de la semana 📅' end,
        'Semana del ' || to_char(w.lunes, 'FMDD/FMMM') || ' al ' || to_char(w.lunes + 6, 'FMDD/FMMM') || ': '
          || case when x.n = 0 then 'esta semana no tenés clases asignadas.' when x.n = 1 then 'tenés 1 clase. Mirala en la app.'
                  else 'tenés ' || x.n || ' clases. Miralas en la app.' end
      from (select p.user_id, (select count(*) from clases c join grupos g on g.id = c.grupo_id and g.activo
                               where c.profesor_id = p.id and c.fecha between w.lunes and w.lunes + 6 and coalesce(c.materia, '') not in ('', 'examen')) as n
            from profesores p where p.activo and p.user_id is not null) x
      join push_subs s on s.user_id = x.user_id;
    return query
      select s.endpoint, s.keys,
        case when actualizado then 'Se actualizó tu horario 📅' else 'Ya está tu horario de la semana 📅' end,
        'Semana del ' || to_char(w.lunes, 'FMDD/FMMM') || ' al ' || to_char(w.lunes + 6, 'FMDD/FMMM') || ': mirá en la app qué materia y qué tema tenés cada día.'
      from alumnos a
      join grupos g on g.id = a.grupo_id and g.activo
      join push_subs s on s.user_id = a.user_id
      where a.estado = 'activo'
        and exists (select 1 from clases c where c.grupo_id = a.grupo_id and c.fecha between w.lunes and w.lunes + 6 and coalesce(c.materia, '') <> '');
  elsif tipo = 'disp' then
    l := f - (extract(isodow from f)::int - 1) + 7;
    -- oficina: misma fecha límite que los profes
    if coalesce((cfg->>'ofDisp')::boolean, true) then
      return query
        select s.endpoint, s.keys, 'Tu disponibilidad para la oficina 🗓️',
          case extract(isodow from f)::int
            when 3 then 'Ya podés cargar tus turnos disponibles para la semana del ' || to_char(l, 'FMDD/FMMM') || ' en Mis turnos. Tenés tiempo hasta el sábado a las 17:00.'
            when 6 then '¡Último aviso! Hoy a las 17:00 cierra la carga de disponibilidad de la oficina para la semana del ' || to_char(l, 'FMDD/FMMM') || '.'
            else 'Te falta cargar tu disponibilidad para la oficina (semana del ' || to_char(l, 'FMDD/FMMM') || '). Cierra el sábado a las 17:00.' end
        from perfiles pf join push_subs s on s.user_id = pf.id
        where pf.rol = 'oficina' and pf.activo
          and not exists (select 1 from oficina_disp d join semanas sm on sm.id = d.semana_id where sm.lunes = l and d.user_id = pf.id and d.enviado);
    end if;
    if not coalesce((cfg->>'disp')::boolean, true) then return; end if;
    return query
      select s.endpoint, s.keys, 'Tu disponibilidad 🗓️',
        case extract(isodow from f)::int
          when 3 then 'Ya podés cargar tu disponibilidad para la semana del ' || to_char(l, 'FMDD/FMMM') || '. Tenés tiempo hasta el sábado a las 17:00.'
          when 6 then '¡Último aviso! Hoy a las 17:00 cierra la carga de disponibilidad para la semana del ' || to_char(l, 'FMDD/FMMM') || '.'
          else 'Te falta cargar tu disponibilidad para la semana del ' || to_char(l, 'FMDD/FMMM') || '. Cierra el sábado a las 17:00.' end
      from profesores p join push_subs s on s.user_id = p.user_id
      where p.activo
        and not exists (select 1 from disponibilidad d join semanas sm on sm.id = d.semana_id where sm.lunes = l and d.profesor_id = p.id and d.enviado);
  end if;
end $$;

-- Avisos para marcar la clase, con las horas de cada grupo (lo llama la función "push" cada 15 minutos con la hora de Paraguay):
--   entrada: desde que empieza la clase y hasta 1 hora después → "Empieza tu clase… marcá tu entrada" (si no la marcó)
--   salida:  desde que termina y hasta 1 h 30 después → "Terminó tu clase… marcá tu salida" (si no la marcó; si tampoco
--            marcó la entrada, se lo dice)
-- Les llega a quien da la clase: el profe del horario, o el que pidió el cambio (si no se lo rechazaron).
-- Cada aviso sale una sola vez por profe, día, turno y tipo (queda anotado en push_log).
-- Se activan o apagan en Ajustes → Avisos al celular (config.general.push.prEntrada / prSalida; vienen activados).
-- (push_marcar(tipo, f), el de las horas fijas, ya no lo usa la función push.)
create or replace function public.push_marcar_ahora(f date, m int)
returns table (endpoint text, keys jsonb, titulo text, cuerpo text, aviso text)
language plpgsql volatile security definer set search_path = public as $$
declare cfg jsonb; pe boolean; ps boolean;
begin
  select coalesce(c.valor -> 'push', '{}'::jsonb) into cfg from config c where c.clave = 'general';
  cfg := coalesce(cfg, '{}'::jsonb);
  pe := coalesce((cfg ->> 'prEntrada')::boolean, true);
  ps := coalesce((cfg ->> 'prSalida')::boolean, true);
  if not pe and not ps then return; end if;
  return query
  with cl as (
    select c.turno, c.materia, c.tema, g.nombre as grupo, g.orden,
      (extract(epoch from public.hora_turno(g.horas, c.turno)) / 60)::int as ini,
      (extract(epoch from public.hora_turno(g.horas, c.turno, true)) / 60)::int as fin,
      to_char(public.hora_turno(g.horas, c.turno), 'FMHH24:MI') as hora,
      coalesce((select x.profesor_id from cambios x
                 where x.grupo_id = c.grupo_id and x.fecha = c.fecha and x.turno = c.turno and x.estado <> 'rechazado'
                 order by x.estado = 'aprobado' desc, x.creado desc limit 1), c.profesor_id) as prof
    from clases c join grupos g on g.id = c.grupo_id and g.activo
    where c.fecha = f and coalesce(c.materia, '') not in ('', 'examen')),
  ev as (
    select 'entrada'::text as k, cl.* from cl where pe and m >= cl.ini and m < cl.ini + 60
    union all
    select 'salida'::text, cl.* from cl where ps and m >= cl.fin and m < cl.fin + 90),
  pr as (
    select ev.k, ev.turno, p.user_id,
      string_agg(public.mat_nombre(ev.materia) || coalesce(' (' || nullif(btrim(ev.tema), '') || ')', '') || ' en ' || ev.grupo
                 || case when ev.k = 'entrada' then ', ' || ev.hora else '' end, ' · ' order by ev.ini, ev.orden, ev.grupo) as txt
    from ev join profesores p on p.id = ev.prof and p.activo and p.user_id is not null
    group by ev.k, ev.turno, p.user_id),
  pend as (
    select pr.k, pr.turno, pr.user_id, pr.txt, mk.entrada as ent_marcada,
      'marcar|' || pr.k || '|' || f || '|' || pr.turno || '|' || pr.user_id as clave
    from pr left join marcaciones mk on mk.user_id = pr.user_id and mk.fecha = f and mk.turno = pr.turno
    where (pr.k = 'entrada' and mk.entrada is null) or (pr.k = 'salida' and mk.salida is null)),
  nuevo as (
    insert into push_log (clave) select pend.clave from pend on conflict do nothing returning push_log.clave)
  select s.endpoint, s.keys,
    case when pend.k = 'entrada' then 'Empieza tu clase ⏰'
         when pend.ent_marcada is null then 'Te faltó marcar tu clase ✋'
         else 'Terminó tu clase ✅' end,
    case when pend.k = 'entrada' then pend.txt || '. No te olvides de marcar tu entrada en la app y de llamar lista.'
         when pend.ent_marcada is null then pend.txt || ': no marcaste la entrada ni la salida. Cargalas en la app, en “Tus entradas y salidas”.'
         else pend.txt || '. No te olvides de marcar tu salida en la app.' end,
    pend.k
  from pend join nuevo on nuevo.clave = pend.clave
  join push_subs s on s.user_id = pend.user_id;
end $$;
revoke all on function public.push_marcar_ahora(date, int) from public, anon, authenticated;
grant execute on function public.push_marcar_ahora(date, int) to service_role;
