-- ============================================================================
-- Módulo de Variables · 012 · Fila del líder (consolidado de su turno) también en la tabla de Hoy / Día
--  · var_horas_vivas: horas transcurridas del turno (la misma regla que var_ritmo_vivo, sin dividir), para el ritmo consolidado de hoy
--  · var_resumen_mes: nueva clave `consolidado_dia` (misma forma que `consolidado`, calculada sobre el día mostrado); lo demás no cambia
-- ============================================================================
create or replace function public.var_horas_vivas(d date, turno char, primera_hh integer, ahora timestamp, cfg jsonb)
returns numeric language plpgsql stable set search_path = public, pg_temp as $fn$
declare dow int := extract(isodow from d); fest boolean := var_es_festivo(d);
        inicio timestamp; fin timestamp; brk timestamp; tope time; desc_min numeric := 0; horas numeric;
begin
  if primera_hh is null or dow = 7 then return null; end if;
  inicio := d + (primera_hh * interval '30 minutes');
  if turno = 'M' then
    tope := case when dow <= 4 then time '14:00' else time '13:00' end;
    brk  := d + time '10:00';
  else
    tope := case when dow <= 4 then time '21:00'                 -- L–J: la última hora (21–22) no llama
                 when dow = 5 then time '20:00' else time '19:00' end;
    brk  := d + case when dow <= 5 and not fest then time '18:00' else time '17:00' end;
  end if;
  fin := least(ahora, d + tope);
  if fin <= inicio then return null; end if;
  desc_min := greatest(0, extract(epoch from (least(fin, brk + interval '30 minutes') - greatest(inicio, brk))) / 60);
  horas := (extract(epoch from (fin - inicio)) / 3600) - (desc_min / 60);
  if horas < 1 then return null; end if;                            -- primera hora de gestión: "—"
  return horas;
end $fn$;
revoke all on function public.var_horas_vivas(date, char, integer, timestamp, jsonb) from public, anon, authenticated;

create or replace function public.var_resumen_mes(p_mes date, p_dia date default null, p_desde date default null, p_hasta date default null) returns jsonb
language plpgsql stable set search_path = public, pg_temp as $fn$
declare
  cfg jsonb := var_config_vigente(p_mes); hoy date := var_hoy_col(); ahora timestamp := var_ahora_col();
  d_fin date := least(coalesce(p_hasta, (p_mes + interval '1 month' - interval '1 day')::date), (p_mes + interval '1 month' - interval '1 day')::date, hoy);
  d_ini date := greatest(coalesce(p_desde, p_mes), p_mes);     -- rango opcional dentro del mes (filtro de fechas del Resumen)
  fin_mes date := least((p_mes + interval '1 month' - interval '1 day')::date, hoy);
  dia date := coalesce(p_dia, fin_mes);                         -- la tabla del DÍA no depende del rango filtrado de la tabla mensual
  comp numeric := coalesce((cfg->>'compuerta_ritmo')::numeric, 38);
  aud_meta numeric := nullif(cfg->>'auditoria_meta_pct','')::numeric;
  v_semana date := (dia - ((extract(isodow from dia)::int) - 1))::date;
  res jsonb;
begin
  if extract(day from p_mes) <> 1 then raise exception 'El mes debe ser el día 1' using errcode = 'P0010'; end if;
  if p_mes > hoy then return jsonb_build_object('mes', to_char(p_mes,'YYYY-MM'), 'hoy', hoy, 'agentes', '[]'::jsonb, 'consolidado', '{}'::jsonb, 'sin_asignar', '[]'::jsonb, 'sin_alias', '[]'::jsonb); end if;
  with
  ev as (select e.ev_date, e.type, e.halfhour, e.agent as nombre, a.agent_id from events_history e
    left join lateral (select al.agent_id from var_agente_alias al where al.nombre_norm = var_norm(e.agent) and e.ev_date >= al.desde and (al.hasta is null or e.ev_date <= al.hasta) order by al.desde desc limit 1) a on true
    where e.ev_date between d_ini and d_fin and not var_es_excluido(e.agent)),
  sin_alias as (select nombre, count(*)::int gest from ev where agent_id is null group by nombre),
  dd as (select agent_id, ev_date as fecha, count(*)::int gest, count(*) filter (where type = 0)::int conf, count(*) filter (where type = 1)::int canc, count(*) filter (where type = 2)::int reprog, min(halfhour)::int primera_hh from ev where agent_id is not null group by 1, 2),
  asg as (select fecha, agent_id, turno, estado, lider_uid, es_na from var_asignacion where vigente and fecha between d_ini and d_fin),
  ad as (select coalesce(d.agent_id, s.agent_id) agent_id, coalesce(d.fecha, s.fecha) fecha, coalesce(d.gest,0) gest, coalesce(d.conf,0) conf, coalesce(d.canc,0) canc, coalesce(d.reprog,0) reprog, d.primera_hh, s.turno, s.estado, s.lider_uid, s.es_na,
           case when s.turno is null then 0 else var_horas_efectivas(coalesce(d.fecha, s.fecha), s.turno, cfg) end as horas, (extract(isodow from coalesce(d.fecha, s.fecha)) = 7) as domingo
    from dd d full join asg s on s.fecha = d.fecha and s.agent_id = d.agent_id),
  metas as (select k as cargo,
      (select (v->>'meta')::numeric from jsonb_array_elements(coalesce(cfg->'cargos'->k->'variables','[]'::jsonb)) v where v->>'clave' = 'efectividad') meta_ef,
      (select (v->>'meta')::numeric from jsonb_array_elements(coalesce(cfg->'cargos'->k->'variables','[]'::jsonb)) v where v->>'clave' = 'cancelacion') meta_ca,
      (select (v->>'peso')::numeric from jsonb_array_elements(coalesce(cfg->'cargos'->k->'variables','[]'::jsonb)) v where v->>'clave' = 'efectividad') w_ef,
      (select (v->>'peso')::numeric from jsonb_array_elements(coalesce(cfg->'cargos'->k->'variables','[]'::jsonb)) v where v->>'clave' = 'cancelacion') w_ca,
      coalesce((cfg->'cargos'->k->>'medible')::boolean, false) medible
    from jsonb_object_keys(cfg->'cargos') k),
  -- acumulado por agente × cargo
  agc as (select agent_id, estado as cargo, count(*) filter (where not domingo)::int dias, sum(gest)::int gest, sum(conf)::int conf, sum(canc)::int canc, sum(reprog)::int reprog, sum(case when domingo then 0 else gest end)::int gest_ritmo, sum(horas)::numeric horas from ad where estado is not null group by 1, 2),
  agcx as (select a.*, m.meta_ef, m.meta_ca, m.w_ef, m.w_ca, m.medible,
      case when a.gest > 0 then round((a.conf + a.canc) * 100::numeric / a.gest, 1) end as ef_real,
      case when a.gest > 0 and m.meta_ef > 0 then least(150.0, round((a.conf + a.canc) * 10000::numeric / (a.gest * m.meta_ef), 1)) end as ef_cumpl,
      case when a.conf + a.canc > 0 then round(a.canc * 100::numeric / (a.conf + a.canc), 1) end as ca_real,
      case when a.conf + a.canc = 0 then null when a.canc = 0 then 150.0 when m.meta_ca > 0 then least(150.0, round(m.meta_ca * (a.conf + a.canc)::numeric / a.canc, 1)) end as ca_cumpl,
      case when a.horas > 0 then round(a.gest_ritmo::numeric / a.horas, 1) end as ritmo
    from agc a left join metas m on m.cargo = a.cargo),
  agcg as (select *, (ritmo is not null and ritmo >= comp) as compuerta,
      case when medible and (ef_cumpl is not null or ca_cumpl is not null) then
        round((coalesce(case when ritmo is not null and ritmo >= comp then ef_cumpl else 0 end * w_ef, 0) + coalesce(ca_cumpl * w_ca, 0))
              / nullif(coalesce(case when ef_cumpl is not null then w_ef end,0) + coalesce(case when ca_cumpl is not null then w_ca end,0), 0), 1) end as general
    from agcx),
  -- el día p_dia por agente: con sus propios eventos y asignaciones (independientes del rango d_ini..d_fin)
  ev_d as (select e.ev_date, e.type, e.halfhour, a.agent_id from events_history e
    left join lateral (select al.agent_id from var_agente_alias al where al.nombre_norm = var_norm(e.agent) and e.ev_date >= al.desde and (al.hasta is null or e.ev_date <= al.hasta) order by al.desde desc limit 1) a on true
    where e.ev_date = dia and not var_es_excluido(e.agent) and a.agent_id is not null),
  dd_d as (select agent_id, ev_date as fecha, count(*)::int gest, count(*) filter (where type = 0)::int conf, count(*) filter (where type = 1)::int canc, count(*) filter (where type = 2)::int reprog, min(halfhour)::int primera_hh from ev_d group by 1, 2),
  asg_d as (select fecha, agent_id, turno, estado from var_asignacion where vigente and fecha = dia),
  ad_d as (select coalesce(d.agent_id, s.agent_id) agent_id, coalesce(d.fecha, s.fecha) fecha, coalesce(d.gest,0) gest, coalesce(d.conf,0) conf, coalesce(d.canc,0) canc, coalesce(d.reprog,0) reprog, d.primera_hh, s.turno, s.estado,
           case when s.turno is null then 0 else var_horas_efectivas(coalesce(d.fecha, s.fecha), s.turno, cfg) end as horas, (extract(isodow from coalesce(d.fecha, s.fecha)) = 7) as domingo
    from dd_d d full join asg_d s on s.fecha = d.fecha and s.agent_id = d.agent_id),
  dx as (select a.*, m.meta_ef, m.meta_ca, m.w_ef, m.w_ca, m.medible,
      case when a.gest > 0 then round((a.conf + a.canc) * 100::numeric / a.gest, 1) end as ef_real,
      case when a.gest > 0 and m.meta_ef > 0 then least(150.0, round((a.conf + a.canc) * 10000::numeric / (a.gest * m.meta_ef), 1)) end as ef_cumpl,
      case when a.conf + a.canc > 0 then round(a.canc * 100::numeric / (a.conf + a.canc), 1) end as ca_real,
      case when a.conf + a.canc = 0 then null when a.canc = 0 then 150.0 when m.meta_ca > 0 then least(150.0, round(m.meta_ca * (a.conf + a.canc)::numeric / a.canc, 1)) end as ca_cumpl,
      case when a.fecha = hoy then var_ritmo_vivo(a.fecha, a.turno, a.primera_hh, a.gest, ahora, cfg)
           when a.horas > 0 and not a.domingo then round(a.gest::numeric / a.horas, 1) end as ritmo
    from ad_d a left join metas m on m.cargo = a.estado),
  dxg as (select *, (ritmo is not null and ritmo >= comp) as compuerta,
      case when medible and (ef_cumpl is not null or ca_cumpl is not null) then
        round((coalesce(case when ritmo is not null and ritmo >= comp then ef_cumpl else 0 end * w_ef, 0) + coalesce(ca_cumpl * w_ca, 0))
              / nullif(coalesce(case when ef_cumpl is not null then w_ef end,0) + coalesce(case when ca_cumpl is not null then w_ca end,0), 0), 1) end as general
    from dx),
  -- auditoría por porcentaje (mes)
  audt as (select t.agent_id, t.total from var_auditadas t where t.mes = p_mes and t.vigente),
  aude as (select e.agent_id, count(*)::int errores from var_auditoria e where e.anulado_por is null and (e.momento at time zone 'America/Bogota')::date between p_mes and (p_mes + interval '1 month' - interval '1 day')::date group by 1),
  -- consolidado por turno (cargos medibles), con líder de la semana
  con_c as (select turno, estado as cargo, sum(gest)::int gest, sum(conf)::int conf, sum(canc)::int canc, sum(case when domingo then 0 else gest end)::int gest_ritmo, sum(horas)::numeric horas from ad where turno is not null and coalesce((cfg->'cargos'->estado->>'medible')::boolean, false) group by 1, 2),
  con_cx as (select c.*, m.meta_ef, m.meta_ca, m.w_ef, m.w_ca,
      case when c.gest > 0 and m.meta_ef > 0 then least(150.0, (c.conf + c.canc) * 10000::numeric / (c.gest * m.meta_ef)) end as ef_cumpl,
      case when c.conf + c.canc = 0 then null when c.canc = 0 then 150.0 when m.meta_ca > 0 then least(150.0, m.meta_ca * (c.conf + c.canc)::numeric / c.canc) end as ca_cumpl
    from con_c c left join metas m on m.cargo = c.cargo),
  con as (select turno, sum(gest)::int gest, sum(conf)::int conf, sum(canc)::int canc,
      case when sum(gest) > 0 then round(sum(conf + canc) * 100::numeric / sum(gest), 1) end ef_real,
      case when sum(conf + canc) > 0 then round(sum(canc) * 100::numeric / sum(conf + canc), 1) end ca_real,
      round(sum(gest * ef_cumpl) filter (where ef_cumpl is not null) / nullif(sum(gest) filter (where ef_cumpl is not null), 0), 1) ef_cumpl,
      round(sum(gest * ca_cumpl) filter (where ca_cumpl is not null) / nullif(sum(gest) filter (where ca_cumpl is not null), 0), 1) ca_cumpl,
      case when sum(horas) > 0 then round(sum(gest_ritmo)::numeric / sum(horas), 1) end ritmo,
      max(w_ef) w_ef, max(w_ca) w_ca
    from con_cx group by turno),
  -- consolidado del DÍA por turno (cargos medibles): la fila del líder en la tabla de Hoy / Día. Misma regla que el consolidado del mes:
  --  cumplimientos ponderados por gestiones, ritmo = gestiones ÷ horas (hoy: horas transcurridas, igual que el ritmo vivo de cada agente).
  con_d_a as (select a.turno, a.estado as cargo, a.gest, a.conf, a.canc,
      case when a.domingo then null when a.fecha = hoy then var_horas_vivas(a.fecha, a.turno, a.primera_hh, ahora, cfg) else a.horas end as horas_r
    from ad_d a where a.turno is not null and coalesce((cfg->'cargos'->a.estado->>'medible')::boolean, false)),
  con_d_c as (select turno, cargo, sum(gest)::int gest, sum(conf)::int conf, sum(canc)::int canc,
      sum(case when horas_r is null then 0 else gest end)::int gest_ritmo, sum(horas_r)::numeric horas from con_d_a group by 1, 2),
  con_d_cx as (select c.*, m.meta_ef, m.meta_ca, m.w_ef, m.w_ca,
      case when c.gest > 0 and m.meta_ef > 0 then least(150.0, (c.conf + c.canc) * 10000::numeric / (c.gest * m.meta_ef)) end as ef_cumpl,
      case when c.conf + c.canc = 0 then null when c.canc = 0 then 150.0 when m.meta_ca > 0 then least(150.0, m.meta_ca * (c.conf + c.canc)::numeric / c.canc) end as ca_cumpl
    from con_d_c c left join metas m on m.cargo = c.cargo),
  con_d as (select turno, sum(gest)::int gest, sum(conf)::int conf, sum(canc)::int canc,
      case when sum(gest) > 0 then round(sum(conf + canc) * 100::numeric / sum(gest), 1) end ef_real,
      case when sum(conf + canc) > 0 then round(sum(canc) * 100::numeric / sum(conf + canc), 1) end ca_real,
      round(sum(gest * ef_cumpl) filter (where ef_cumpl is not null) / nullif(sum(gest) filter (where ef_cumpl is not null), 0), 1) ef_cumpl,
      round(sum(gest * ca_cumpl) filter (where ca_cumpl is not null) / nullif(sum(gest) filter (where ca_cumpl is not null), 0), 1) ca_cumpl,
      case when sum(horas) > 0 then round(sum(gest_ritmo)::numeric / sum(horas), 1) end ritmo,
      max(w_ef) w_ef, max(w_ca) w_ca
    from con_d_cx group by turno),
  lid as (select ls.turno, u.nombre, u.etiqueta from var_lider_semana ls join var_usuarios u on u.auth_uid = ls.lider_uid where ls.semana = v_semana),
  hoyasg as (select distinct on (agent_id) agent_id, estado, turno, fecha, es_na from var_asignacion where vigente and fecha between p_mes and dia order by agent_id, fecha desc),
  agentes as (select g.agent_id, g.nombre, g.cargo_permanente from var_agente g where g.activo or exists (select 1 from ad where ad.agent_id = g.agent_id) or exists (select 1 from ad_d where ad_d.agent_id = g.agent_id))
  select jsonb_build_object(
    'mes', to_char(p_mes, 'YYYY-MM'), 'hoy', hoy, 'desde', d_ini, 'hasta', d_fin, 'dia', dia, 'estado', var_estado_mes(p_mes), 'config_version', cfg->'_version',
    'compuerta_ritmo', comp, 'auditoria_meta_pct', aud_meta, 'dias_habiles', var_dias_habiles(p_mes),
    'metas', (select jsonb_object_agg(m.cargo, jsonb_build_object('efectividad', m.meta_ef, 'cancelacion', m.meta_ca, 'medible', m.medible)) from metas m),
    'lideres', coalesce((select jsonb_object_agg(l.turno, jsonb_build_object('nombre', l.nombre, 'etiqueta', l.etiqueta)) from lid l), '{}'::jsonb),
    'agentes', coalesce((select jsonb_agg(jsonb_build_object(
        'agent_id', g.agent_id, 'nombre', g.nombre, 'cargo_permanente', g.cargo_permanente,
        'cargo_hoy', h.estado, 'turno_hoy', h.turno, 'asignado_hasta', h.fecha,
        'dia', (select jsonb_build_object('fecha', x.fecha, 'cargo', x.estado, 'turno', x.turno, 'gest', x.gest, 'conf', x.conf, 'canc', x.canc, 'reprog', x.reprog, 'horas', x.horas,
                  'efectividad_real', x.ef_real, 'efectividad_cumpl', x.ef_cumpl, 'cancelacion_real', x.ca_real, 'cancelacion_cumpl', x.ca_cumpl,
                  'ritmo', x.ritmo, 'compuerta', x.compuerta, 'general', x.general, 'medible', x.medible) from dxg x where x.agent_id = g.agent_id),
        'auditoria', (select jsonb_build_object('auditadas', t.total, 'errores', coalesce(e.errores, 0),
                  'pct', case when t.total > 0 then round(coalesce(e.errores,0) * 100::numeric / t.total, 1) end,
                  'cumpl', case when t.total > 0 and aud_meta is not null then (round(coalesce(e.errores,0) * 100::numeric / t.total, 1) <= aud_meta) end)
                from audt t left join aude e on e.agent_id = t.agent_id where t.agent_id = g.agent_id),
        'errores', coalesce((select e.errores from aude e where e.agent_id = g.agent_id), 0),
        'cargos', coalesce((select jsonb_agg(jsonb_build_object('cargo', x.cargo, 'medible', x.medible, 'dias', x.dias, 'gest', x.gest, 'conf', x.conf, 'canc', x.canc, 'reprog', x.reprog, 'horas', x.horas,
            'efectividad_real', x.ef_real, 'efectividad_cumpl', x.ef_cumpl, 'cancelacion_real', x.ca_real, 'cancelacion_cumpl', x.ca_cumpl, 'ritmo', x.ritmo, 'compuerta', x.compuerta, 'general', x.general) order by x.cargo) from agcg x where x.agent_id = g.agent_id), '[]'::jsonb),
        'dias', coalesce((select jsonb_agg(jsonb_build_object('fecha', d.fecha, 'estado', d.estado, 'turno', d.turno, 'gest', d.gest, 'conf', d.conf, 'canc', d.canc, 'reprog', d.reprog, 'horas', d.horas) order by d.fecha) from ad d where d.agent_id = g.agent_id), '[]'::jsonb)
      ) order by g.nombre) from agentes g left join hoyasg h on h.agent_id = g.agent_id), '[]'::jsonb),
    'consolidado', coalesce((select jsonb_object_agg(c.turno, jsonb_build_object('gest', c.gest, 'conf', c.conf, 'canc', c.canc, 'efectividad_real', c.ef_real, 'efectividad_cumpl', c.ef_cumpl,
        'cancelacion_real', c.ca_real, 'cancelacion_cumpl', c.ca_cumpl, 'ritmo', c.ritmo, 'compuerta', case when c.ritmo is null then null else c.ritmo >= comp end,
        'general', case when c.ef_cumpl is not null or c.ca_cumpl is not null then round((coalesce(case when c.ritmo >= comp then c.ef_cumpl else 0 end * c.w_ef,0) + coalesce(c.ca_cumpl * c.w_ca,0)) / nullif(coalesce(case when c.ef_cumpl is not null then c.w_ef end,0) + coalesce(case when c.ca_cumpl is not null then c.w_ca end,0),0), 1) end,
        'lider', (select jsonb_build_object('nombre', l.nombre, 'etiqueta', l.etiqueta) from lid l where l.turno = c.turno))) from con c), '{}'::jsonb),
    'consolidado_dia', coalesce((select jsonb_object_agg(c.turno, jsonb_build_object('gest', c.gest, 'conf', c.conf, 'canc', c.canc, 'efectividad_real', c.ef_real, 'efectividad_cumpl', c.ef_cumpl,
        'cancelacion_real', c.ca_real, 'cancelacion_cumpl', c.ca_cumpl, 'ritmo', c.ritmo, 'compuerta', case when c.ritmo is null then null else c.ritmo >= comp end,
        'general', case when c.ef_cumpl is not null or c.ca_cumpl is not null then round((coalesce(case when c.ritmo >= comp then c.ef_cumpl else 0 end * c.w_ef,0) + coalesce(c.ca_cumpl * c.w_ca,0)) / nullif(coalesce(case when c.ef_cumpl is not null then c.w_ef end,0) + coalesce(case when c.ca_cumpl is not null then c.w_ca end,0),0), 1) end,
        'lider', (select jsonb_build_object('nombre', l.nombre, 'etiqueta', l.etiqueta) from lid l where l.turno = c.turno))) from con_d c), '{}'::jsonb),
    'sin_asignar', coalesce((select jsonb_agg(jsonb_build_object('agent_id', d.agent_id, 'fecha', d.fecha, 'gest', d.gest, 'estado', d.estado) order by d.fecha, d.agent_id) from ad d where d.gest > 0 and (d.estado is null or d.estado in ('ausencia','incapacidad'))), '[]'::jsonb),
    'sin_alias', coalesce((select jsonb_agg(jsonb_build_object('nombre', s.nombre, 'gest', s.gest) order by s.gest desc, s.nombre) from sin_alias s), '[]'::jsonb),
    'asignaciones_hoy', (select count(*) from var_asignacion where vigente and fecha = hoy)
  ) into res;
  return res;
end $fn$;

