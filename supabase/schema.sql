-- =====================================================================
--  VIBE App · esquema de base de datos (Supabase / Postgres)
--  Roles: admin (dirección), oficina, profe, alumno
--  Se corre una sola vez en: Supabase → SQL Editor → New query → Run
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------- tablas ----------------------------------------------------

create table if not exists public.perfiles (
  id      uuid primary key references auth.users(id) on delete cascade,
  email   text not null,
  nombre  text not null default '',
  tel     text,
  rol     text not null default 'alumno' check (rol in ('admin','oficina','profe','alumno')),
  activo  boolean not null default true,
  creado  timestamptz not null default now()
);

-- Configuración visible para todos los usuarios con sesión (nombre del cursillo, mensaje, logo…)
create table if not exists public.config (
  clave text primary key,
  valor jsonb not null default '{}'::jsonb
);

-- Configuración privada: solo la lee la base (correos de dirección)
create table if not exists public.config_privada (
  clave text primary key,
  valor jsonb not null
);

create table if not exists public.grupos (
  id        uuid primary key default gen_random_uuid(),
  nombre    text not null,
  programa  text,
  horario   text,
  inicio    date,
  fin       date,
  activo    boolean not null default true,
  plan      jsonb not null default '[]'::jsonb,  -- [{id:"mat"|"c1"…, concepto, monto, venc}]
  creado    timestamptz not null default now()
);

create table if not exists public.alumnos (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid unique references auth.users(id) on delete set null,
  email           text unique,
  nombre          text not null default '',
  apellido        text not null default '',
  ci              text,
  fecha_nac       date,
  tel             text,
  ciudad          text,
  colegio         text,
  encargado       text,
  encargado_tel   text,
  programa        text,                                 -- curso al que se inscribe (Ingeniería, Medicina, Becas, Ingreso a colegios…)
  ficha           jsonb not null default '{}'::jsonb,   -- resto de las preguntas de la ficha
  ficha_completa  boolean not null default false,
  ficha_fecha     timestamptz,
  aviso_enviado   boolean not null default false,
  grupo_id        uuid references public.grupos(id) on delete set null,
  estado          text not null default 'invitado' check (estado in ('invitado','pendiente','activo','baja')),
  descuento       numeric not null default 0 check (descuento between 0 and 100),
  cuota_especial  bigint check (cuota_especial is null or cuota_especial >= 0),
  mat_exonerada   boolean not null default false,
  obs             text,
  creado          timestamptz not null default now()
);
alter table public.alumnos add column if not exists programa text;
create index if not exists alumnos_grupo_idx on public.alumnos(grupo_id);
create index if not exists alumnos_user_idx  on public.alumnos(user_id);

-- Links de inscripción por curso: la oficina comparte un link y el alumno crea su cuenta solo
create table if not exists public.links_inscripcion (
  id        uuid primary key default gen_random_uuid(),
  codigo    text not null unique check (codigo ~ '^[a-z0-9-]{4,40}$'),
  titulo    text not null,
  programa  text,
  grupo_id  uuid references public.grupos(id) on delete set null,
  activo    boolean not null default true,
  creado    timestamptz not null default now()
);
alter table public.alumnos add column if not exists link_id uuid references public.links_inscripcion(id) on delete set null;

create sequence if not exists public.recibo_seq;

create table if not exists public.pagos (
  id              uuid primary key default gen_random_uuid(),
  nro             bigint not null unique default nextval('public.recibo_seq'),
  alumno_id       uuid not null references public.alumnos(id) on delete restrict,
  grupo_id        uuid references public.grupos(id) on delete set null,
  item            text not null,
  concepto        text not null,
  monto           bigint not null check (monto > 0),
  fecha           date not null default current_date,
  metodo          text not null default 'Efectivo',
  obs             text,
  registrado_por  uuid default auth.uid() references auth.users(id) on delete set null,
  creado          timestamptz not null default now()
);
create index if not exists pagos_alumno_idx on public.pagos(alumno_id);

create table if not exists public.asistencia (
  grupo_id   uuid not null references public.grupos(id) on delete cascade,
  fecha      date not null,
  alumno_id  uuid not null references public.alumnos(id) on delete cascade,
  marca      char(1) not null check (marca in ('P','A','T','J')),
  por        uuid default auth.uid() references auth.users(id) on delete set null,
  act        timestamptz not null default now(),
  primary key (grupo_id, fecha, alumno_id)
);
create index if not exists asistencia_alumno_idx on public.asistencia(alumno_id);

create table if not exists public.examenes (
  id          uuid primary key default gen_random_uuid(),
  grupo_id    uuid not null references public.grupos(id) on delete cascade,
  nombre      text not null,
  materia     text,
  fecha       date,
  maximo      numeric not null default 100 check (maximo > 0),
  creado_por  uuid default auth.uid() references auth.users(id) on delete set null,
  creado      timestamptz not null default now()
);

create table if not exists public.notas (
  examen_id  uuid not null references public.examenes(id) on delete cascade,
  alumno_id  uuid not null references public.alumnos(id) on delete cascade,
  nota       numeric not null check (nota >= 0),
  primary key (examen_id, alumno_id)
);

create table if not exists public.profe_grupos (
  profe_id  uuid not null references public.perfiles(id) on delete cascade,
  grupo_id  uuid not null references public.grupos(id) on delete cascade,
  primary key (profe_id, grupo_id)
);

-- ---------- funciones de permisos ------------------------------------

create or replace function public.mi_rol() returns text
language sql stable security definer set search_path = public as $$
  select rol from perfiles where id = auth.uid() and activo
$$;

create or replace function public.es_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select rol in ('admin','oficina') from perfiles where id = auth.uid() and activo), false)
$$;

create or replace function public.es_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select rol = 'admin' from perfiles where id = auth.uid() and activo), false)
$$;

create or replace function public.da_clase(g uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from profe_grupos pg join perfiles p on p.id = pg.profe_id
    where pg.profe_id = auth.uid() and pg.grupo_id = g and p.activo and p.rol = 'profe')
$$;

create or replace function public.mi_alumno() returns uuid
language sql stable security definer set search_path = public as $$
  select id from alumnos where user_id = auth.uid()
$$;

create or replace function public.mi_grupo() returns uuid
language sql stable security definer set search_path = public as $$
  select grupo_id from alumnos where user_id = auth.uid() and estado = 'activo'
$$;

create or replace function public.examen_de_clase(e uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from examenes x where x.id = e and public.da_clase(x.grupo_id))
$$;

create or replace function public.rendi_examen(e uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from notas n where n.examen_id = e and n.alumno_id = public.mi_alumno())
$$;

-- ---------- alta de usuarios -----------------------------------------
-- Cada usuario nuevo (invitado por la oficina) recibe un perfil.
-- Los correos listados en config_privada.admins entran como dirección.
create or replace function public.nuevo_usuario() returns trigger
language plpgsql security definer set search_path = public as $$
declare r text := 'alumno'; l links_inscripcion%rowtype;
begin
  if exists (select 1 from config_privada where clave = 'admins' and valor ? lower(new.email)) then
    r := 'admin';
  end if;
  insert into perfiles (id, email, nombre, rol)
  values (new.id, lower(new.email), coalesce(new.raw_user_meta_data->>'nombre', ''), r)
  on conflict (id) do nothing;
  update alumnos set user_id = new.id where lower(email) = lower(new.email) and user_id is null;
  -- se registró con un link de inscripción: se crea su ficha con el curso del link
  if r = 'alumno' and coalesce(new.raw_user_meta_data->>'codigo', '') <> '' then
    select * into l from links_inscripcion where codigo = lower(new.raw_user_meta_data->>'codigo') and activo;
    if found and not exists (select 1 from alumnos where user_id = new.id or lower(email) = lower(new.email)) then
      insert into alumnos (email, user_id, programa, grupo_id, link_id, estado)
      values (lower(new.email), new.id, l.programa, l.grupo_id, l.id, 'invitado');
    end if;
  end if;
  return new;
end $$;

-- Datos públicos de un link (para mostrar el nombre del curso antes de crear la cuenta)
create or replace function public.info_link(c text)
returns table (titulo text, programa text, activo boolean)
language sql stable security definer set search_path = public as $$
  select titulo, programa, activo from links_inscripcion where codigo = lower(c)
$$;

-- Un alumno que ya tenía cuenta entra con un link: se le crea la ficha si no tenía
create or replace function public.usar_link(c text) returns text
language plpgsql security definer set search_path = public as $$
declare l links_inscripcion%rowtype; mail text;
begin
  if auth.uid() is null then return 'sin_sesion'; end if;
  if exists (select 1 from alumnos where user_id = auth.uid()) then return 'ya_inscripto'; end if;
  if exists (select 1 from perfiles where id = auth.uid() and rol <> 'alumno') then return 'no_alumno'; end if;
  select * into l from links_inscripcion where codigo = lower(c) and activo;
  if not found then return 'link_invalido'; end if;
  select email into mail from perfiles where id = auth.uid();
  insert into alumnos (email, user_id, programa, grupo_id, link_id, estado) values (mail, auth.uid(), l.programa, l.grupo_id, l.id, 'invitado');
  return 'ok';
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.nuevo_usuario();

-- ---------- RPC: el alumno guarda su ficha -----------------------------
-- Solo toca los datos personales; grupo, estado y descuentos los maneja la oficina.
create or replace function public.guardar_mi_ficha(datos jsonb)
returns table (primera_vez boolean)
language plpgsql security definer set search_path = public as $$
declare a alumnos%rowtype;
begin
  select * into a from alumnos where user_id = auth.uid();
  if not found then raise exception 'No hay una ficha asociada a tu cuenta. Avisá a la oficina.'; end if;
  update alumnos set
    nombre        = coalesce(nullif(trim(datos->>'nombre'), ''), nombre),
    apellido      = coalesce(trim(datos->>'apellido'), apellido),
    ci            = nullif(trim(coalesce(datos->>'ci', ci)), ''),
    fecha_nac     = nullif(coalesce(datos->>'fecha_nac', fecha_nac::text), '')::date,
    tel           = nullif(trim(coalesce(datos->>'tel', tel)), ''),
    ciudad        = nullif(trim(coalesce(datos->>'ciudad', ciudad)), ''),
    colegio       = nullif(trim(coalesce(datos->>'colegio', colegio)), ''),
    encargado     = nullif(trim(coalesce(datos->>'encargado', encargado)), ''),
    encargado_tel = nullif(trim(coalesce(datos->>'encargado_tel', encargado_tel)), ''),
    ficha         = ficha || coalesce(datos->'ficha', '{}'::jsonb),
    ficha_completa = true,
    ficha_fecha   = coalesce(ficha_fecha, now()),
    estado        = case when estado = 'invitado' then 'pendiente' else estado end
  where id = a.id;
  update perfiles set nombre = (select trim(x.nombre || ' ' || x.apellido) from alumnos x where x.id = a.id)
  where id = auth.uid();
  return query select not a.ficha_completa;
end $$;

-- ---------- RPC: cómo le fue al alumno comparado con su grupo ----------
create or replace function public.mis_resultados()
returns table (examen_id uuid, promedio numeric, puesto int, rindieron int)
language sql stable security definer set search_path = public as $$
  with yo as (select id from alumnos where user_id = auth.uid()),
  mis as (select n.examen_id, n.nota from notas n where n.alumno_id = (select id from yo))
  select m.examen_id,
         round((select avg(n2.nota) from notas n2 where n2.examen_id = m.examen_id), 2),
         (select count(*) from notas n3 where n3.examen_id = m.examen_id and n3.nota > m.nota)::int + 1,
         (select count(*) from notas n4 where n4.examen_id = m.examen_id)::int
  from mis m
$$;

-- ---------- RPC: siguiente número de recibo (solo vista) ---------------
-- (el número real lo asigna la secuencia al guardar el pago)

-- ---------- seguridad por filas (RLS) ---------------------------------
alter table public.perfiles       enable row level security;
alter table public.config         enable row level security;
alter table public.config_privada enable row level security;
alter table public.grupos         enable row level security;
alter table public.alumnos        enable row level security;
alter table public.pagos          enable row level security;
alter table public.asistencia     enable row level security;
alter table public.examenes       enable row level security;
alter table public.notas          enable row level security;
alter table public.profe_grupos   enable row level security;
alter table public.links_inscripcion enable row level security;

-- perfiles
drop policy if exists perfiles_ver on public.perfiles;
create policy perfiles_ver on public.perfiles for select to authenticated
  using (id = auth.uid() or public.es_staff());
drop policy if exists perfiles_editar on public.perfiles;
create policy perfiles_editar on public.perfiles for update to authenticated
  using (public.es_admin()) with check (public.es_admin());

-- config (config_privada no tiene políticas: nadie la lee desde la app)
drop policy if exists config_ver on public.config;
create policy config_ver on public.config for select to authenticated using (true);
drop policy if exists config_escribir on public.config;
create policy config_escribir on public.config for all to authenticated
  using (public.es_staff()) with check (public.es_staff());

-- grupos
drop policy if exists grupos_ver on public.grupos;
create policy grupos_ver on public.grupos for select to authenticated
  using (public.es_staff() or public.da_clase(id) or id = public.mi_grupo());
drop policy if exists grupos_escribir on public.grupos;
create policy grupos_escribir on public.grupos for all to authenticated
  using (public.es_staff()) with check (public.es_staff());

-- alumnos
drop policy if exists alumnos_ver on public.alumnos;
create policy alumnos_ver on public.alumnos for select to authenticated
  using (public.es_staff() or user_id = auth.uid() or (grupo_id is not null and estado = 'activo' and public.da_clase(grupo_id)));
drop policy if exists alumnos_crear on public.alumnos;
create policy alumnos_crear on public.alumnos for insert to authenticated with check (public.es_staff());
drop policy if exists alumnos_editar on public.alumnos;
create policy alumnos_editar on public.alumnos for update to authenticated
  using (public.es_staff()) with check (public.es_staff());
drop policy if exists alumnos_borrar on public.alumnos;
create policy alumnos_borrar on public.alumnos for delete to authenticated using (public.es_admin());

-- pagos
drop policy if exists pagos_ver on public.pagos;
create policy pagos_ver on public.pagos for select to authenticated
  using (public.es_staff() or alumno_id = public.mi_alumno());
drop policy if exists pagos_crear on public.pagos;
create policy pagos_crear on public.pagos for insert to authenticated with check (public.es_staff());
drop policy if exists pagos_editar on public.pagos;
create policy pagos_editar on public.pagos for update to authenticated
  using (public.es_staff()) with check (public.es_staff());
drop policy if exists pagos_borrar on public.pagos;
create policy pagos_borrar on public.pagos for delete to authenticated using (public.es_admin());

-- asistencia
drop policy if exists asistencia_ver on public.asistencia;
create policy asistencia_ver on public.asistencia for select to authenticated
  using (public.es_staff() or public.da_clase(grupo_id) or alumno_id = public.mi_alumno());
drop policy if exists asistencia_escribir on public.asistencia;
create policy asistencia_escribir on public.asistencia for all to authenticated
  using (public.es_staff() or public.da_clase(grupo_id))
  with check (public.es_staff() or public.da_clase(grupo_id));

-- exámenes
drop policy if exists examenes_ver on public.examenes;
create policy examenes_ver on public.examenes for select to authenticated
  using (public.es_staff() or public.da_clase(grupo_id) or grupo_id = public.mi_grupo() or public.rendi_examen(id));
drop policy if exists examenes_escribir on public.examenes;
create policy examenes_escribir on public.examenes for all to authenticated
  using (public.es_staff() or public.da_clase(grupo_id))
  with check (public.es_staff() or public.da_clase(grupo_id));

-- notas
drop policy if exists notas_ver on public.notas;
create policy notas_ver on public.notas for select to authenticated
  using (public.es_staff() or alumno_id = public.mi_alumno() or public.examen_de_clase(examen_id));
drop policy if exists notas_escribir on public.notas;
create policy notas_escribir on public.notas for all to authenticated
  using (public.es_staff() or public.examen_de_clase(examen_id))
  with check (public.es_staff() or public.examen_de_clase(examen_id));

-- profe_grupos
drop policy if exists profe_grupos_ver on public.profe_grupos;
create policy profe_grupos_ver on public.profe_grupos for select to authenticated
  using (public.es_staff() or profe_id = auth.uid());
drop policy if exists profe_grupos_escribir on public.profe_grupos;
create policy profe_grupos_escribir on public.profe_grupos for all to authenticated
  using (public.es_staff()) with check (public.es_staff());

-- links de inscripción (solo la oficina; el alumno usa info_link / usar_link)
drop policy if exists links_staff on public.links_inscripcion;
create policy links_staff on public.links_inscripcion for all to authenticated
  using (public.es_staff()) with check (public.es_staff());

-- ---------- permisos de tablas para el rol de la API --------------------
revoke all on all tables in schema public from anon;
grant select, insert, update, delete on public.perfiles, public.config, public.grupos, public.alumnos,
  public.pagos, public.asistencia, public.examenes, public.notas, public.profe_grupos, public.links_inscripcion to authenticated;
revoke all on public.config_privada from authenticated;
grant usage on sequence public.recibo_seq to authenticated;
grant execute on function public.guardar_mi_ficha(jsonb), public.mis_resultados(),
  public.mi_rol(), public.es_staff(), public.es_admin(), public.da_clase(uuid), public.mi_alumno(), public.mi_grupo(),
  public.examen_de_clase(uuid), public.rendi_examen(uuid)
  to authenticated;
revoke execute on function public.guardar_mi_ficha(jsonb), public.mis_resultados(), public.usar_link(text) from anon;
grant execute on function public.info_link(text) to anon, authenticated;
grant execute on function public.usar_link(text) to authenticated;

-- ---------- datos iniciales --------------------------------------------
-- Correo(s) de la dirección: entran con rol admin la primera vez que se crean.
insert into public.config_privada (clave, valor)
values ('admins', '["informacion@vibe.com.py"]'::jsonb)
on conflict (clave) do nothing;

insert into public.config (clave, valor)
values ('general', '{"nombre":"Cursillo VIBE","dir":"Coronel Oviedo - Paraguay","tel":"+595 994 214 571"}'::jsonb)
on conflict (clave) do nothing;
