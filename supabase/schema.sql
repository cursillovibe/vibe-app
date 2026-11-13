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

-- Un profe ve un grupo si lo tiene asignado o si tiene clases ahí en el horario (último mes y medio / próximas 3 semanas)
create or replace function public.da_clase(g uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from perfiles p where p.id = auth.uid() and p.activo and p.rol = 'profe')
     and (exists (select 1 from profe_grupos pg where pg.profe_id = auth.uid() and pg.grupo_id = g)
          or exists (select 1 from clases c join profesores pr on pr.id = c.profesor_id
                     where pr.user_id = auth.uid() and c.grupo_id = g
                       and c.fecha between public.hoy_py() - 45 and public.hoy_py() + 21))
$$;

-- La carga de disponibilidad abre el miércoles anterior y cierra el sábado a las 17:00 (hora de Paraguay);
-- la dirección puede reabrirla con semanas.carga_abierta_hasta.
create or replace function public.carga_abierta(s uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from semanas w where w.id = s and (
    (now() at time zone 'UTC' - interval '3 hours') between (w.lunes - 5)::timestamp and (w.lunes - 2)::timestamp + interval '17 hours'
    or (w.carga_abierta_hasta is not null and now() < w.carga_abierta_hasta)))
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
  update semanas set publicada = now() where id = sem;
  return n;
end $$;

-- Notas de la clase y por alumno. El profe solo en sus grupos y el mismo día; la oficina cualquier día.
create or replace function public.anotar_clase(g uuid, f date, t text, nota text, notas jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare limpio jsonb := '{}'::jsonb; k text; v text;
begin
  if not (public.es_staff() or (public.da_clase(g) and f = public.hoy_py())) then
    raise exception 'Solo podés anotar en tus clases y el mismo día';
  end if;
  if t not in ('Mañana', 'Tarde') then raise exception 'Turno no válido'; end if;
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
-- El profe solo llama lista el mismo día de la clase (es su firma). La oficina corrige cualquier fecha.
drop policy if exists asistencia_escribir on public.asistencia;
create policy asistencia_escribir on public.asistencia for all to authenticated
  using (public.es_staff() or (public.da_clase(grupo_id) and fecha = public.hoy_py()))
  with check (public.es_staff() or (public.da_clase(grupo_id) and fecha = public.hoy_py()));

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

-- ---------- permisos de tablas para el rol de la API --------------------
revoke all on all tables in schema public from anon;
grant select, insert, update, delete on public.perfiles, public.config, public.grupos, public.alumnos,
  public.pagos, public.asistencia, public.examenes, public.notas, public.profe_grupos, public.links_inscripcion,
  public.profesores, public.profesores_puntajes, public.semanas, public.disponibilidad, public.materias_semana,
  public.horarios, public.clases to authenticated;
revoke all on public.config_privada from authenticated;
grant usage on sequence public.recibo_seq to authenticated;
grant execute on function public.guardar_mi_ficha(jsonb), public.mis_resultados(),
  public.mi_rol(), public.es_staff(), public.es_admin(), public.da_clase(uuid), public.mi_alumno(), public.mi_grupo(),
  public.examen_de_clase(uuid), public.rendi_examen(uuid),
  public.hoy_py(), public.mi_profesor(), public.carga_abierta(uuid), public.abrir_semana(date),
  public.publicar_horario(uuid), public.mi_horario(date, date), public.anotar_clase(uuid, date, text, text, jsonb)
  to authenticated;
revoke execute on function public.guardar_mi_ficha(jsonb), public.mis_resultados(), public.usar_link(text),
  public.abrir_semana(date), public.publicar_horario(uuid), public.mi_horario(date, date), public.mi_profesor(),
  public.carga_abierta(uuid), public.anotar_clase(uuid, date, text, text, jsonb) from anon;
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
