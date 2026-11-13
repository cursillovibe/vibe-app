-- Importa los datos de la app vibe-horarios (plantel, grupos, semanas, disponibilidad,
-- materias y el último horario de cada semana). Se puede correr más de una vez.
-- Entre las marcas $mig$ va el JSON exportado de la base de vibe-horarios.
create temp table if not exists mig (j jsonb);
truncate mig;
insert into mig values ($mig$__DATOS__$mig$::jsonb);

-- Volver a correrlo solo suma lo nuevo: no pisa grupos, plantel ni materias editados en la app,
-- y de la disponibilidad se queda con la más reciente.

-- grupos (mismos id; el plan de pagos y el programa los completa la oficina)
insert into public.grupos (id, nombre, descripcion, prioridad, dias, orden, activo, programa)
select (x->>'id')::uuid, x->>'nombre', nullif(x->>'descripcion', ''), coalesce((x->>'prioridad')::boolean, false),
       coalesce(x->'dias', '{}'::jsonb), coalesce((x->>'orden')::int, 0), coalesce((x->>'activo')::boolean, true),
       case when x->>'nombre' ilike '%beca%' then 'Becas' else 'Ingeniería' end
from mig, jsonb_array_elements(j->'grupos') x
on conflict (id) do nothing;

-- plantel (sin la cuenta "Admin VIBE"; Guido queda con el correo de la dirección)
insert into public.profesores (id, email, nombre, telefono, activo)
select (x->>'id')::uuid,
       case lower(x->>'email') when 'guidobenitez11@gmail.com' then 'informacion@vibe.com.py' else nullif(lower(x->>'email'), '') end,
       x->>'nombre', nullif(x->>'telefono', ''), coalesce((x->>'activo')::boolean, true)
from mig, jsonb_array_elements(j->'profesores') x
where coalesce((x->>'es_admin')::boolean, false) = false
on conflict (id) do nothing;

insert into public.profesores_puntajes (profesor_id, anios, manejo, punt, scores)
select (x->>'id')::uuid, coalesce((x->>'anios')::numeric, 0), coalesce((x->>'manejo')::numeric, 0), coalesce((x->>'punt')::numeric, 0), coalesce(x->'scores', '{}'::jsonb)
from mig, jsonb_array_elements(j->'profesores') x
where exists (select 1 from public.profesores p where p.id = (x->>'id')::uuid)
on conflict (profesor_id) do nothing;

insert into public.semanas (lunes, feriados, carga_abierta_hasta)
select (x->>'lunes')::date, coalesce(array(select jsonb_array_elements_text(x->'feriados')), '{}'), (x->>'carga_abierta_hasta')::timestamptz
from mig, jsonb_array_elements(j->'semanas') x
on conflict (lunes) do update set feriados = case when cardinality(public.semanas.feriados) = 0 then excluded.feriados else public.semanas.feriados end;

insert into public.disponibilidad (semana_id, profesor_id, dias, enviado, act)
select s.id, (x->>'profesor_id')::uuid, coalesce(x->'dias', '{}'::jsonb), coalesce((x->>'enviado')::boolean, false), coalesce((x->>'updated_at')::timestamptz, now())
from mig, jsonb_array_elements(j->'disponibilidad') x join public.semanas s on s.lunes = (x->>'lunes')::date
where exists (select 1 from public.profesores p where p.id = (x->>'profesor_id')::uuid)
on conflict (semana_id, profesor_id) do update set dias = excluded.dias, enviado = excluded.enviado, act = excluded.act
  where public.disponibilidad.act < excluded.act;

insert into public.materias_semana (semana_id, grupo_id, items)
select s.id, (x->>'grupo_id')::uuid, coalesce(x->'items', '[]'::jsonb)
from mig, jsonb_array_elements(j->'materias') x join public.semanas s on s.lunes = (x->>'lunes')::date
where exists (select 1 from public.grupos g where g.id = (x->>'grupo_id')::uuid)
on conflict (semana_id, grupo_id) do update set items = excluded.items
  where jsonb_array_length(public.materias_semana.items) = 0;

insert into public.horarios (semana_id, data, generado)
select s.id, x->'data', (x->>'generado_at')::timestamptz
from mig, jsonb_array_elements(j->'horarios') x join public.semanas s on s.lunes = (x->>'lunes')::date
where not exists (select 1 from public.horarios h where h.semana_id = s.id and h.generado >= (x->>'generado_at')::timestamptz);

-- vincular a los profes que ya tienen cuenta en esta app
update public.profesores pr set user_id = u.id
  from auth.users u where lower(u.email) = lower(pr.email) and pr.user_id is null;
update public.perfiles p set rol = 'profe'
  from public.profesores pr where pr.user_id = p.id and pr.activo and p.rol = 'alumno';

select (select count(*) from public.profesores) as profes, (select count(*) from public.grupos) as grupos,
       (select count(*) from public.semanas) as semanas, (select count(*) from public.disponibilidad) as disponibilidad,
       (select count(*) from public.materias_semana) as materias, (select count(*) from public.horarios) as horarios;
