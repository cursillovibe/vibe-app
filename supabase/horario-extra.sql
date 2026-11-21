-- Clases extra de una semana: días o turnos que el grupo no tiene normalmente (por ejemplo, sábado y domingo
-- solo esta semana), sin cambiar el grupo. Se guardan junto a las materias de esa semana.
alter table public.materias_semana add column if not exists extra jsonb not null default '{}'::jsonb;   -- {"Sáb":"M","Dom":"MT"}

-- Publicar: además de los días del grupo, valen los días extra de esa semana.
create or replace function public.publicar_horario(sem uuid) returns int
language plpgsql security definer set search_path = public as $$
declare w semanas; h jsonb; g record; s jsonb; f date; code text; ex text; n int := 0;
  dias text[] := array['Lun','Mar','Mié','Jue','Vie','Sáb','Dom'];
begin
  if not public.es_admin() then raise exception 'Solo la dirección publica el horario'; end if;
  select * into w from semanas where id = sem;
  if not found then raise exception 'No existe la semana'; end if;
  select data into h from horarios where semana_id = sem order by generado desc limit 1;
  if h is null then raise exception 'Todavía no se armó el horario de esta semana'; end if;
  delete from clases c where c.fecha between w.lunes and w.lunes + 6 and c.dictada_por is null
    and c.nota_profe is null and c.notas_alumnos = '{}'::jsonb
    and not exists (select 1 from evaluaciones e where e.clase_id = c.id)
    and not exists (select 1 from asistencia a where a.grupo_id = c.grupo_id and a.fecha = c.fecha and a.turno = c.turno);
  for g in select key, value from jsonb_each(h) loop
    continue when not exists (select 1 from grupos gr where gr.id::text = g.key);
    for s in select value from jsonb_array_elements(g.value) loop
      continue when coalesce(s->>'materia', '') = '' or array_position(dias, s->>'day') is null;
      continue when (s->>'day') = any(w.feriados);
      select coalesce(gr.dias->>(s->>'day'), '-') into code from grupos gr where gr.id::text = g.key;
      ex := null;
      select m.extra->>(s->>'day') into ex from materias_semana m where m.semana_id = sem and m.grupo_id::text = g.key;
      ex := coalesce(ex, '-');
      continue when not ((s->>'turno' = 'Mañana' and (code in ('M','MT') or ex in ('M','MT')))
                      or (s->>'turno' = 'Tarde' and (code in ('T','MT') or ex in ('T','MT'))));
      f := w.lunes + array_position(dias, s->>'day') - 1;
      insert into clases (grupo_id, fecha, turno, materia, tema, profesor_id, semana_id)
      values (g.key::uuid, f, s->>'turno', s->>'materia', nullif(s->>'tema', ''),
              case when s->>'materia' = 'examen' then null
                   else (select pr.id from profesores pr where pr.id::text = nullif(s->>'profe', '')) end, sem)
      on conflict (grupo_id, fecha, turno) do update
        set materia = excluded.materia, tema = excluded.tema, profesor_id = excluded.profesor_id, semana_id = excluded.semana_id;
      n := n + 1;
    end loop;
  end loop;
  -- los cambios ya aprobados por la dirección se mantienen aunque se vuelva a publicar
  update clases c set profesor_id = x.profesor_id
    from cambios x
   where x.estado = 'aprobado' and x.grupo_id = c.grupo_id and x.fecha = c.fecha and x.turno = c.turno
     and c.fecha between w.lunes and w.lunes + 6;
  update semanas set publicada = now() where id = sem;
  return n;
end $$;
