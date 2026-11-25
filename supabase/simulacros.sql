-- =====================================================================
--  Simulacros del examen de ingreso (24/11/2026)
--  Al final del cursillo (o antes del repaso) los grupos rinden un simulacro con los 5 exámenes del ingreso:
--  1 Álgebra y Aritmética · 2 Geometría (plana y del espacio) · 3 Trigonometría · 4 Cálculo · 5 Física.
--  Cada examen vale 20 puntos; ingresa quien suma 60 de 100.
--  Cada examen del simulacro es un examen común a los grupos que lo rinden (una fila por grupo en "examenes",
--  con los permisos de siempre y el mismo "comun"), marcado con "simulacro" y su número "sim_n".
--  Las notas se cargan como en cualquier examen (a mano o con la cámara); la app suma los puntos, arma el
--  ranking y lo exporta (Excel y PDF).
--  Se corre una vez en Supabase → SQL Editor (se puede volver a correr). También está al final de schema.sql.
-- =====================================================================
create table if not exists public.simulacros (
  id          uuid primary key default gen_random_uuid(),
  nombre      text not null check (btrim(nombre) <> ''),
  creado_por  uuid default auth.uid() references auth.users(id) on delete set null,
  creado      timestamptz not null default now()
);
alter table public.simulacros enable row level security;

alter table public.examenes add column if not exists simulacro uuid references public.simulacros(id) on delete cascade;
alter table public.examenes add column if not exists sim_n smallint check (sim_n between 1 and 9);
create index if not exists examenes_simulacro_idx on public.examenes(simulacro) where simulacro is not null;

-- Lo ve quien ve al menos uno de sus exámenes (dirección, oficina, y profes y alumnos de esos grupos).
drop policy if exists simulacros_ver on public.simulacros;
create policy simulacros_ver on public.simulacros for select to authenticated
  using (public.es_staff() or exists (select 1 from public.examenes e where e.simulacro = simulacros.id));
-- Solo la dirección lo borra (se borran sus exámenes y notas). Crear, cambiar el nombre y sumar grupos: con las funciones de abajo.
drop policy if exists simulacros_borrar on public.simulacros;
create policy simulacros_borrar on public.simulacros for delete to authenticated using (public.es_admin());
revoke all on public.simulacros from anon, authenticated;
grant select, delete on public.simulacros to authenticated;

-- Iniciar un simulacro (dirección y oficina): nombre, grupos que lo rinden y sus exámenes
--   exs = [{"materia": "Álgebra y Aritmética", "fecha": "2026-11-30"}, …]  (en orden; 20 puntos cada uno)
-- Cada examen se llama "<simulacro> · <materia>". Devuelve el id del simulacro.
create or replace function public.crear_simulacro(nom text, gids uuid[], exs jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare sid uuid; x jsonb; n int := 0; c uuid; m text;
begin
  if not public.es_staff() then raise exception 'Solo la dirección y la oficina pueden iniciar un simulacro'; end if;
  nom := btrim(coalesce(nom, ''));
  if nom = '' then raise exception 'Poné un nombre al simulacro'; end if;
  gids := array(select distinct u from unnest(coalesce(gids, '{}'::uuid[])) u where u is not null);
  if coalesce(array_length(gids, 1), 0) = 0 then raise exception 'Elegí al menos un grupo'; end if;
  if exists (select 1 from unnest(gids) u where not exists (select 1 from grupos g where g.id = u)) then raise exception 'Uno de los grupos no existe'; end if;
  if jsonb_typeof(exs) is distinct from 'array' or jsonb_array_length(exs) not between 1 and 9 then raise exception 'El simulacro tiene que tener entre 1 y 9 exámenes'; end if;
  insert into simulacros (nombre) values (nom) returning id into sid;
  for x in select v from jsonb_array_elements(exs) v loop
    n := n + 1; c := gen_random_uuid();
    m := btrim(coalesce(x ->> 'materia', ''));
    if m = '' then raise exception 'Falta el nombre del examen %', n; end if;
    insert into examenes (grupo_id, nombre, materia, fecha, maximo, comun, simulacro, sim_n)
      select u, nom || ' · ' || m, m, nullif(x ->> 'fecha', '')::date, 20, c, sid, n from unnest(gids) u;
  end loop;
  return sid;
end $$;
revoke all on function public.crear_simulacro(text, uuid[], jsonb) from public, anon;
grant execute on function public.crear_simulacro(text, uuid[], jsonb) to authenticated;

-- Sumar grupos a un simulacro ya iniciado (dirección y oficina): les crea los mismos exámenes
-- (mismo nombre, fecha, puntaje y clave de la cámara). Devuelve cuántos exámenes creó.
create or replace function public.simulacro_grupos(sid uuid, gids uuid[]) returns int
language plpgsql security definer set search_path = public as $$
declare cnt int;
begin
  if not public.es_staff() then raise exception 'Solo la dirección y la oficina pueden sumar grupos'; end if;
  if not exists (select 1 from simulacros s where s.id = sid) then raise exception 'El simulacro no existe'; end if;
  if exists (select 1 from unnest(coalesce(gids, '{}'::uuid[])) u where not exists (select 1 from grupos g where g.id = u)) then raise exception 'Uno de los grupos no existe'; end if;
  with modelo as (
    select distinct on (e.sim_n) e.* from examenes e where e.simulacro = sid order by e.sim_n, e.creado),
  nuevos as (
    insert into examenes (grupo_id, nombre, materia, fecha, maximo, comun, simulacro, sim_n)
    select u, m.nombre, m.materia, m.fecha, m.maximo, m.comun, m.simulacro, m.sim_n
    from modelo m cross join (select distinct u from unnest(gids) u) g(u)
    where not exists (select 1 from examenes x where x.simulacro = sid and x.sim_n = m.sim_n and x.grupo_id = g.u)
    returning id, comun),
  claves as (
    insert into examen_claves (examen_id, formato, preguntas, opciones, claves)
    select nv.id, kk.formato, kk.preguntas, kk.opciones, kk.claves
    from nuevos nv
    join lateral (select kc.* from examen_claves kc join examenes x on x.id = kc.examen_id
                  where x.comun = nv.comun order by kc.editado_en desc limit 1) kk on true
    returning 1)
  select count(*) into cnt from nuevos;
  return cnt;
end $$;
revoke all on function public.simulacro_grupos(uuid, uuid[]) from public, anon;
grant execute on function public.simulacro_grupos(uuid, uuid[]) to authenticated;

-- Cambiar el nombre del simulacro (dirección y oficina): también el de sus exámenes ("<simulacro> · <materia>")
create or replace function public.simulacro_renombrar(sid uuid, nom text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.es_staff() then raise exception 'Solo la dirección y la oficina pueden cambiar el nombre'; end if;
  nom := btrim(coalesce(nom, ''));
  if nom = '' then raise exception 'Poné un nombre al simulacro'; end if;
  update simulacros set nombre = nom where id = sid;
  if not found then raise exception 'El simulacro no existe'; end if;
  update examenes set nombre = nom || ' · ' || coalesce(nullif(btrim(materia), ''), 'Examen ' || sim_n) where simulacro = sid;
end $$;
revoke all on function public.simulacro_renombrar(uuid, text) from public, anon;
grant execute on function public.simulacro_renombrar(uuid, text) to authenticated;
