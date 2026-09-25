-- Módulo de Variables · 017/018 · Candidatas para consultar estado en Dropi (input 27: sin tope de tiempo para el desenlace)
--  · Órdenes con gestión aceptada en los últimos 180 días sin estado final; diario los primeros 14 días, semanal después.
--  · Excluye lo consultado hoy (Colombia) y no encola mientras haya una tanda pendiente: tandas de 1.000 (tope de PostgREST) varias veces al día.
create or replace function public.nov_candidatas_estado(p_dias int default 14, p_max int default 1000, p_dias_max int default 180)
returns table (order_id text, country text, store_name text) language sql stable set search_path = public, pg_temp as $$
  with g as (
    select distinct on (order_id) order_id, store_name, created_at from nov_gestiones
    where resolved_in_dropi and created_at >= now() - make_interval(days => p_dias_max)
    order by order_id, created_at desc
  ), c as (
    select g.order_id, coalesce(n.country, var_pais_iso(split_part(g.store_name, ' ', -1))) as country, g.store_name, g.created_at,
           e.final, e.checked_at
    from g left join nov_novedades n on n.order_id = g.order_id
    left join nov_orden_estado e on e.order_id = g.order_id and e.country = coalesce(n.country, var_pais_iso(split_part(g.store_name, ' ', -1)))
  ), hoy as (select (date_trunc('day', now() at time zone 'America/Bogota') at time zone 'America/Bogota') as t0)
  select order_id, country, store_name from c, hoy
  where country is not null and coalesce(final, false) = false
    and (checked_at is null or checked_at < hoy.t0)
    and (checked_at is null or created_at >= now() - make_interval(days => p_dias) or checked_at < now() - interval '7 days')
    and not exists (select 1 from nov_estado_jobs j where j.status = 'pending')
  order by (checked_at is null) desc, created_at desc limit p_max;
$$;
revoke all on function public.nov_candidatas_estado(int, int, int) from public, anon, authenticated;
drop function if exists public.nov_candidatas_estado(int, int);
