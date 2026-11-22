-- Avisos al celular para que los profes marquen su clase:
--   al empezar (8:00 / 13:30): "Empieza tu clase… marcá tu entrada" (solo si todavía no la marcó)
--   al terminar (12:00 / 17:30): "Terminó tu clase… marcá tu salida" (solo si no la marcó; si tampoco marcó la entrada, se lo dice)
-- Les llega a quien da la clase: el profe del horario, o el que pidió el cambio (si no se lo rechazaron).
-- Se activan o apagan en Ajustes → Avisos al celular (config.general.push.prEntrada / prSalida; vienen activados).
-- Lo usa la función "push" (modo auto, cada 15 minutos) con la clave de servicio.
create or replace function public.push_marcar(tipo text, f date)
returns table (endpoint text, keys jsonb, titulo text, cuerpo text)
language plpgsql stable security definer set search_path = public as $$
declare cfg jsonb; t text; ent boolean;
begin
  if tipo not in ('entrada_m', 'entrada_t', 'salida_m', 'salida_t') then raise exception 'Tipo de aviso no válido'; end if;
  ent := tipo like 'entrada%';
  t := case when right(tipo, 1) = 'm' then 'Mañana' else 'Tarde' end;
  select coalesce(c.valor -> 'push', '{}'::jsonb) into cfg from config c where c.clave = 'general';
  if not coalesce((coalesce(cfg, '{}'::jsonb) ->> (case when ent then 'prEntrada' else 'prSalida' end))::boolean, true) then return; end if;
  return query
  with cl as (
    select c.materia, c.tema, g.nombre as grupo, g.orden,
      coalesce((select x.profesor_id from cambios x
                 where x.grupo_id = c.grupo_id and x.fecha = c.fecha and x.turno = c.turno and x.estado <> 'rechazado'
                 order by x.estado = 'aprobado' desc, x.creado desc limit 1), c.profesor_id) as prof
    from clases c join grupos g on g.id = c.grupo_id and g.activo
    where c.fecha = f and c.turno = t and coalesce(c.materia, '') not in ('', 'examen')),
  pr as (
    select p.user_id,
      string_agg(public.mat_nombre(cl.materia) || coalesce(' (' || nullif(btrim(cl.tema), '') || ')', '') || ' en ' || cl.grupo, ' · '
                 order by cl.orden, cl.grupo) as txt
    from cl join profesores p on p.id = cl.prof and p.activo and p.user_id is not null
    group by p.user_id),
  pm as (
    select pr.user_id, pr.txt, m.entrada, m.salida
    from pr left join marcaciones m on m.user_id = pr.user_id and m.fecha = f and m.turno = t)
  select s.endpoint, s.keys,
    case when ent then 'Empieza tu clase ⏰'
         when pm.entrada is null then 'Te faltó marcar tu clase ✋'
         else 'Terminó tu clase ✅' end,
    case when ent then pm.txt || ', ' || (case when t = 'Mañana' then '8:00' else '13:30' end)
                       || '. No te olvides de marcar tu entrada en la app y de llamar lista.'
         when pm.entrada is null then pm.txt || ': no marcaste la entrada ni la salida. Cargalas en la app, en “Tus entradas y salidas”.'
         else pm.txt || '. No te olvides de marcar tu salida en la app.' end
  from pm join push_subs s on s.user_id = pm.user_id
  where (ent and pm.entrada is null) or (not ent and pm.salida is null);
end $$;
revoke all on function public.push_marcar(text, date) from public, anon, authenticated;
grant execute on function public.push_marcar(text, date) to service_role;
