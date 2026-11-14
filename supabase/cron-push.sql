-- Avisos programados por notificación. Se corre una vez en Supabase → SQL Editor (se puede volver a correr).
-- Llama a la función "push" cada 15 minutos; la función decide si toca mandar algo según los horarios de Ajustes
-- (recordatorio de la noche, de la mañana y de disponibilidad) y cada aviso sale una sola vez por día.
-- No lleva claves: la función se despliega con "Verify JWT" apagado.
create extension if not exists pg_cron;
create extension if not exists pg_net;

do $$ begin perform cron.unschedule('vibe-push'); exception when others then null; end $$;

select cron.schedule('vibe-push', '*/15 * * * *', $job$
  select net.http_post(
    url := 'https://dverryhnnvdydefbvzki.supabase.co/functions/v1/push',
    headers := '{"Content-Type": "application/json"}'::jsonb,
    body := '{"tipo": "auto"}'::jsonb,
    timeout_milliseconds := 30000
  );
$job$);

select jobname, schedule, active from cron.job order by jobname;
