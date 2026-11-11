-- ============================================================================
-- 032 · Incidente del 10-nov-2026: todas las copias automáticas se detuvieron tras un reinicio de la base
--  Causa: al reiniciarse Postgres (10-nov 10:35 Col), pg_net reinicia en 1 la numeración de sus peticiones. Cada cron hace
--  `insert into cron_calls(req_id, fn) select net.http_post(...)` y cron_calls tenía PRIMARY KEY (req_id): los ids nuevos
--  chocaban con los de los últimos 7 días (la base ya se había reiniciado el 7-nov), el insert fallaba y, por ir en la misma
--  transacción, la petición HTTP nunca salía. El monitor de salud cayó igual (usa el mismo mecanismo), por eso no hubo alerta.
--  Corrección: cron_calls deja de exigir req_id único (es una bitácora); el monitor asocia cada respuesta con la llamada más
--  reciente de ese id.
-- ============================================================================
alter table public.cron_calls drop constraint if exists cron_calls_pkey;
create index if not exists cron_calls_req_at_idx on public.cron_calls (req_id, at desc);

do $do$
declare d text; viejo text := 'left join public.cron_calls cc on cc.req_id = h.id';
begin
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'monitor_checks';
  if position(viejo in d) = 0 then raise exception 'fragmento de monitor_checks no encontrado'; end if;
  d := replace(d, viejo, 'left join lateral (select c.fn from public.cron_calls c where c.req_id = h.id and c.at between h.created - interval ''15 minutes'' and h.created + interval ''1 minute'' order by c.at desc limit 1) cc on true');
  execute d;
end $do$;
