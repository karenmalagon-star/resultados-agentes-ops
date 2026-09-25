-- ============================================================================
-- Módulo de Variables · 019 · Novedades, etapa 2: medición (D-024/D-027, reglamento v1.8)
--  · var_agente.correo + var_nov_puente(): enlace SGN→Variables por correo (o por nombre normalizado como respaldo).
--  · var_config_default: el cargo Novedades trae sus metas (Solución 55 %, Gestión Ácida 20 % provisional, Gestiones/hora 33, Puntualidad).
--    Sigue con medible=false y liquida_fuera=true: el motor de dinero NO cambia (lo salta explícitamente); la integración al pago es la etapa 3.
--  · var_novedades_mes(): Real·Meta·Cumpl. por agente-día con cargo del día "Novedades" y acumulado del mes:
--      Solución      = órdenes con solución aceptada por Dropi (no devolución) ÷ órdenes gestionadas · más es mejor
--      Gestión Ácida = órdenes con solución del agente que DESPUÉS volvieron a novedad o terminaron en DEVOLUCION (estado final) ÷ intentos válidos · menos es mejor
--                      · intentos válidos = intentos menos las devoluciones con motivo del catálogo de 15 exclusiones y menos las órdenes en estado excluido (destrucción, siniestro)
--                      · sin tope de tiempo; la reincidencia sale del historial de Dropi (NOVEDAD con fecha posterior a la gestión)
--      Gestiones/h   = intentos ÷ horas efectivas del turno asignado (hoy: horas transcurridas) · todo o nada sobre el mes
--      Pendientes de cierre = órdenes con solución del agente que aún no tienen estado final en Dropi (informativo: "qué hay pendiente por cierre")
--  · nov_sin_gestion(): reporte Admin de novedades cerradas sin gestión humana ni de la IA (IA resolvió = trigger 'api_ok').
-- ============================================================================
alter table public.var_agente add column if not exists correo text;
create unique index if not exists var_agente_correo_idx on public.var_agente (lower(correo)) where correo is not null;

create or replace function public.var_nov_puente() returns int language plpgsql set search_path = public, pg_temp as $fn$
declare n int := 0; m int := 0;
begin
  update nov_profiles p set agent_id = a.agent_id from var_agente a
    where p.email is not null and a.correo is not null and lower(p.email) = lower(a.correo) and p.agent_id is distinct from a.agent_id;
  get diagnostics n = row_count;
  update nov_profiles p set agent_id = al.agent_id from var_agente_alias al
    where p.agent_id is null and al.nombre_norm = var_norm(p.full_name)
      and not exists (select 1 from nov_profiles q where q.agent_id = al.agent_id and q.id <> p.id and q.active);   -- no duplicar el enlace
  get diagnostics m = row_count;
  return n + m;
end $fn$;
revoke all on function public.var_nov_puente() from public, anon, authenticated;

create or replace function public.var_config_default(p_mes date) returns jsonb language sql immutable set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'fin_revision', to_char((p_mes + interval '1 month' + interval '6 days')::date, 'YYYY-MM-DD'),
    'horas_efectivas', jsonb_build_object('M', jsonb_build_object('1-4', 6.5, '5', 5.5, '6', 4.5, 'festivo', 4.5), 'T', jsonb_build_object('1-4', 6.5, '5', 6.5, '6', 5.5, 'festivo', 5.5)),
    'compuerta_ritmo', 38,
    'auditoria_meta_pct', null,
    'escalera', jsonb_build_array(jsonb_build_object('desde_excl', 110.0, 'factor', 1.5), jsonb_build_object('desde', 100.0, 'hasta', 110.0, 'factor', 'parte_entera'), jsonb_build_object('desde', 95.0, 'factor', 0.95), jsonb_build_object('desde', 90.0, 'factor', 0.80), jsonb_build_object('factor', 0)),
    'cargos', jsonb_build_object(
        'verificacion', jsonb_build_object('nombre', 'Verificación', 'medible', true, 'valor', 100000, 'variables', jsonb_build_array(
            jsonb_build_object('clave', 'efectividad', 'tipo', 'prop', 'dir', 'mas', 'meta', 75, 'peso', 50),
            jsonb_build_object('clave', 'cancelacion', 'tipo', 'prop', 'dir', 'menos', 'meta', 18, 'peso', 35),
            jsonb_build_object('clave', 'puntualidad', 'tipo', 'todo_o_nada', 'regla', 'dias_tarde<3', 'peso', 15))),
        'v_historica', jsonb_build_object('nombre', 'Verificación Histórica', 'medible', true, 'valor', 100000, 'variables', jsonb_build_array(
            jsonb_build_object('clave', 'efectividad', 'tipo', 'prop', 'dir', 'mas', 'meta', 85, 'peso', 50),
            jsonb_build_object('clave', 'cancelacion', 'tipo', 'prop', 'dir', 'menos', 'meta', 45, 'peso', 35),
            jsonb_build_object('clave', 'puntualidad', 'tipo', 'todo_o_nada', 'regla', 'dias_tarde<3', 'peso', 15))),
        'novedades', jsonb_build_object('nombre', 'Gestión de Novedades', 'medible', false, 'liquida_fuera', true, 'valor', 100000, 'variables', jsonb_build_array(
            jsonb_build_object('clave', 'solucion', 'tipo', 'prop', 'dir', 'mas', 'meta', 55, 'peso', 35),
            jsonb_build_object('clave', 'gestion_acida', 'tipo', 'prop', 'dir', 'menos', 'meta', 20, 'peso', 25, 'nota', 'meta provisional: se valida con la base observada de octubre'),
            jsonb_build_object('clave', 'gestiones_hora', 'tipo', 'todo_o_nada', 'meta', 33, 'peso', 25),
            jsonb_build_object('clave', 'puntualidad', 'tipo', 'todo_o_nada', 'regla', 'dias_tarde<3', 'peso', 15))),
        'agente_whatsapp', jsonb_build_object('nombre', 'Agente WhatsApp', 'medible', false),
        'apoyo', jsonb_build_object('nombre', 'Apoyo', 'medible', false),
        'lider', jsonb_build_object('valor', 200000, 'bloques', jsonb_build_object('operacion', 0.70, 'novedades', 0.30)))) $$;

create or replace function public.var_novedades_mes(p_mes date, p_dia date default null, p_desde date default null, p_hasta date default null) returns jsonb
language plpgsql stable set search_path = public, pg_temp as $fn$
declare
  cfg jsonb := var_config_vigente(p_mes); hoy date := var_hoy_col(); ahora timestamp := var_ahora_col();
  d_fin date := least(coalesce(p_hasta, (p_mes + interval '1 month' - interval '1 day')::date), (p_mes + interval '1 month' - interval '1 day')::date, hoy);
  d_ini date := greatest(coalesce(p_desde, p_mes), p_mes);
  dia date := coalesce(p_dia, least((p_mes + interval '1 month' - interval '1 day')::date, hoy));
  vars jsonb := coalesce(cfg->'cargos'->'novedades'->'variables', '[]'::jsonb);
  m_sol numeric := coalesce((select (v->>'meta')::numeric from jsonb_array_elements(vars) v where v->>'clave' = 'solucion'), 55);
  m_aci numeric := coalesce((select (v->>'meta')::numeric from jsonb_array_elements(vars) v where v->>'clave' = 'gestion_acida'), 20);
  m_gh  numeric := coalesce((select (v->>'meta')::numeric from jsonb_array_elements(vars) v where v->>'clave' = 'gestiones_hora'), 33);
  w_sol numeric := coalesce((select (v->>'peso')::numeric from jsonb_array_elements(vars) v where v->>'clave' = 'solucion'), 35);
  w_aci numeric := coalesce((select (v->>'peso')::numeric from jsonb_array_elements(vars) v where v->>'clave' = 'gestion_acida'), 25);
  w_gh  numeric := coalesce((select (v->>'peso')::numeric from jsonb_array_elements(vars) v where v->>'clave' = 'gestiones_hora'), 25);
  res jsonb;
begin
  if extract(day from p_mes) <> 1 then raise exception 'El mes debe ser el día 1' using errcode = 'P0010'; end if;
  with
  -- agente-día con cargo del día Novedades, enlazado al perfil de SGN
  ad as (select s.fecha, s.agent_id, s.turno, p.id as perfil from var_asignacion s join nov_profiles p on p.agent_id = s.agent_id
         where s.vigente and s.estado = 'novedades' and s.fecha between least(d_ini, dia) and greatest(d_fin, dia)),
  excl as (select var_norm(texto) t from nov_motivos where activo),
  -- intentos del agente por día (hora Colombia)
  g as (select ad.fecha, ad.agent_id, ad.turno, ge.id, ge.order_id, ge.accion, ge.resolved_in_dropi, ge.created_at,
               (ge.accion = 'devolucion' and var_norm(coalesce(ge.motivo_devolucion,'')) in (select t from excl)) as dev_excluida,
               coalesce(n.country, var_pais_iso(split_part(ge.store_name, ' ', -1))) as country,
               extract(hour from ge.created_at at time zone 'America/Bogota')::int * 2 + (extract(minute from ge.created_at at time zone 'America/Bogota')::int / 30) as hh
        from ad join nov_gestiones ge on ge.agente_id = ad.perfil and (ge.created_at at time zone 'America/Bogota')::date = ad.fecha
        left join nov_novedades n on n.order_id = ge.order_id),
  -- estado final de la orden y desenlace posterior a cada solución
  gx as (select g.*, e.status as estado_final, var_estado_final(e.status) as final_tipo,
                (g.resolved_in_dropi and g.accion <> 'devolucion') as solucion_ok,
                exists (select 1 from nov_orden_estado_hist h where h.order_id = g.order_id and h.estado = 'NOVEDAD' and h.fecha > g.created_at + interval '1 minute') as reincidio
         from g left join nov_orden_estado e on e.order_id = g.order_id and e.country = g.country),
  -- por agente-día
  dd as (select fecha, agent_id, turno,
                count(*)::int intentos,
                count(distinct order_id)::int ordenes,
                count(distinct order_id) filter (where solucion_ok)::int ordenes_sol,
                count(*) filter (where not dev_excluida and coalesce(final_tipo,'') <> 'excluido')::int intentos_validos,
                count(distinct order_id) filter (where solucion_ok and coalesce(final_tipo,'') <> 'excluido' and (reincidio or estado_final = 'DEVOLUCION'))::int ordenes_acidas,
                count(distinct order_id) filter (where solucion_ok and final_tipo is null)::int pendientes_cierre,
                min(hh)::int primera_hh
         from gx group by 1, 2, 3),
  ddx as (select dd.*,
                 case when dd.fecha = hoy then var_horas_vivas(dd.fecha, dd.turno, dd.primera_hh, ahora, cfg) else nullif(var_horas_efectivas(dd.fecha, dd.turno, cfg), 0) end as horas
          from dd),
  ddj as (select agent_id, fecha, jsonb_build_object('fecha', fecha, 'turno', turno, 'intentos', intentos, 'ordenes', ordenes, 'ordenes_sol', ordenes_sol, 'intentos_validos', intentos_validos,
                  'ordenes_acidas', ordenes_acidas, 'pendientes', pendientes_cierre, 'horas', round(horas, 2),
                  'solucion_real', case when ordenes > 0 then round(ordenes_sol * 100.0 / ordenes, 1) end,
                  'acida_real', case when intentos_validos > 0 then round(ordenes_acidas * 100.0 / intentos_validos, 1) end,
                  'gest_h', case when horas > 0 then round(intentos / horas, 1) end) as j from ddx),
  -- acumulado del mes (rango) por agente
  mm as (select agent_id, count(*)::int dias, sum(intentos)::int intentos, sum(ordenes)::int ordenes, sum(ordenes_sol)::int ordenes_sol, sum(intentos_validos)::int intentos_validos,
                sum(ordenes_acidas)::int ordenes_acidas, sum(pendientes_cierre)::int pendientes, sum(case when fecha = hoy then 0 else coalesce(horas, 0) end)::numeric horas_cerradas,
                sum(case when fecha = hoy then 0 else intentos end)::int intentos_cerrados
         from ddx where fecha between d_ini and d_fin group by 1),
  mmx as (select mm.*,
                 case when ordenes > 0 then round(ordenes_sol * 100.0 / ordenes, 1) end as sol_real,
                 case when intentos_validos > 0 then round(ordenes_acidas * 100.0 / intentos_validos, 1) end as aci_real,
                 case when horas_cerradas > 0 then round(intentos_cerrados / horas_cerradas, 1) end as gh_real
          from mm),
  mmc as (select mmx.*,
                 case when sol_real is not null and m_sol > 0 then least(150.0, round(sol_real * 100 / m_sol, 1)) end as sol_cumpl,
                 case when aci_real is null then null when aci_real = 0 then 150.0 when m_aci > 0 then least(150.0, round(m_aci * 100 / aci_real, 1)) end as aci_cumpl,
                 case when gh_real is null then null when gh_real >= m_gh then 100.0 else 0.0 end as gh_cumpl
          from mmx),
  agentes as (select distinct a.agent_id, a.nombre from var_agente a join ad on ad.agent_id = a.agent_id)
  select jsonb_build_object(
    'mes', to_char(p_mes, 'YYYY-MM'), 'hoy', hoy, 'desde', d_ini, 'hasta', d_fin, 'dia', dia,
    'metas', jsonb_build_object('solucion', m_sol, 'gestion_acida', m_aci, 'gestiones_hora', m_gh),
    'agentes', coalesce((select jsonb_agg(jsonb_build_object(
        'agent_id', a.agent_id, 'nombre', a.nombre,
        'dia', (select j from ddj where ddj.agent_id = a.agent_id and ddj.fecha = dia),
        'mes', (select jsonb_build_object('dias', c.dias, 'intentos', c.intentos, 'ordenes', c.ordenes, 'ordenes_sol', c.ordenes_sol, 'intentos_validos', c.intentos_validos,
                  'ordenes_acidas', c.ordenes_acidas, 'pendientes', c.pendientes, 'horas', round(c.horas_cerradas, 2),
                  'solucion_real', c.sol_real, 'solucion_cumpl', c.sol_cumpl, 'acida_real', c.aci_real, 'acida_cumpl', c.aci_cumpl, 'gest_h', c.gh_real, 'gest_h_cumpl', c.gh_cumpl,
                  'general', case when c.sol_cumpl is not null or c.aci_cumpl is not null or c.gh_cumpl is not null then
                     round((coalesce(c.sol_cumpl * w_sol, 0) + coalesce(c.aci_cumpl * w_aci, 0) + coalesce(c.gh_cumpl * w_gh, 0))
                           / nullif(coalesce(case when c.sol_cumpl is not null then w_sol end, 0) + coalesce(case when c.aci_cumpl is not null then w_aci end, 0) + coalesce(case when c.gh_cumpl is not null then w_gh end, 0), 0), 1) end)
                from mmc c where c.agent_id = a.agent_id),
        'dias', coalesce((select jsonb_agg(j order by fecha) from ddj where ddj.agent_id = a.agent_id and ddj.fecha between d_ini and d_fin), '[]'::jsonb)
      ) order by a.nombre) from agentes a), '[]'::jsonb),
    'sin_puente', coalesce((select jsonb_agg(jsonb_build_object('agent_id', s.agent_id, 'nombre', a.nombre)) from (select distinct agent_id from var_asignacion where vigente and estado = 'novedades' and fecha between d_ini and d_fin) s
        join var_agente a on a.agent_id = s.agent_id where not exists (select 1 from nov_profiles p where p.agent_id = s.agent_id)), '[]'::jsonb)
  ) into res;
  return res;
end $fn$;
revoke all on function public.var_novedades_mes(date, date, date, date) from public, anon, authenticated;

-- Reporte Admin: novedades cerradas en Dropi sin gestión de humano ni de la IA (IA resolvió = trigger 'api_ok')
create or replace function public.nov_sin_gestion(p_desde date, p_hasta date) returns jsonb language sql stable set search_path = public, pg_temp as $$
  with c as (
    select e.order_id, e.country, e.store_name, (e.detectado_en at time zone 'America/Bogota')::date as fecha_cierre, e.detectado_en, e.tipo_novedad
    from nov_eventos e where e.evento = 'cerrada' and (e.detectado_en at time zone 'America/Bogota')::date between p_desde and p_hasta
  ), x as (
    select c.*,
      exists (select 1 from nov_gestiones g where g.order_id = c.order_id and g.created_at <= c.detectado_en) as humano,
      exists (select 1 from nov_ia_gestiones i where i.order_id = c.order_id and i.trigger_evento = 'api_ok' and i.revisado_at <= c.detectado_en) as ia
    from c
  )
  select jsonb_build_object(
    'desde', p_desde, 'hasta', p_hasta,
    'total_cerradas', (select count(*) from x), 'con_humano', (select count(*) from x where humano), 'con_ia', (select count(*) from x where ia and not humano),
    'sin_gestion', (select count(*) from x where not humano and not ia),
    'por_dia', coalesce((select jsonb_agg(jsonb_build_object('fecha', fecha_cierre, 'cerradas', n, 'sin_gestion', s) order by fecha_cierre) from (select fecha_cierre, count(*) n, count(*) filter (where not humano and not ia) s from x group by 1) d), '[]'::jsonb),
    'por_tienda', coalesce((select jsonb_agg(jsonb_build_object('pais', country, 'tienda', store_name, 'sin_gestion', s, 'cerradas', n) order by s desc, n desc) from (select country, store_name, count(*) n, count(*) filter (where not humano and not ia) s from x group by 1, 2 having count(*) filter (where not humano and not ia) > 0) t), '[]'::jsonb),
    'ordenes', coalesce((select jsonb_agg(jsonb_build_object('orden', order_id, 'pais', country, 'tienda', store_name, 'tipo', tipo_novedad, 'cerrada', fecha_cierre) order by detectado_en desc) from (select * from x where not humano and not ia order by detectado_en desc limit 500) o), '[]'::jsonb)
  );
$$;
revoke all on function public.nov_sin_gestion(date, date) from public, anon, authenticated;
select var_nov_puente();

-- (020, aplicada aparte) var_roster incluye correo y si la persona está enlazada con SGN
create or replace function public.var_roster(p_fecha date default null, p_incluir_salidos boolean default false) returns jsonb language sql stable set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object('agent_id', g.agent_id, 'nombre', g.nombre, 'cargo_permanente', g.cargo_permanente, 'es_apoyo', g.es_apoyo, 'desde', g.desde, 'hasta', g.hasta,
                                                'salio', (g.hasta is not null and g.hasta < var_hoy_col()), 'correo', g.correo,
                                                'sgn', exists (select 1 from nov_profiles p where p.agent_id = g.agent_id)) order by g.nombre), '[]'::jsonb)
  from var_agente g
  where g.activo
    and case when p_fecha is not null then (g.desde is null or g.desde <= p_fecha) and (g.hasta is null or g.hasta >= p_fecha)
             when p_incluir_salidos then true
             else (g.hasta is null or g.hasta >= var_hoy_col()) end;
$$;
revoke all on function public.var_roster(date, boolean) from public, anon, authenticated;
