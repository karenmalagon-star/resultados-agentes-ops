-- ============================================================================
-- Módulo de Variables · 022 · Reporte Admin "Novedades sin gestión" con el universo completo (D-030, aprobado 25-sep-2026)
--  La IA actúa ANTES de que la novedad llegue a la app del equipo (SGN): lo que resuelve casi nunca entra a esa lista.
--  Se agrega el bloque `universo`: resueltas por la IA antes de llegar al equipo (api_ok sin fila previa en SGN) + las que llegaron al equipo (nueva/reaparece);
--  y `por_dia` trae las dos columnas nuevas. El bloque de cerradas (con humano / IA / sin gestión) no cambia.
-- ============================================================================
create index if not exists nov_ia_gestiones_ok_idx on public.nov_ia_gestiones (revisado_at) where trigger_evento = 'api_ok';
create index if not exists nov_eventos_llegan_idx on public.nov_eventos (detectado_en) where evento in ('nueva', 'reaparece');

create or replace function public.nov_sin_gestion(p_desde date, p_hasta date) returns jsonb language sql stable set search_path = public, pg_temp as $$
  with c as (
    select e.order_id, e.country, e.store_name, (e.detectado_en at time zone 'America/Bogota')::date as fecha_cierre, e.detectado_en, e.tipo_novedad,
           coalesce((select max(x.detectado_en) from nov_eventos x where x.order_id = e.order_id and x.evento = 'cerrada' and x.detectado_en < e.detectado_en), '-infinity'::timestamptz) as desde_ev
    from nov_eventos e where e.evento = 'cerrada'
      and e.detectado_en >= p_desde::timestamp at time zone 'America/Bogota' and e.detectado_en < (p_hasta + 1)::timestamp at time zone 'America/Bogota'
  ), x as (
    select c.*,
      exists (select 1 from nov_gestiones g where g.order_id = c.order_id and g.created_at > c.desde_ev and g.created_at <= c.detectado_en) as humano,
      exists (select 1 from nov_ia_gestiones i where i.order_id = c.order_id and i.trigger_evento = 'api_ok' and i.revisado_at > c.desde_ev and i.revisado_at <= c.detectado_en) as ia
    from c
  ),
  -- universo: resueltas por la IA antes de llegar al equipo (sin fila en SGN al momento de la solución) y las que llegaron al equipo
  u_ia as (
    select i.order_id, min((i.revisado_at at time zone 'America/Bogota')::date) as f
    from nov_ia_gestiones i
    where i.trigger_evento = 'api_ok'
      and i.revisado_at >= p_desde::timestamp at time zone 'America/Bogota' and i.revisado_at < (p_hasta + 1)::timestamp at time zone 'America/Bogota'
      and not exists (select 1 from nov_novedades n where n.order_id = i.order_id and n.first_synced_at <= i.revisado_at)
    group by 1
  ),
  u_eq as (
    select e.order_id, min((e.detectado_en at time zone 'America/Bogota')::date) as f
    from nov_eventos e
    where e.evento in ('nueva', 'reaparece')
      and e.detectado_en >= p_desde::timestamp at time zone 'America/Bogota' and e.detectado_en < (p_hasta + 1)::timestamp at time zone 'America/Bogota'
    group by 1
  ),
  pd as (
    select coalesce(a.f, b.f, k.f) as f, coalesce(a.ia, 0) as ia_fuera, coalesce(b.lleg, 0) as llegaron, coalesce(k.n, 0) as cerradas, coalesce(k.s, 0) as sin_gestion
    from (select f, count(*) ia from u_ia group by 1) a
    full join (select f, count(*) lleg from u_eq group by 1) b on b.f = a.f
    full join (select fecha_cierre f, count(*) n, count(*) filter (where not humano and not ia) s from x group by 1) k on k.f = coalesce(a.f, b.f)
  )
  select jsonb_build_object(
    'desde', p_desde, 'hasta', p_hasta,
    'universo', jsonb_build_object('ia_fuera', (select count(*) from u_ia), 'llegaron', (select count(*) from u_eq), 'total', (select count(*) from u_ia) + (select count(*) from u_eq)),
    'total_cerradas', (select count(*) from x), 'con_humano', (select count(*) from x where humano), 'con_ia', (select count(*) from x where ia and not humano),
    'sin_gestion', (select count(*) from x where not humano and not ia),
    'por_dia', coalesce((select jsonb_agg(jsonb_build_object('fecha', f, 'ia_fuera', ia_fuera, 'llegaron', llegaron, 'cerradas', cerradas, 'sin_gestion', sin_gestion) order by f) from pd), '[]'::jsonb),
    'por_tienda', coalesce((select jsonb_agg(jsonb_build_object('pais', country, 'tienda', store_name, 'sin_gestion', s, 'cerradas', n) order by s desc, n desc) from (select country, store_name, count(*) n, count(*) filter (where not humano and not ia) s from x group by 1, 2 having count(*) filter (where not humano and not ia) > 0) t), '[]'::jsonb),
    'ordenes', coalesce((select jsonb_agg(jsonb_build_object('orden', order_id, 'pais', country, 'tienda', store_name, 'tipo', tipo_novedad, 'cerrada', fecha_cierre) order by detectado_en desc) from (select * from x where not humano and not ia order by detectado_en desc limit 500) o), '[]'::jsonb)
  );
$$;
revoke all on function public.nov_sin_gestion(date, date) from public, anon, authenticated;
