-- Corrección de exámenes con la cámara (hoja de respuestas VIBE).
-- La clave de cada examen queda en una tabla aparte que los alumnos NO pueden leer.
-- Cada nota guarda además lo que marcó el alumno (respuestas) y la fila (versión) del examen.

alter table public.notas add column if not exists respuestas text;     -- una letra por pregunta: a-e, '-' en blanco, '*' doble marca
alter table public.notas add column if not exists fila smallint;
do $$ begin
  alter table public.notas add constraint notas_fila_ck check (fila between 1 and 4);
exception when duplicate_object then null; end $$;

create table if not exists public.examen_claves (
  examen_id    uuid primary key references public.examenes(id) on delete cascade,
  formato      text not null check (formato in ('ing', 'becas', 'med')),
  preguntas    int  not null check (preguntas between 1 and 60),
  opciones     int  not null check (opciones between 2 and 5),
  claves       jsonb not null default '{}'::jsonb,                     -- {"1": "abcd…", "2": "…"}: una clave por fila
  editado_por  uuid default auth.uid() references auth.users(id) on delete set null,
  editado_en   timestamptz not null default now()
);
alter table public.examen_claves enable row level security;

-- la ven la dirección, la oficina y el profe que da clase en ese grupo; los alumnos no
drop policy if exists examen_claves_ver on public.examen_claves;
create policy examen_claves_ver on public.examen_claves for select to authenticated
  using (public.es_staff() or exists (select 1 from public.examenes e where e.id = examen_id and public.da_clase(e.grupo_id)));
-- no hay políticas de escritura: se guarda solo con guardar_clave(), que valida y la copia a todos los grupos del examen

create or replace function public.guardar_clave(eid uuid, fmt text, cl jsonb)
returns int language plpgsql security definer set search_path = public as $$
declare
  e examenes; n int; o int; k text; v text; ids uuid[]; mx numeric; r record; kc text; unica text; cambiadas int := 0; b int;
begin
  select * into e from examenes where id = eid;
  if not found then raise exception 'No existe ese examen'; end if;
  if not (es_staff() or da_clase(e.grupo_id)) then raise exception 'No podés cargar la clave de este examen'; end if;
  n := case fmt when 'ing' then 20 when 'becas' then 40 when 'med' then 60 end;
  o := case fmt when 'becas' then 4 else 5 end;
  if n is null then raise exception 'Formato de hoja desconocido'; end if;
  if cl is null or jsonb_typeof(cl) <> 'object' or cl = '{}'::jsonb then raise exception 'Falta la clave de respuestas'; end if;
  for k, v in select key, value #>> '{}' from jsonb_each(cl) loop
    if k not in ('1', '2', '3', '4') then raise exception 'Fila inválida: %', k; end if;
    if v is null or length(v) <> n or v !~ ('^[a-' || substr('abcde', o, 1) || ']+$') then
      raise exception 'A la clave de la fila % le faltan respuestas: tienen que ser % (letras %)', k, n, upper(substr('abcde', 1, o));
    end if;
  end loop;
  if (select count(*) from jsonb_object_keys(cl)) = 1 then select value #>> '{}' into unica from jsonb_each(cl); end if;

  -- el mismo examen en todos sus grupos
  ids := array(select x.id from examenes x where x.id = eid or (e.comun is not null and x.comun = e.comun));
  -- con la cámara el puntaje máximo es la cantidad de preguntas: no se mezcla con notas cargadas a mano sobre otro máximo
  select max(x.maximo) into mx from examenes x where x.id = any(ids) and x.maximo <> n
    and exists (select 1 from notas nt where nt.examen_id = x.id and nt.respuestas is null);
  if mx is not null then
    raise exception 'Este examen ya tiene notas cargadas a mano sobre % puntos y la hoja tiene % preguntas. Borrá esas notas o creá otro examen para corregir con la cámara.', mx, n;
  end if;
  update examenes set maximo = n where id = any(ids) and maximo <> n;
  insert into examen_claves (examen_id, formato, preguntas, opciones, claves, editado_por, editado_en)
    select x, fmt, n, o, cl, auth.uid(), now() from unnest(ids) x
  on conflict (examen_id) do update set formato = excluded.formato, preguntas = excluded.preguntas, opciones = excluded.opciones,
    claves = excluded.claves, editado_por = excluded.editado_por, editado_en = excluded.editado_en;

  -- si se corrigió la clave, se recalculan las notas de las hojas ya leídas
  for r in select nt.examen_id, nt.alumno_id, nt.respuestas, nt.fila, nt.nota from notas nt where nt.examen_id = any(ids) and nt.respuestas is not null loop
    kc := coalesce(unica, cl ->> r.fila::text);
    if kc is null then continue; end if;
    select count(*) into b from generate_series(1, n) i where substr(r.respuestas, i, 1) = substr(kc, i, 1);
    if b <> r.nota then
      update notas set nota = b where examen_id = r.examen_id and alumno_id = r.alumno_id;
      cambiadas := cambiadas + 1;
    end if;
  end loop;
  return cambiadas;
end $$;
revoke all on function public.guardar_clave(uuid, text, jsonb) from public, anon;
grant execute on function public.guardar_clave(uuid, text, jsonb) to authenticated;
