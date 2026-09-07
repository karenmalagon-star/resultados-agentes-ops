-- ============================================================================
-- Módulo de Variables · 008 · Detalle por tienda para las pestañas Efectividad / Cancelación / Gestiones
-- Una fila por agente × tienda con enteros (gestiones, confirmadas, canceladas, reprogramadas) en un rango de fechas.
-- El "ojo" por tienda reutiliza var_ordenes_agente con filtro opcional de tienda.
-- ============================================================================
create or replace function public.var_tiendas_agentes(p_desde date, p_hasta date) returns jsonb
language sql stable set search_path = public, pg_temp as $$
  with ev as (
    select al.agent_id, coalesce(e.store, '(sin tienda)') tienda, e.type
    from events_history e
    join var_agente_alias al on al.nombre_norm = var_norm(e.agent) and e.ev_date >= al.desde and (al.hasta is null or e.ev_date <= al.hasta)
    where e.ev_date between p_desde and p_hasta and not var_es_excluido(e.agent)
  ),
  t as (select agent_id, tienda, count(*)::int gest, count(*) filter (where type = 0)::int conf, count(*) filter (where type = 1)::int canc, count(*) filter (where type = 2)::int reprog
        from ev group by 1, 2),
  ag as (select agent_id, sum(gest)::int gest, sum(conf)::int conf, sum(canc)::int canc, sum(reprog)::int reprog from t group by 1)
  select jsonb_build_object('desde', p_desde, 'hasta', p_hasta,
    'agentes', coalesce((select jsonb_agg(jsonb_build_object('agent_id', g.agent_id, 'nombre', g.nombre,
        'total', jsonb_build_object('gest', coalesce(a.gest,0), 'conf', coalesce(a.conf,0), 'canc', coalesce(a.canc,0), 'reprog', coalesce(a.reprog,0)),
        'tiendas', coalesce((select jsonb_agg(jsonb_build_object('tienda', x.tienda, 'gest', x.gest, 'conf', x.conf, 'canc', x.canc, 'reprog', x.reprog) order by x.gest desc, x.tienda)
                             from t x where x.agent_id = g.agent_id), '[]'::jsonb)) order by g.nombre)
      from var_agente g left join ag a on a.agent_id = g.agent_id
      where g.activo or a.agent_id is not null), '[]'::jsonb))
$$;

-- var_ordenes_agente con filtro opcional de tienda (el ojo por tienda).
drop function if exists public.var_ordenes_agente(text, date, date);
create or replace function public.var_ordenes_agente(p_agent_id text, p_desde date, p_hasta date, p_tienda text default null) returns jsonb
language sql stable set search_path = public, pg_temp as $$
  with ev as (
    select e.order_id, e.type, e.ev_date, e.halfhour, e.reason, e.store
    from events_history e
    join var_agente_alias al on al.nombre_norm = var_norm(e.agent) and e.ev_date >= al.desde and (al.hasta is null or e.ev_date <= al.hasta)
    where al.agent_id = p_agent_id and e.ev_date between p_desde and p_hasta and not var_es_excluido(e.agent)
      and (p_tienda is null or coalesce(e.store, '(sin tienda)') = p_tienda)
  )
  select jsonb_build_object(
    'agent_id', p_agent_id, 'desde', p_desde, 'hasta', p_hasta, 'tienda', p_tienda,
    'total', (select count(*) from ev), 'conf', (select count(*) from ev where type = 0), 'canc', (select count(*) from ev where type = 1), 'reprog', (select count(*) from ev where type = 2),
    'ordenes', coalesce((select jsonb_agg(jsonb_build_object(
        'orden', v.order_id,
        'celular', nullif(regexp_replace(coalesce(c.phone, ''), '\s', '', 'g'), ''),
        'tipo', case v.type when 0 then 'Confirmada' when 1 then 'Cancelada' else 'Reprogramada' end,
        'fecha', v.ev_date,
        'hora', lpad((v.halfhour / 2)::text, 2, '0') || ':' || case when v.halfhour % 2 = 1 then '30' else '00' end,
        'motivo', case when v.type = 1 then coalesce(v.reason, '(sin motivo)') else null end,
        'tienda', coalesce(c.store, v.store)
      ) order by v.ev_date desc, v.halfhour desc, v.order_id desc)
      from ev v left join orders_contact c on c.order_id = v.order_id), '[]'::jsonb)
  )
$$;
