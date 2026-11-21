-- =====================================================================
--  Examen común a varios grupos (21/11/2026)
--  Cada grupo sigue teniendo su fila en "examenes" (con los mismos permisos de siempre: cada profe ve y carga
--  solo sus grupos). Las filas del mismo examen comparten "comun", y así la app carga las notas grupo por grupo
--  y muestra / exporta la lista completa de todos los que lo rindieron.
--  Se puede volver a correr. También está al final de schema.sql.
-- =====================================================================
alter table public.examenes add column if not exists comun uuid;
create index if not exists examenes_comun_idx on public.examenes(comun) where comun is not null;
