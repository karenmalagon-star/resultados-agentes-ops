-- ============================================================================
-- Módulo de Variables · 007 · Detalle de órdenes gestionadas por agente (el "ojo" del Resumen) + celular del cliente
-- events_history guarda orden, tipo, fecha, media hora, motivo y tienda, pero NO el teléfono; orders_cache se purga a ~5 días.
-- Se crea una tabla permanente de contacto por orden que sync-refresh alimenta en cada corrida.
-- ============================================================================
create table if not exists public.orders_contact (
  order_id    bigint primary key,
  phone       text,
  client_name text,
  store       text,
  updated_at  timestamptz not null default now()
);
alter table public.orders_contact enable row level security;

-- Órdenes gestionadas por un agente en un rango de fechas (por alias, mismas exclusiones del resumen).
create or replace function public.var_ordenes_agente(p_agent_id text, p_desde date, p_hasta date) returns jsonb
language sql stable set search_path = public, pg_temp as $$
  with ev as (
    select e.order_id, e.type, e.ev_date, e.halfhour, e.reason, e.store
    from events_history e
    join var_agente_alias al on al.nombre_norm = var_norm(e.agent) and e.ev_date >= al.desde and (al.hasta is null or e.ev_date <= al.hasta)
    where al.agent_id = p_agent_id and e.ev_date between p_desde and p_hasta and not var_es_excluido(e.agent)
  )
  select jsonb_build_object(
    'agent_id', p_agent_id, 'desde', p_desde, 'hasta', p_hasta,
    'total', (select count(*) from ev), 'conf', (select count(*) from ev where type = 0), 'canc', (select count(*) from ev where type = 1), 'reprog', (select count(*) from ev where type = 2),
    'ordenes', coalesce((select jsonb_agg(jsonb_build_object(
        'orden', v.order_id,
        'celular', nullif(regexp_replace(coalesce(c.phone, ''), '\s', '', 'g'), ''),   -- sin espacios, para copiar fácil (pedido de Daniel)
        'tipo', case v.type when 0 then 'Confirmada' when 1 then 'Cancelada' else 'Reprogramada' end,
        'fecha', v.ev_date,
        'hora', lpad((v.halfhour / 2)::text, 2, '0') || ':' || case when v.halfhour % 2 = 1 then '30' else '00' end,
        'motivo', case when v.type = 1 then coalesce(v.reason, '(sin motivo)') else null end,
        'tienda', coalesce(c.store, v.store)
      ) order by v.ev_date desc, v.halfhour desc, v.order_id desc)
      from ev v left join orders_contact c on c.order_id = v.order_id), '[]'::jsonb)
  )
$$;
