-- ============================================================================
-- Módulo de Variables · 021 · Novedades etapa 2: correcciones de la revisión adversaria (25-sep-2026)
--  1. var_nov_puente() des-enlaza perfiles cuyo correo ya no coincide (y respeta alias vigentes).
--  2. Gestión Ácida se atribuye SOLO a la última solución de la orden antes del desenlace (reincidencia o DEVOLUCION), no a todas.
--  3. La reincidencia se detecta por el historial de Dropi (NOVEDAD posterior) O por el cuaderno de eventos de SGN (reaparece/nueva posterior).
--  4. Agente-día asignado a Novedades sin gestiones cuenta con 0 intentos y sus horas (el denominador de Gestiones/hora no se encoge).
--  5. Intentos de días sin horas (domingo) no entran al numerador de Gestiones/hora.
--  6. nov_sin_gestion acota la gestión humana/IA a la ventana de ESA novedad (desde el cierre anterior de la misma orden).
--  7. Estados comparados normalizados (final_tipo = 'fracaso'; upper(trim(estado)) = 'NOVEDAD').
--  8. Nuevo: sin_asignar (gestiones en días sin asignación Novedades) y sin_pais (soluciones sin país: no se pueden consultar en Dropi).
--  9. Acumulado del mes por órdenes distintas (no suma de diarios); intentos_cerrados expuesto.
-- 11. Predicado por rango de fecha para usar el índice; índice parcial de eventos cerrados.
-- ============================================================================
create index if not exists nov_eventos_cerrada_idx on public.nov_eventos (detectado_en) where evento = 'cerrada';

create or replace function public.var_nov_puente() returns int language plpgsql set search_path = public, pg_temp as $fn$
declare n int := 0; m int := 0;
begin
  -- 0) des-enlazar lo que ya no se justifica: ni el correo coincide ni hay alias vigente con ese nombre
  update nov_profiles p set agent_id = null from var_agente a
    where p.agent_id = a.agent_id
      and (a.correo is null or lower(p.email) is distinct from lower(a.correo))
      and not exists (select 1 from var_agente_alias al where al.agent_id = a.agent_id and al.hasta is null and al.nombre_norm = var_norm(p.full_name));
  update nov_profiles p set agent_id = a.agent_id from var_agente a
    where p.email is not null and a.correo is not null and lower(p.email) = lower(a.correo) and p.agent_id is distinct from a.agent_id;
  get diagnostics n = row_count;
  update nov_profiles p set agent_id = al.agent_id from var_agente_alias al
    where p.agent_id is null and al.hasta is null and al.nombre_norm = var_norm(p.full_name)
      and not exists (select 1 from nov_profiles q where q.agent_id = al.agent_id and q.id <> p.id and q.active);
  get diagnostics m = row_count;
  return n + m;
end $fn$;
revoke all on function public.var_nov_puente() from public, anon, authenticated;

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
  r_ini date; r_fin date; t_ini timestamptz; t_fin timestamptz;
  res jsonb;
begin
  if extract(day from p_mes) <> 1 then raise exception 'El mes debe ser el día 1' using errcode = 'P0010'; end if;
  if dia < p_mes or dia >= p_mes + interval '1 month' then raise exception 'El día debe estar dentro del mes' using errcode = 'P0010'; end if;
  r_ini := least(d_ini, dia); r_fin := greatest(d_fin, dia);
  t_ini := r_ini::timestamp at time zone 'America/Bogota'; t_fin := (r_fin + 1)::timestamp at time zone 'America/Bogota';
  with
  -- agente-día con cargo del día Novedades, enlazado al perfil de SGN
  ad as (select s.fecha, s.agent_id, s.turno, p.id as perfil from var_asignacion s join nov_profiles p on p.agent_id = s.agent_id
         where s.vigente and s.estado = 'novedades' and s.fecha between r_ini and r_fin),
  excl as (select var_norm(texto) t from nov_motivos where activo),
  -- intentos del agente por día (hora Colombia); un agente-día sin gestiones produce una fila con id nulo
  g as (select ad.fecha, ad.agent_id, ad.turno, ge.id, ge.order_id, ge.accion, ge.resolved_in_dropi, ge.created_at,
               (ge.accion = 'devolucion' and var_norm(coalesce(ge.motivo_devolucion,'')) in (select t from excl)) as dev_excluida,
               coalesce(n.country, var_pais_iso(split_part(ge.store_name, ' ', -1))) as country,
               extract(hour from ge.created_at at time zone 'America/Bogota')::int * 2 + (extract(minute from ge.created_at at time zone 'America/Bogota')::int / 30) as hh
        from ad left join nov_gestiones ge on ge.agente_id = ad.perfil and ge.created_at >= t_ini and ge.created_at < t_fin
                                          and (ge.created_at at time zone 'America/Bogota')::date = ad.fecha
        left join nov_novedades n on n.order_id = ge.order_id),
  -- estado final de la orden y desenlace posterior a cada solución
  g1 as (select g.*, e.status as estado_final, var_estado_final(e.status) as final_tipo,
                (g.resolved_in_dropi and g.accion <> 'devolucion') as solucion_ok,
                least((select min(h.fecha) from nov_orden_estado_hist h where h.order_id = g.order_id and upper(trim(h.estado)) = 'NOVEDAD' and h.fecha > g.created_at + interval '1 minute'),
                      (select min(ev.detectado_en) from nov_eventos ev where ev.order_id = g.order_id and ev.evento in ('reaparece', 'nueva') and ev.detectado_en > g.created_at + interval '1 minute')) as reinc_at
         from g left join nov_orden_estado e on e.order_id = g.order_id and e.country = g.country),
  gx as (select g1.*,
                -- la ácida se atribuye a la ÚLTIMA solución de la orden antes del desenlace (reincidencia o cierre)
                (g1.solucion_ok and not exists (select 1 from nov_gestiones g2 where g2.order_id = g1.order_id and g2.resolved_in_dropi and g2.accion <> 'devolucion'
                                                  and g2.created_at > g1.created_at and g2.created_at < coalesce(g1.reinc_at, 'infinity'::timestamptz))) as ultima_sol
         from g1),
  gy as (select gx.*,
                (ultima_sol and coalesce(final_tipo,'') <> 'excluido' and (reinc_at is not null or final_tipo = 'fracaso')) as acida,
                (solucion_ok and final_tipo is null and reinc_at is null and country is not null) as pendiente,
                (solucion_ok and final_tipo is null and reinc_at is null and country is null) as sin_pais
         from gx),
  -- por agente-día
  dd as (select fecha, agent_id, turno,
                count(id)::int intentos,
                count(distinct order_id)::int ordenes,
                count(distinct order_id) filter (where solucion_ok)::int ordenes_sol,
                count(id) filter (where not dev_excluida and coalesce(final_tipo,'') <> 'excluido')::int intentos_validos,
                count(distinct order_id) filter (where acida)::int ordenes_acidas,
                count(distinct order_id) filter (where pendiente)::int pendientes_cierre,
                min(hh)::int primera_hh
         from gy group by 1, 2, 3),
  ddx as (select dd.*,
                 case when dd.fecha = hoy then var_horas_vivas(dd.fecha, dd.turno, dd.primera_hh, ahora, cfg) else nullif(var_horas_efectivas(dd.fecha, dd.turno, cfg), 0) end as horas
          from dd),
  ddj as (select agent_id, fecha, jsonb_build_object('fecha', fecha, 'turno', turno, 'intentos', intentos, 'ordenes', ordenes, 'ordenes_sol', ordenes_sol, 'intentos_validos', intentos_validos,
                  'ordenes_acidas', ordenes_acidas, 'pendientes', pendientes_cierre, 'horas', round(horas, 2),
                  'solucion_real', case when ordenes > 0 then round(ordenes_sol * 100.0 / ordenes, 1) end,
                  'acida_real', case when intentos_validos > 0 then round(ordenes_acidas * 100.0 / intentos_validos, 1) end,
                  'gest_h', case when horas > 0 then round(intentos / horas, 1) end) as j from ddx),
  -- acumulado del mes (rango) por agente: días y horas desde los diarios; órdenes distintas desde las gestiones
  mh as (select agent_id, count(*)::int dias, sum(intentos)::int intentos,
                sum(case when fecha = hoy then 0 else coalesce(horas, 0) end)::numeric horas_cerradas,
                sum(case when fecha = hoy or horas is null then 0 else intentos end)::int intentos_cerrados
         from ddx where fecha between d_ini and d_fin group by 1),
  mo as (select agent_id, count(distinct order_id)::int ordenes, count(distinct order_id) filter (where solucion_ok)::int ordenes_sol,
                count(id) filter (where not dev_excluida and coalesce(final_tipo,'') <> 'excluido')::int intentos_validos,
                count(distinct order_id) filter (where acida)::int ordenes_acidas,
                count(distinct order_id) filter (where pendiente)::int pendientes,
                count(distinct order_id) filter (where sin_pais)::int sin_pais
         from gy where fecha between d_ini and d_fin group by 1),
  mm as (select mh.*, mo.ordenes, mo.ordenes_sol, mo.intentos_validos, mo.ordenes_acidas, mo.pendientes, mo.sin_pais from mh join mo using (agent_id)),
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
  agentes as (select distinct a.agent_id, a.nombre from var_agente a join ad on ad.agent_id = a.agent_id),
  -- gestiones de personas enlazadas en días del rango SIN asignación del día "Novedades" (no se miden: aviso al líder)
  sa as (select p.agent_id, a.nombre, (ge.created_at at time zone 'America/Bogota')::date as fecha, count(*)::int intentos
         from nov_gestiones ge join nov_profiles p on p.id = ge.agente_id and p.agent_id is not null join var_agente a on a.agent_id = p.agent_id and a.activo
         where ge.created_at >= t_ini and ge.created_at < t_fin
           and not exists (select 1 from ad where ad.agent_id = p.agent_id and ad.fecha = (ge.created_at at time zone 'America/Bogota')::date)
         group by 1, 2, 3)
  select jsonb_build_object(
    'mes', to_char(p_mes, 'YYYY-MM'), 'hoy', hoy, 'desde', d_ini, 'hasta', d_fin, 'dia', dia,
    'metas', jsonb_build_object('solucion', m_sol, 'gestion_acida', m_aci, 'gestiones_hora', m_gh),
    'agentes', coalesce((select jsonb_agg(jsonb_build_object(
        'agent_id', a.agent_id, 'nombre', a.nombre,
        'dia', (select j from ddj where ddj.agent_id = a.agent_id and ddj.fecha = dia),
        'mes', (select jsonb_build_object('dias', c.dias, 'intentos', c.intentos, 'intentos_cerrados', c.intentos_cerrados, 'ordenes', c.ordenes, 'ordenes_sol', c.ordenes_sol, 'intentos_validos', c.intentos_validos,
                  'ordenes_acidas', c.ordenes_acidas, 'pendientes', c.pendientes, 'sin_pais', c.sin_pais, 'horas', round(c.horas_cerradas, 2),
                  'solucion_real', c.sol_real, 'solucion_cumpl', c.sol_cumpl, 'acida_real', c.aci_real, 'acida_cumpl', c.aci_cumpl, 'gest_h', c.gh_real, 'gest_h_cumpl', c.gh_cumpl,
                  'general', case when c.sol_cumpl is not null or c.aci_cumpl is not null or c.gh_cumpl is not null then
                     round((coalesce(c.sol_cumpl * w_sol, 0) + coalesce(c.aci_cumpl * w_aci, 0) + coalesce(c.gh_cumpl * w_gh, 0))
                           / nullif(coalesce(case when c.sol_cumpl is not null then w_sol end, 0) + coalesce(case when c.aci_cumpl is not null then w_aci end, 0) + coalesce(case when c.gh_cumpl is not null then w_gh end, 0), 0), 1) end)
                from mmc c where c.agent_id = a.agent_id),
        'dias', coalesce((select jsonb_agg(j order by fecha) from ddj where ddj.agent_id = a.agent_id and ddj.fecha between d_ini and d_fin), '[]'::jsonb)
      ) order by a.nombre) from agentes a), '[]'::jsonb),
    'sin_puente', coalesce((select jsonb_agg(jsonb_build_object('agent_id', s.agent_id, 'nombre', a.nombre)) from (select distinct agent_id from var_asignacion where vigente and estado = 'novedades' and fecha between d_ini and d_fin) s
        join var_agente a on a.agent_id = s.agent_id where not exists (select 1 from nov_profiles p where p.agent_id = s.agent_id)), '[]'::jsonb),
    'sin_asignar', coalesce((select jsonb_agg(jsonb_build_object('agent_id', agent_id, 'nombre', nombre, 'fecha', fecha, 'intentos', intentos) order by fecha, nombre) from sa), '[]'::jsonb)
  ) into res;
  return res;
end $fn$;
revoke all on function public.var_novedades_mes(date, date, date, date) from public, anon, authenticated;

-- Reporte Admin: la gestión humana o de la IA debe ser de ESTA novedad (después del cierre anterior de la misma orden)
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
