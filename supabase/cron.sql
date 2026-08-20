-- ============================================================================
-- Tareas programadas (pg_cron) del proyecto "Resultados Agentes Ops".
-- Recrean el pipeline automatico. Reemplaza <WRITE_KEY> por el valor real que
-- esta en la tabla app_config (key='write_key'). NO subas la write_key al repo.
-- Horarios en UTC (Colombia = UTC-5).
-- ============================================================================

-- sync-refresh: snapshot de Resultados (cada 30 min)
select cron.schedule('sync-refresh-30m', '0,30 * * * *', $$
  select net.http_post(
    url := 'https://sbiyedqpqtiqvlgentci.supabase.co/functions/v1/sync-refresh',
    headers := jsonb_build_object('Content-Type','application/json','x-write-key','<WRITE_KEY>'),
    body := '{}'::jsonb, timeout_milliseconds := 150000);
$$);

-- sync-panels: panel Lider (cada hora al minuto 10)
select cron.schedule('sync-panels-hourly', '10 * * * *', $$
  select net.http_post(
    url := 'https://sbiyedqpqtiqvlgentci.supabase.co/functions/v1/sync-panels',
    headers := jsonb_build_object('Content-Type','application/json','x-write-key','<WRITE_KEY>'),
    body := '{}'::jsonb, timeout_milliseconds := 150000);
$$);

-- sync-cohort: panel Cierre (diario 12:00 UTC / 07:00 CO)
select cron.schedule('sync-cohort-daily', '0 12 * * *', $$
  select net.http_post(
    url := 'https://sbiyedqpqtiqvlgentci.supabase.co/functions/v1/sync-cohort',
    headers := jsonb_build_object('Content-Type','application/json','x-write-key','<WRITE_KEY>'),
    body := '{}'::jsonb, timeout_milliseconds := 150000);
$$);

-- sync-capacity: capacidad operativa (diario 13:00 UTC / 08:00 CO)
select cron.schedule('sync-capacity-daily', '0 13 * * *', $$
  select net.http_post(
    url := 'https://sbiyedqpqtiqvlgentci.supabase.co/functions/v1/sync-capacity',
    headers := jsonb_build_object('Content-Type','application/json','x-write-key','<WRITE_KEY>'),
    body := '{}'::jsonb, timeout_milliseconds := 60000);
$$);

-- build-history: arma histD (Resultados) y cohortH (Cierre) con periodo completo (cada 30 min)
select cron.schedule('build-history-hourly', '10,40 * * * *', $$
  select net.http_post(
    url := 'https://sbiyedqpqtiqvlgentci.supabase.co/functions/v1/build-history',
    headers := jsonb_build_object('Content-Type','application/json','x-write-key','<WRITE_KEY>'),
    body := '{}'::jsonb, timeout_milliseconds := 120000);
$$);

-- events-history-append: acumula la historia permanente de eventos (cada 30 min, min 5 y 35)
select cron.schedule('events-history-append', '5,35 * * * *', $$
  insert into public.events_history(order_id, type, agent, store, country, ev_date, halfhour, reason)
  select (e->>7)::bigint,(e->>5)::smallint,
   (s.data->'agents'->>((e->>0)::int)),(s.data->'stores'->>((e->>1)::int)),(s.data->'countries'->>((e->>2)::int)),
   ((s.data->'dates'->>((e->>3)::int)))::date,(e->>4)::smallint,
   case when (e->>6)::int>=0 then (s.data->'reasons'->>((e->>6)::int)) else null end
  from (select data from public.snapshot order by created_at desc limit 1) s, jsonb_array_elements(s.data->'events') e
  where (e->>7) is not null
  on conflict (order_id,type,ev_date,halfhour) do nothing;
$$);

-- cohort-history-append: acumula la historia permanente del cierre (diario 12:30 UTC)
select cron.schedule('cohort-history-append', '30 12 * * *', $$
  with g as (
    select (d->>'dc')::date dc, d as general
    from public.panel_data, jsonb_array_elements(data->'general') d where key='cohort'
  ),
  s as (
    select (day->>'dc')::date dc, jsonb_agg(jsonb_build_object('store', st->>'store','byDay', jsonb_build_array(day))) by_store
    from public.panel_data, jsonb_array_elements(data->'byStore') st, jsonb_array_elements(st->'byDay') day
    where key='cohort' group by 1
  )
  insert into public.cohort_history(dc, general, by_store, updated_at)
  select coalesce(g.dc,s.dc), g.general, coalesce(s.by_store,'[]'::jsonb), now()
  from g full join s on g.dc=s.dc
  on conflict (dc) do update set general=excluded.general, by_store=excluded.by_store, updated_at=now();
$$);
