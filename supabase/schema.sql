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
  turno      text not null default 'Mañana' constraint asistencia_turno_chk check (turno in ('Mañana','Tarde')),
  alumno_id  uuid not null references public.alumnos(id) on delete cascade,
  marca      char(1) not null check (marca in ('P','A','T','J')),
  por        uuid default auth.uid() references auth.users(id) on delete set null,
  act        timestamptz not null default now(),
  primary key (grupo_id, fecha, turno, alumno_id)
);
-- bases creadas antes del horario: se agrega el turno (mañana y tarde cuentan por separado)
alter table public.asistencia add column if not exists turno text not null default 'Mañana';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'asistencia_turno_chk') then
    alter table public.asistencia add constraint asistencia_turno_chk check (turno in ('Mañana','Tarde'));
  end if;
  if (select pg_get_constraintdef(oid) from pg_constraint where conrelid = 'public.asistencia'::regclass and contype = 'p') not like '%turno%' then
    alter table public.asistencia drop constraint asistencia_pkey;
    alter table public.asistencia add primary key (grupo_id, fecha, turno, alumno_id);
  end if;
end $$;
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

-- ---------- horario de profes (antes app vibe-horarios) ----------------
-- Turno por día de cada grupo: {"Lun":"M","Mar":"T","Sáb":"MT",…}  - nada · M mañana · T tarde · MT doble
alter table public.grupos add column if not exists dias jsonb not null default '{}'::jsonb;
alter table public.grupos add column if not exists prioridad boolean not null default false;  -- recibe primero a los mejores profes
alter table public.grupos add column if not exists orden int not null default 0;
alter table public.grupos add column if not exists descripcion text;

-- Plantel. El correo vincula al profe con su cuenta de la app.
create table if not exists public.profesores (
  id        uuid primary key default gen_random_uuid(),
  user_id   uuid unique references auth.users(id) on delete set null,
  email     text unique,
  nombre    text not null,
  telefono  text,
  activo    boolean not null default true,
  creado    timestamptz not null default now()
);
-- Puntajes y pago por clase: solo los ve la dirección
create table if not exists public.profesores_puntajes (
  profesor_id  uuid primary key references public.profesores(id) on delete cascade,
  anios        numeric not null default 0 check (anios >= 0),
  manejo       numeric not null default 0 check (manejo between 0 and 10),
  punt         numeric not null default 0 check (punt between 0 and 10),
  scores       jsonb not null default '{}'::jsonb,   -- {"arit":8,"alg":10,"geo":null,…} null = no da la materia
  monto_clase  numeric not null default 0 check (monto_clase >= 0)
);
-- Una fila por semana (identificada por el lunes)
create table if not exists public.semanas (
  id                   uuid primary key default gen_random_uuid(),
  lunes                date not null unique check (extract(isodow from lunes) = 1),
  feriados             text[] not null default '{}',
  carga_abierta_hasta  timestamptz,         -- la dirección reabre la carga de disponibilidad hasta esta hora
  publicada            timestamptz,         -- última vez que se publicó el horario
  creado               timestamptz not null default now()
);
-- Disponibilidad que marca cada profe: {"Lun":{"Mañana":true,"Tarde":false},…}
create table if not exists public.disponibilidad (
  semana_id    uuid not null references public.semanas(id) on delete cascade,
  profesor_id  uuid not null references public.profesores(id) on delete cascade,
  dias         jsonb not null default '{}'::jsonb,
  enviado      boolean not null default false,
  act          timestamptz not null default now(),
  primary key (semana_id, profesor_id)
);
-- Materias de la semana por grupo, sin día: [{"mat":"alg","tema":"…","nivel":"alto","seguida":true,"dia":"Mié"}]
create table if not exists public.materias_semana (
  semana_id  uuid not null references public.semanas(id) on delete cascade,
  grupo_id   uuid not null references public.grupos(id) on delete cascade,
  items      jsonb not null default '[]'::jsonb,
  primary key (semana_id, grupo_id)
);
-- Borradores del horario armado: {"<grupo_id>":[{"day","turno","materia","tema","nivel","profe"}]}
create table if not exists public.horarios (
  id         uuid primary key default gen_random_uuid(),
  semana_id  uuid not null references public.semanas(id) on delete cascade,
  data       jsonb not null,
  generado   timestamptz not null default now()
);
create index if not exists horarios_semana_idx on public.horarios(semana_id, generado desc);
-- Clases publicadas. Cuando un profe llama lista, la clase queda dictada por él.
create table if not exists public.clases (
  id           uuid primary key default gen_random_uuid(),
  grupo_id     uuid not null references public.grupos(id) on delete cascade,
  fecha        date not null,
  turno        text not null default 'Mañana' check (turno in ('Mañana','Tarde')),
  materia      text,                 -- arit · alg · geo · trig · calc · fis · examen (vacío = lista fuera del horario)
  tema         text,
  profesor_id  uuid references public.profesores(id) on delete set null,   -- el del horario
  semana_id    uuid references public.semanas(id) on delete set null,
  dictada_por  uuid references public.profesores(id) on delete set null,   -- el que llamó lista
  dictada_en   timestamptz,
  obs          text,
  unique (grupo_id, fecha, turno)
);
create index if not exists clases_fecha_idx on public.clases(fecha);
-- Notas del profe al llamar lista (las ve la oficina; el alumno no): de la clase y por alumno {"<alumno_id>":"se retiró 10:30"}
alter table public.clases add column if not exists nota_profe text;
alter table public.clases add column if not exists notas_alumnos jsonb not null default '{}'::jsonb;
alter table public.clases add column if not exists nota_por uuid references auth.users(id) on delete set null;
alter table public.clases add column if not exists nota_en timestamptz;

-- Pedidos de cambio: un profe va a dar (o ya dio) una clase que no estaba a su nombre en el horario.
-- Con el pedido ya puede llamar lista ese día; la clase le cuenta para el pago cuando la dirección lo aprueba.
create table if not exists public.cambios (
  id           uuid primary key default gen_random_uuid(),
  profesor_id  uuid not null references public.profesores(id) on delete cascade,   -- el que pide
  grupo_id     uuid not null references public.grupos(id) on delete cascade,
  fecha        date not null,
  turno        text not null check (turno in ('Mañana','Tarde')),
  motivo       text,
  estado       text not null default 'pendiente' check (estado in ('pendiente','aprobado','rechazado')),
  profe_antes  uuid references public.profesores(id) on delete set null,           -- el que la tenía en el horario
  creado       timestamptz not null default now(),
  resuelto_por uuid references auth.users(id) on delete set null,
  resuelto_en  timestamptz,
  unique (profesor_id, grupo_id, fecha, turno)
);
create index if not exists cambios_fecha_idx on public.cambios(fecha);

-- Turnos de la oficina (Mañana, Tarde, Noche): disponibilidad, turnos asignados y marcación del día.
create table if not exists public.oficina_disp (
  semana_id uuid not null references public.semanas(id) on delete cascade,
  user_id   uuid not null references public.perfiles(id) on delete cascade,
  dias      jsonb not null default '{}'::jsonb,       -- {"Lun":{"Mañana":true,"Noche":true}, ...}
  enviado   boolean not null default false,
  act       timestamptz not null default now(),
  primary key (semana_id, user_id)
);
create table if not exists public.oficina_turnos (
  id           uuid primary key default gen_random_uuid(),
  fecha        date not null,
  turno        text not null check (turno in ('Mañana','Tarde','Noche')),
  user_id      uuid not null references public.perfiles(id) on delete cascade,
  estado       text not null default 'asignado' check (estado in ('asignado','pendiente','rechazado')),
  motivo       text,             -- lo pidió la persona: turno fuera de lo que le armó la dirección
  marcado_en   timestamptz,      -- marcó el turno ese día; cuenta para el pago si está asignado
  creado       timestamptz not null default now(),
  resuelto_por uuid references auth.users(id) on delete set null,
  resuelto_en  timestamptz,
  unique (fecha, turno, user_id)
);
create index if not exists oficina_turnos_fecha_idx on public.oficina_turnos(fecha);
-- Pago por turno de cada persona de la oficina: solo la dirección
create table if not exists public.oficina_montos (
  user_id     uuid primary key references public.perfiles(id) on delete cascade,
  monto_turno integer not null default 0
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

-- Fecha de hoy en Paraguay (UTC-3 todo el año desde 2024)
create or replace function public.hoy_py() returns date
language sql stable as $$ select (now() at time zone 'UTC' - interval '3 hours')::date $$;

-- Fila del plantel de quien está usando la app (null si no es profe)
create or replace function public.mi_profesor() returns uuid
language sql stable security definer set search_path = public as $$
  select pr.id from profesores pr join perfiles p on p.id = pr.user_id
  where pr.user_id = auth.uid() and pr.activo and p.activo
$$;

-- Un profe ve un grupo si tiene clases ahí en el horario o pidió un cambio en ese grupo
-- (último mes y medio / próximas 3 semanas). No hay asignación manual de grupos.
create or replace function public.da_clase(g uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from perfiles p where p.id = auth.uid() and p.activo and p.rol = 'profe')
     and (exists (select 1 from clases c join profesores pr on pr.id = c.profesor_id
                  where pr.user_id = auth.uid() and c.grupo_id = g
                    and c.fecha between public.hoy_py() - 45 and public.hoy_py() + 21)
          or exists (select 1 from cambios x join profesores pr on pr.id = x.profesor_id
                     where pr.user_id = auth.uid() and x.grupo_id = g and x.estado <> 'rechazado'
                       and x.fecha between public.hoy_py() - 45 and public.hoy_py() + 21))
$$;

-- La carga de disponibilidad abre el miércoles anterior y cierra el sábado a las 17:00 (hora de Paraguay);
-- la dirección puede reabrirla con semanas.carga_abierta_hasta.
create or replace function public.carga_abierta(s uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from semanas w where w.id = s and (
    (now() at time zone 'UTC' - interval '3 hours') between (w.lunes - 5)::timestamp and (w.lunes - 2)::timestamp + interval '17 hours'
    or (w.carga_abierta_hasta is not null and now() < w.carga_abierta_hasta)))
$$;

-- El profe llama lista (y anota la clase) solo el día de la clase y solo si esa clase es suya en el horario
-- o pidió el cambio (pendiente o aprobado).
create or replace function public.puede_llamar(g uuid, f date, t text) returns boolean
language sql stable security definer set search_path = public as $$
  select f = public.hoy_py()
     and exists (select 1 from perfiles p where p.id = auth.uid() and p.activo and p.rol = 'profe')
     and (exists (select 1 from clases c where c.grupo_id = g and c.fecha = f and c.turno = t and c.profesor_id = public.mi_profesor())
          or exists (select 1 from cambios x where x.grupo_id = g and x.fecha = f and x.turno = t
                     and x.profesor_id = public.mi_profesor() and x.estado <> 'rechazado'))
$$;

create or replace function public.es_oficina() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select rol = 'oficina' from perfiles where id = auth.uid() and activo), false)
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
  elsif exists (select 1 from profesores where lower(email) = lower(new.email) and activo) then
    r := 'profe';   -- está en el plantel: entra como profe
  end if;
  insert into perfiles (id, email, nombre, rol)
  values (new.id, lower(new.email), coalesce(new.raw_user_meta_data->>'nombre', ''), r)
  on conflict (id) do nothing;
  update alumnos set user_id = new.id where lower(email) = lower(new.email) and user_id is null;
  update profesores set user_id = new.id where lower(email) = lower(new.email) and user_id is null;
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

-- ---------- horario: clase dictada, semanas, publicación ---------------

-- Cuando un profe llama lista, la clase de ese grupo, día y turno queda dictada por él
-- (reemplaza la planilla firmada; sirve para el pago por clase). La primera lista manda.
create or replace function public.registrar_clase() returns trigger
language plpgsql security definer set search_path = public as $$
declare p uuid := public.mi_profesor();
begin
  if p is not null then
    insert into clases (grupo_id, fecha, turno, dictada_por, dictada_en)
    values (new.grupo_id, new.fecha, new.turno, p, now())
    on conflict (grupo_id, fecha, turno) do update
      set dictada_por = coalesce(clases.dictada_por, excluded.dictada_por),
          dictada_en  = coalesce(clases.dictada_en, excluded.dictada_en);
  end if;
  return new;
end $$;
drop trigger if exists asistencia_registra_clase on public.asistencia;
create trigger asistencia_registra_clase after insert or update on public.asistencia
  for each row execute function public.registrar_clase();

-- Devuelve (y si hace falta crea) la semana de ese lunes. La usan la dirección y los profes.
create or replace function public.abrir_semana(l date) returns public.semanas
language plpgsql security definer set search_path = public as $$
declare w semanas;
begin
  if not (public.es_staff() or public.mi_profesor() is not null) then raise exception 'Sin permiso'; end if;
  if extract(isodow from l) <> 1 then raise exception 'La semana tiene que empezar un lunes'; end if;
  insert into semanas (lunes) values (l) on conflict (lunes) do nothing;
  select * into w from semanas where lunes = l;
  return w;
end $$;

-- Publica el último horario armado de la semana: crea o actualiza las clases.
-- Las clases que ya tienen lista no se borran (quedan con su profe y su registro).
create or replace function public.publicar_horario(sem uuid) returns int
language plpgsql security definer set search_path = public as $$
declare w semanas; h jsonb; g record; s jsonb; f date; code text; n int := 0;
  dias text[] := array['Lun','Mar','Mié','Jue','Vie','Sáb','Dom'];
begin
  if not public.es_admin() then raise exception 'Solo la dirección publica el horario'; end if;
  select * into w from semanas where id = sem;
  if not found then raise exception 'No existe la semana'; end if;
  select data into h from horarios where semana_id = sem order by generado desc limit 1;
  if h is null then raise exception 'Todavía no se armó el horario de esta semana'; end if;
  delete from clases c where c.fecha between w.lunes and w.lunes + 6 and c.dictada_por is null
    and c.nota_profe is null and c.notas_alumnos = '{}'::jsonb
    and not exists (select 1 from asistencia a where a.grupo_id = c.grupo_id and a.fecha = c.fecha and a.turno = c.turno);
  for g in select key, value from jsonb_each(h) loop
    continue when not exists (select 1 from grupos gr where gr.id::text = g.key);
    for s in select value from jsonb_array_elements(g.value) loop
      continue when coalesce(s->>'materia', '') = '' or array_position(dias, s->>'day') is null;
      continue when (s->>'day') = any(w.feriados);
      select coalesce(gr.dias->>(s->>'day'), '-') into code from grupos gr where gr.id::text = g.key;
      continue when not ((s->>'turno' = 'Mañana' and code in ('M','MT')) or (s->>'turno' = 'Tarde' and code in ('T','MT')));
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

-- Notas de la clase y por alumno. El profe solo en sus grupos y el mismo día; la oficina cualquier día.
create or replace function public.anotar_clase(g uuid, f date, t text, nota text, notas jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare limpio jsonb := '{}'::jsonb; k text; v text;
begin
  if t not in ('Mañana', 'Tarde') then raise exception 'Turno no válido'; end if;
  if not (public.es_staff() or public.puede_llamar(g, f, t)) then
    raise exception 'Solo podés anotar en tus clases y el mismo día';
  end if;
  for k, v in select key, value from jsonb_each_text(coalesce(notas, '{}'::jsonb)) loop
    if btrim(coalesce(v, '')) <> '' and exists (select 1 from alumnos a where a.id::text = k) then
      limpio := limpio || jsonb_build_object(k, left(btrim(v), 300));
    end if;
  end loop;
  insert into clases (grupo_id, fecha, turno, nota_profe, notas_alumnos, nota_por, nota_en)
  values (g, f, t, nullif(left(btrim(coalesce(nota, '')), 1000), ''), limpio, auth.uid(), now())
  on conflict (grupo_id, fecha, turno) do update
    set nota_profe = excluded.nota_profe, notas_alumnos = excluded.notas_alumnos, nota_por = excluded.nota_por, nota_en = excluded.nota_en;
end $$;

-- Grupos activos (solo nombre y días) para que el profe elija dónde pide un cambio
create or replace function public.grupos_lista()
returns table (id uuid, nombre text, dias jsonb, orden int)
language sql stable security definer set search_path = public as $$
  select g.id, g.nombre, g.dias, g.orden from grupos g
  where g.activo and (public.es_staff() or public.mi_profesor() is not null)
  order by g.orden, g.nombre
$$;

-- Qué clase hay en ese grupo, día y turno (para el pedido de cambio)
create or replace function public.info_clase(g uuid, f date, t text)
returns table (materia text, tema text, profe text)
language sql stable security definer set search_path = public as $$
  select c.materia, c.tema, pr.nombre from clases c left join profesores pr on pr.id = c.profesor_id
  where c.grupo_id = g and c.fecha = f and c.turno = t and (public.es_staff() or public.mi_profesor() is not null)
$$;

-- El profe pide dar una clase que no está a su nombre (hoy o hasta 3 semanas adelante)
create or replace function public.pedir_cambio(g uuid, f date, t text, motivo text) returns uuid
language plpgsql security definer set search_path = public as $$
declare p uuid := public.mi_profesor(); r uuid;
begin
  if p is null or not exists (select 1 from perfiles where id = auth.uid() and activo and rol = 'profe') then
    raise exception 'Solo los profes piden cambios';
  end if;
  if t not in ('Mañana', 'Tarde') then raise exception 'Turno no válido'; end if;
  if f < public.hoy_py() or f > public.hoy_py() + 21 then raise exception 'Podés pedir cambios desde hoy hasta 3 semanas adelante'; end if;
  if not exists (select 1 from grupos where id = g and activo) then raise exception 'Grupo no válido'; end if;
  if exists (select 1 from clases where grupo_id = g and fecha = f and turno = t and profesor_id = p) then
    raise exception 'Esa clase ya está a tu nombre en el horario';
  end if;
  if exists (select 1 from cambios where profesor_id = p and grupo_id = g and fecha = f and turno = t and estado = 'rechazado') then
    raise exception 'La dirección ya rechazó ese cambio';
  end if;
  insert into cambios (profesor_id, grupo_id, fecha, turno, motivo, profe_antes)
  values (p, g, f, t, nullif(left(btrim(coalesce(motivo, '')), 300), ''),
          (select c.profesor_id from clases c where c.grupo_id = g and c.fecha = f and c.turno = t))
  on conflict (profesor_id, grupo_id, fecha, turno) do update set motivo = excluded.motivo
  returning id into r;
  return r;
end $$;

-- La dirección aprueba o rechaza. Aprobado: la clase pasa a nombre del profe que la pidió (y le cuenta para el pago).
create or replace function public.resolver_cambio(cid uuid, aprobar boolean) returns void
language plpgsql security definer set search_path = public as $$
declare x cambios;
begin
  if not public.es_admin() then raise exception 'Solo la dirección aprueba cambios'; end if;
  select * into x from cambios where id = cid for update;
  if not found then raise exception 'No existe el pedido'; end if;
  if x.profe_antes is null then
    select c.profesor_id into x.profe_antes from clases c
     where c.grupo_id = x.grupo_id and c.fecha = x.fecha and c.turno = x.turno and c.profesor_id is distinct from x.profesor_id;
  end if;
  update cambios set estado = case when aprobar then 'aprobado' else 'rechazado' end,
         resuelto_por = auth.uid(), resuelto_en = now(), profe_antes = x.profe_antes
   where id = cid;
  if aprobar then
    insert into clases (grupo_id, fecha, turno, profesor_id) values (x.grupo_id, x.fecha, x.turno, x.profesor_id)
    on conflict (grupo_id, fecha, turno) do update set profesor_id = excluded.profesor_id;
  elsif x.estado = 'aprobado' then
    -- se había aprobado y ahora se rechaza: la clase vuelve al profe del horario
    update clases set profesor_id = x.profe_antes
     where grupo_id = x.grupo_id and fecha = x.fecha and turno = x.turno and profesor_id = x.profesor_id;
  end if;
end $$;

-- Oficina: marcar el turno el mismo día (su firma)
create or replace function public.marcar_turno(tid uuid) returns timestamptz
language plpgsql security definer set search_path = public as $$
declare r timestamptz;
begin
  if not public.es_staff() then raise exception 'Sin permiso'; end if;
  update oficina_turnos set marcado_en = coalesce(marcado_en, now())
   where id = tid and user_id = auth.uid() and fecha = public.hoy_py() and estado <> 'rechazado'
  returning marcado_en into r;
  if r is null then raise exception 'Solo podés marcar tus turnos y el mismo día'; end if;
  return r;
end $$;

-- Oficina: pedir un turno que no estaba en lo que armó la dirección (hoy o hasta 3 semanas adelante)
create or replace function public.pedir_turno(f date, t text, motivo text) returns uuid
language plpgsql security definer set search_path = public as $$
declare r uuid; e text;
begin
  if not public.es_oficina() then raise exception 'Solo el personal de oficina pide turnos'; end if;
  if t not in ('Mañana', 'Tarde', 'Noche') then raise exception 'Turno no válido'; end if;
  if f < public.hoy_py() or f > public.hoy_py() + 21 then raise exception 'Podés pedir turnos desde hoy hasta 3 semanas adelante'; end if;
  select estado into e from oficina_turnos where fecha = f and turno = t and user_id = auth.uid();
  if e = 'rechazado' then raise exception 'La dirección ya rechazó ese turno'; end if;
  if e is not null then raise exception 'Ya tenés ese turno'; end if;
  insert into oficina_turnos (fecha, turno, user_id, estado, motivo)
  values (f, t, auth.uid(), 'pendiente', nullif(left(btrim(coalesce(motivo, '')), 300), ''))
  returning id into r;
  return r;
end $$;

-- Cuando un profe cambia de correo: al poner en su fila del plantel el correo con el que ya creó su cuenta,
-- la cuenta se engancha sola a esa fila (conserva puntajes) y entra como profe.
create or replace function public.vincular_cuenta_profe() returns trigger
language plpgsql security definer set search_path = public as $$
declare u uuid;
begin
  if new.user_id is null and new.email is not null then
    select au.id into u from auth.users au
     where lower(au.email) = lower(new.email)
       and not exists (select 1 from profesores p where p.user_id = au.id and p.id is distinct from new.id)
       and not exists (select 1 from perfiles pf where pf.id = au.id and pf.rol in ('admin', 'oficina'))
       and not exists (select 1 from alumnos a where a.user_id = au.id);
    if u is not null then
      new.user_id := u;
      update perfiles set rol = 'profe', activo = true where id = u;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists profesores_vincular on public.profesores;
create trigger profesores_vincular before insert or update of email on public.profesores
  for each row execute function public.vincular_cuenta_profe();

-- La dirección engancha a mano una cuenta de profe (que entró con otro correo) a su fila del plantel.
-- La fila pasa a tener el correo de la cuenta y conserva sus puntajes.
create or replace function public.vincular_profe(pid uuid, uid uuid) returns void
language plpgsql security definer set search_path = public as $$
declare e text;
begin
  if not public.es_admin() then raise exception 'Solo la dirección vincula cuentas'; end if;
  select lower(email) into e from auth.users where id = uid;
  if e is null then raise exception 'No existe esa cuenta'; end if;
  if exists (select 1 from perfiles where id = uid and rol in ('admin', 'oficina')) then raise exception 'Esa cuenta es de la dirección o de la oficina'; end if;
  if exists (select 1 from alumnos where user_id = uid) then raise exception 'Esa cuenta es de un alumno'; end if;
  if exists (select 1 from profesores where user_id = uid and id <> pid) then raise exception 'Esa cuenta ya está vinculada a otro profe'; end if;
  if exists (select 1 from profesores where lower(email) = e and id <> pid) then raise exception 'Otro profe del plantel ya tiene el correo %', e; end if;
  update profesores set user_id = uid, email = e, activo = true where id = pid;
  if not found then raise exception 'Ese profe ya no está en el plantel'; end if;
  update perfiles set rol = 'profe', activo = true where id = uid;
end $$;

-- La dirección borra un profe del plantel (ej. filas viejas de la app anterior). No deja borrar a quien ya dio
-- clases registradas (se perdería lo que hay que pagarle): a esos se los desactiva. Se borran sus puntajes,
-- disponibilidades y pedidos; las clases que tenía asignadas quedan sin profe; si tenía cuenta, pierde el acceso.
create or replace function public.borrar_profe(pid uuid) returns text
language plpgsql security definer set search_path = public as $$
declare p profesores; n int;
begin
  if not public.es_admin() then raise exception 'Solo la dirección borra profes'; end if;
  select * into p from profesores where id = pid;
  if not found then raise exception 'Ese profe ya no está en el plantel'; end if;
  if p.user_id = auth.uid() then raise exception 'No podés borrar tu propia fila'; end if;
  select count(*) into n from clases where dictada_por = pid;
  if n > 0 then
    raise exception 'Ya tiene % clase(s) dada(s) registrada(s). Desactivalo en vez de borrarlo, así no se pierde lo que hay que pagarle.', n;
  end if;
  if p.user_id is not null then update perfiles set activo = false where id = p.user_id and rol = 'profe'; end if;
  delete from profesores where id = pid;
  return case when p.user_id is not null then 'sin_acceso' else 'ok' end;
end $$;

-- La dirección aprueba o rechaza un turno pedido
create or replace function public.resolver_turno(tid uuid, aprobar boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.es_admin() then raise exception 'Solo la dirección aprueba turnos'; end if;
  update oficina_turnos set estado = case when aprobar then 'asignado' else 'rechazado' end,
         resuelto_por = auth.uid(), resuelto_en = now()
   where id = tid;
  if not found then raise exception 'No existe el turno'; end if;
end $$;

-- Horario del alumno: materia y tema de cada clase de su grupo, sin el profe
create or replace function public.mi_horario(desde date, hasta date)
returns table (fecha date, turno text, materia text, tema text)
language sql stable security definer set search_path = public as $$
  select c.fecha, c.turno, c.materia, c.tema from clases c
  where c.grupo_id = public.mi_grupo() and c.fecha between desde and hasta and coalesce(c.materia, '') <> ''
  order by c.fecha, c.turno
$$;

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
create policy grupos_escribir on public.grupos for insert to authenticated with check (public.es_staff());
drop policy if exists grupos_editar on public.grupos;
create policy grupos_editar on public.grupos for update to authenticated
  using (public.es_staff()) with check (public.es_staff());
drop policy if exists grupos_borrar on public.grupos;
create policy grupos_borrar on public.grupos for delete to authenticated using (public.es_admin());

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
-- El profe solo llama lista el mismo día y en sus clases del horario o con cambio pedido (es su firma).
-- La oficina corrige cualquier fecha.
drop policy if exists asistencia_escribir on public.asistencia;
create policy asistencia_escribir on public.asistencia for all to authenticated
  using (public.es_staff() or public.puede_llamar(grupo_id, fecha, turno))
  with check (public.es_staff() or public.puede_llamar(grupo_id, fecha, turno));

-- exámenes
drop policy if exists examenes_ver on public.examenes;
create policy examenes_ver on public.examenes for select to authenticated
  using (public.es_staff() or public.da_clase(grupo_id) or grupo_id = public.mi_grupo() or public.rendi_examen(id));
drop policy if exists examenes_escribir on public.examenes;
create policy examenes_escribir on public.examenes for insert to authenticated
  with check (public.es_staff() or public.da_clase(grupo_id));
drop policy if exists examenes_editar on public.examenes;
create policy examenes_editar on public.examenes for update to authenticated
  using (public.es_staff() or public.da_clase(grupo_id))
  with check (public.es_staff() or public.da_clase(grupo_id));
drop policy if exists examenes_borrar on public.examenes;
create policy examenes_borrar on public.examenes for delete to authenticated using (public.es_admin());

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

-- links de inscripción (solo la oficina; borrar solo la dirección; el alumno usa info_link / usar_link)
drop policy if exists links_staff on public.links_inscripcion;
create policy links_staff on public.links_inscripcion for select to authenticated using (public.es_staff());
drop policy if exists links_crear on public.links_inscripcion;
create policy links_crear on public.links_inscripcion for insert to authenticated with check (public.es_staff());
drop policy if exists links_editar on public.links_inscripcion;
create policy links_editar on public.links_inscripcion for update to authenticated
  using (public.es_staff()) with check (public.es_staff());
drop policy if exists links_borrar on public.links_inscripcion;
create policy links_borrar on public.links_inscripcion for delete to authenticated using (public.es_admin());

-- horario
alter table public.profesores          enable row level security;
alter table public.profesores_puntajes enable row level security;
alter table public.semanas             enable row level security;
alter table public.disponibilidad      enable row level security;
alter table public.materias_semana     enable row level security;
alter table public.horarios            enable row level security;
alter table public.clases              enable row level security;

-- plantel: la oficina ve nombres y teléfonos; cada profe ve su fila; solo la dirección edita
drop policy if exists profesores_ver on public.profesores;
create policy profesores_ver on public.profesores for select to authenticated
  using (public.es_staff() or user_id = auth.uid());
drop policy if exists profesores_admin on public.profesores;
create policy profesores_admin on public.profesores for all to authenticated
  using (public.es_admin()) with check (public.es_admin());
-- puntajes y monto por clase: solo la dirección
drop policy if exists puntajes_admin on public.profesores_puntajes;
create policy puntajes_admin on public.profesores_puntajes for all to authenticated
  using (public.es_admin()) with check (public.es_admin());

drop policy if exists semanas_ver on public.semanas;
create policy semanas_ver on public.semanas for select to authenticated
  using (public.es_staff() or public.mi_profesor() is not null);
drop policy if exists semanas_admin on public.semanas;
create policy semanas_admin on public.semanas for all to authenticated
  using (public.es_admin()) with check (public.es_admin());

-- disponibilidad: cada profe la suya y solo con la carga abierta; la dirección todo
drop policy if exists disp_ver on public.disponibilidad;
create policy disp_ver on public.disponibilidad for select to authenticated
  using (public.es_admin() or profesor_id = public.mi_profesor());
drop policy if exists disp_admin on public.disponibilidad;
create policy disp_admin on public.disponibilidad for all to authenticated
  using (public.es_admin()) with check (public.es_admin());
drop policy if exists disp_profe_crear on public.disponibilidad;
create policy disp_profe_crear on public.disponibilidad for insert to authenticated
  with check (profesor_id = public.mi_profesor() and public.carga_abierta(semana_id));
drop policy if exists disp_profe_editar on public.disponibilidad;
create policy disp_profe_editar on public.disponibilidad for update to authenticated
  using (profesor_id = public.mi_profesor() and public.carga_abierta(semana_id))
  with check (profesor_id = public.mi_profesor() and public.carga_abierta(semana_id));

-- materias de la semana y borradores: solo la dirección
drop policy if exists materias_admin on public.materias_semana;
create policy materias_admin on public.materias_semana for all to authenticated
  using (public.es_admin()) with check (public.es_admin());
drop policy if exists horarios_admin on public.horarios;
create policy horarios_admin on public.horarios for all to authenticated
  using (public.es_admin()) with check (public.es_admin());

-- clases publicadas: la oficina las ve; el profe ve las suyas (y las que anotó); el alumno usa mi_horario (sin el nombre del profe)
drop policy if exists clases_ver on public.clases;
create policy clases_ver on public.clases for select to authenticated
  using (public.es_staff() or nota_por = auth.uid() or (public.mi_profesor() is not null and (profesor_id = public.mi_profesor() or dictada_por = public.mi_profesor())));
drop policy if exists clases_admin on public.clases;
create policy clases_admin on public.clases for all to authenticated
  using (public.es_admin()) with check (public.es_admin());

-- pedidos de cambio: la oficina y la dirección los ven; cada profe los suyos; se crean y resuelven por RPC
alter table public.cambios        enable row level security;
alter table public.oficina_disp   enable row level security;
alter table public.oficina_turnos enable row level security;
alter table public.oficina_montos enable row level security;
drop policy if exists cambios_ver on public.cambios;
create policy cambios_ver on public.cambios for select to authenticated
  using (public.es_staff() or profesor_id = public.mi_profesor());
drop policy if exists cambios_admin on public.cambios;
create policy cambios_admin on public.cambios for all to authenticated
  using (public.es_admin()) with check (public.es_admin());

-- turnos de oficina: la oficina ve todos los turnos (para coordinarse); arma y borra solo la dirección;
-- marcar y pedir turnos va por RPC
drop policy if exists oturnos_ver on public.oficina_turnos;
create policy oturnos_ver on public.oficina_turnos for select to authenticated using (public.es_staff());
drop policy if exists oturnos_admin on public.oficina_turnos;
create policy oturnos_admin on public.oficina_turnos for all to authenticated
  using (public.es_admin()) with check (public.es_admin());
-- disponibilidad de la oficina: cada uno la suya con la carga abierta (mismo plazo que los profes)
drop policy if exists odisp_ver on public.oficina_disp;
create policy odisp_ver on public.oficina_disp for select to authenticated
  using (public.es_admin() or (user_id = auth.uid() and public.es_oficina()));
drop policy if exists odisp_admin on public.oficina_disp;
create policy odisp_admin on public.oficina_disp for all to authenticated
  using (public.es_admin()) with check (public.es_admin());
drop policy if exists odisp_crear on public.oficina_disp;
create policy odisp_crear on public.oficina_disp for insert to authenticated
  with check (user_id = auth.uid() and public.es_oficina() and public.carga_abierta(semana_id));
drop policy if exists odisp_editar on public.oficina_disp;
create policy odisp_editar on public.oficina_disp for update to authenticated
  using (user_id = auth.uid() and public.es_oficina() and public.carga_abierta(semana_id))
  with check (user_id = auth.uid() and public.es_oficina() and public.carga_abierta(semana_id));
drop policy if exists omontos_admin on public.oficina_montos;
create policy omontos_admin on public.oficina_montos for all to authenticated
  using (public.es_admin()) with check (public.es_admin());

-- ---------- permisos de tablas para el rol de la API --------------------
revoke all on all tables in schema public from anon;
grant select, insert, update, delete on public.perfiles, public.config, public.grupos, public.alumnos,
  public.pagos, public.asistencia, public.examenes, public.notas, public.profe_grupos, public.links_inscripcion,
  public.profesores, public.profesores_puntajes, public.semanas, public.disponibilidad, public.materias_semana,
  public.horarios, public.clases, public.cambios, public.oficina_disp, public.oficina_turnos, public.oficina_montos to authenticated;
revoke all on public.config_privada from authenticated;
grant usage on sequence public.recibo_seq to authenticated;
grant execute on function public.guardar_mi_ficha(jsonb), public.mis_resultados(),
  public.mi_rol(), public.es_staff(), public.es_admin(), public.da_clase(uuid), public.mi_alumno(), public.mi_grupo(),
  public.examen_de_clase(uuid), public.rendi_examen(uuid),
  public.hoy_py(), public.mi_profesor(), public.carga_abierta(uuid), public.abrir_semana(date),
  public.publicar_horario(uuid), public.mi_horario(date, date), public.anotar_clase(uuid, date, text, text, jsonb),
  public.puede_llamar(uuid, date, text), public.es_oficina(), public.grupos_lista(), public.info_clase(uuid, date, text),
  public.pedir_cambio(uuid, date, text, text), public.resolver_cambio(uuid, boolean),
  public.marcar_turno(uuid), public.pedir_turno(date, text, text), public.resolver_turno(uuid, boolean),
  public.borrar_profe(uuid), public.vincular_profe(uuid, uuid)
  to authenticated;
revoke execute on function public.guardar_mi_ficha(jsonb), public.mis_resultados(), public.usar_link(text),
  public.abrir_semana(date), public.publicar_horario(uuid), public.mi_horario(date, date), public.mi_profesor(),
  public.carga_abierta(uuid), public.anotar_clase(uuid, date, text, text, jsonb),
  public.puede_llamar(uuid, date, text), public.es_oficina(), public.grupos_lista(), public.info_clase(uuid, date, text),
  public.pedir_cambio(uuid, date, text, text), public.resolver_cambio(uuid, boolean),
  public.marcar_turno(uuid), public.pedir_turno(date, text, text), public.resolver_turno(uuid, boolean),
  public.borrar_profe(uuid), public.vincular_profe(uuid, uuid), public.vincular_cuenta_profe() from public, anon;
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

-- Profes del plantel que ya tenían cuenta: se vinculan por correo y pasan a rol profe
update public.profesores pr set user_id = u.id
  from auth.users u where lower(u.email) = lower(pr.email) and pr.user_id is null;
update public.perfiles p set rol = 'profe'
  from public.profesores pr where pr.user_id = p.id and pr.activo and p.rol = 'alumno';
