-- Tareas programadas (pg_cron + pg_net) del dashboard "Resultados Agentes Ops".
-- Patron (desde 2026-08-26):
--   * cada llamada HTTP queda registrada en public.cron_calls con el nombre de su
--     funcion, para que las alertas puedan decir QUE fallo (net._http_response no
--     guarda la URL);
--   * la write_key se lee de app_config EN TIEMPO DE EJECUCION (subselect), de modo
--     que NO queda embebida en texto plano dentro de cron.job.
-- Los dos crons de SQL puro (events-history-append, cohort-history-append) no cambian.

select cron.schedule('sync-refresh-30m', '0,30 * * * *', $cmd$
  insert into public.cron_calls(req_id, fn)
  select net.http_post(
    url := 'https://sbiyedqpqtiqvlgentci.supabase.co/functions/v1/sync-refresh',
    headers := jsonb_build_object('Content-Type','application/json',
               'x-write-key', (select value from app_config where key='write_key')),
    body := '{}'::jsonb, timeout_milliseconds := 120000), 'sync-refresh';
$cmd$);

select cron.schedule('sync-panels-hourly', '10 * * * *', $cmd$
  insert into public.cron_calls(req_id, fn)
  select net.http_post(
    url := 'https://sbiyedqpqtiqvlgentci.supabase.co/functions/v1/sync-panels',
    headers := jsonb_build_object('Content-Type','application/json',
               'x-write-key', (select value from app_config where key='write_key')),
    body := '{}'::jsonb, timeout_milliseconds := 120000), 'sync-panels';
$cmd$);

select cron.schedule('sync-cohort-daily', '0 12 * * *', $cmd$
  insert into public.cron_calls(req_id, fn)
  select net.http_post(
    url := 'https://sbiyedqpqtiqvlgentci.supabase.co/functions/v1/sync-cohort',
    headers := jsonb_build_object('Content-Type','application/json',
               'x-write-key', (select value from app_config where key='write_key')),
    body := '{}'::jsonb, timeout_milliseconds := 150000), 'sync-cohort';
$cmd$);

select cron.schedule('sync-capacity-daily', '0 13 * * *', $cmd$
  insert into public.cron_calls(req_id, fn)
  select net.http_post(
    url := 'https://sbiyedqpqtiqvlgentci.supabase.co/functions/v1/sync-capacity',
    headers := jsonb_build_object('Content-Type','application/json',
               'x-write-key', (select value from app_config where key='write_key')),
    body := '{}'::jsonb, timeout_milliseconds := 120000), 'sync-capacity';
$cmd$);

select cron.schedule('build-history-hourly', '10,40 * * * *', $cmd$
  insert into public.cron_calls(req_id, fn)
  select net.http_post(
    url := 'https://sbiyedqpqtiqvlgentci.supabase.co/functions/v1/build-history',
    headers := jsonb_build_object('Content-Type','application/json',
               'x-write-key', (select value from app_config where key='write_key')),
    body := '{}'::jsonb, timeout_milliseconds := 120000), 'build-history';
$cmd$);

select cron.schedule('monitor-salud-30m', '15,45 * * * *', $cmd$
  delete from public.cron_calls where at < now() - interval '7 days';
  insert into public.cron_calls(req_id, fn)
  select net.http_post(
    url := 'https://sbiyedqpqtiqvlgentci.supabase.co/functions/v1/monitor-salud',
    headers := jsonb_build_object('Content-Type','application/json',
               'x-write-key', (select value from app_config where key='write_key')),
    body := '{}'::jsonb, timeout_milliseconds := 60000), 'monitor-salud';
$cmd$);

-- Crons de SQL puro (sin cambios; los crea/mantiene el proyecto original):
--   events-history-append  '5,35 * * * *'  -> inserta en events_history
--   cohort-history-append  '30 12 * * *'   -> inserta en cohort_history

-- Muestreo de presencia de agentes cada 5 min (gate horario 6:00-22:00 dentro de la funcion)
select cron.schedule('sync-presence-5m', '*/5 * * * *', $cmd$
  insert into public.cron_calls(req_id, fn)
  select net.http_post(
    url := 'https://sbiyedqpqtiqvlgentci.supabase.co/functions/v1/sync-presence',
    headers := jsonb_build_object('Content-Type','application/json',
               'x-write-key', (select value from app_config where key='write_key')),
    body := '{}'::jsonb, timeout_milliseconds := 90000), 'sync-presence';
$cmd$);
