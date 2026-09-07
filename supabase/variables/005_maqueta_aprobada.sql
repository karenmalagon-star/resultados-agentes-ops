-- ============================================================================
-- Módulo de Variables · 005 · Cambios de la maqueta aprobada por Daniel (5-sep, inputs/12–15)
--  · cargo PERMANENTE por agente (Admin) + cargo del DÍA (líder; N/A = rige el permanente)
--  · turno por agente (ya lo era en la tabla; la UI lo hacía masivo)
--  · turno semanal de cada líder (Admin) y etiqueta "Líder A" / "Líder B"
--  · auditoría por PORCENTAJE: órdenes auditadas por agente-mes + orden en cada error
--  · resumen con Real · Meta · Cumplimiento, por día y acumulado, y cumplimiento general (ponderado)
-- Aditivo. Sin dinero.
-- ============================================================================

alter table public.var_agente   add column if not exists cargo_permanente text not null default 'verificacion'
  check (cargo_permanente in ('verificacion','v_historica','novedades'));
alter table public.var_usuarios add column if not exists etiqueta text;               -- 'Líder A' / 'Líder B'
alter table public.var_asignacion add column if not exists es_na boolean not null default false; -- el líder dejó N/A (rige el permanente)
alter table public.var_auditoria add column if not exists orden text;

-- Turno que lidera cada líder en una semana (semana = lunes). Lo fija Admin.
create table if not exists public.var_lider_semana (
  semana      date not null,                                  -- lunes de la semana
  lider_uid   uuid not null references public.var_usuarios(auth_uid),
  turno       char(1) not null check (turno in ('M','T')),
  creado_por  uuid not null,
  creado_en   timestamptz not null default now(),
  primary key (semana, lider_uid),
  constraint var_lider_semana_lunes check (extract(isodow from semana) = 1)
);
alter table public.var_lider_semana enable row level security;

-- Total de órdenes auditadas por agente-mes (lo actualiza quien audita). Historial por filas vigentes.
create table if not exists public.var_auditadas (
  id           bigserial primary key,
  mes          date not null check (extract(day from mes) = 1),
  agent_id     text not null references public.var_agente(agent_id),
  total        integer not null check (total >= 0),
  vigente      boolean not null default true,
  reemplaza_id bigint references public.var_auditadas(id),
  creado_por   uuid not null,
  creado_en    timestamptz not null default now()
);
create unique index if not exists var_auditadas_vigente_uq on public.var_auditadas (mes, agent_id) where vigente;
alter table public.var_auditadas enable row level security;

create or replace function public.var_auditadas_set(p_mes date, p_agent_id text, p_total integer, p_actor uuid) returns bigint
language plpgsql set search_path = public, pg_temp as $fn$
declare prev bigint; nid bigint;
begin
  select id into prev from var_auditadas where mes = p_mes and agent_id = p_agent_id and vigente;
  if found and (select total from var_auditadas where id = prev) = p_total then return prev; end if;
  update var_auditadas set vigente = false where id = prev;
  insert into var_auditadas (mes, agent_id, total, reemplaza_id, creado_por) values (p_mes, p_agent_id, p_total, prev, p_actor) returning id into nid;
  return nid;
end $fn$;

-- var_asignar con es_na (N/A = el día hereda el permanente; el estado se resuelve al guardar y queda escrito)
create or replace function public.var_asignar(p_fecha date, p_agent_id text, p_turno char, p_estado text, p_lider uuid, p_actor uuid, p_es_na boolean default false) returns bigint
language plpgsql set search_path = public, pg_temp as $fn$
declare prev record; nid bigint; est text := p_estado;
begin
  if p_fecha > var_hoy_col() then raise exception 'No se puede asignar una fecha futura (%)', p_fecha using errcode = 'P0002'; end if;
  if not exists (select 1 from var_agente a where a.agent_id = p_agent_id and a.activo) then raise exception 'El agente % no está en el roster activo', p_agent_id using errcode = 'P0003'; end if;
  if not exists (select 1 from var_usuarios u where u.auth_uid = p_lider and u.activo) then raise exception 'Líder inválido' using errcode = 'P0004'; end if;
  if p_es_na then select cargo_permanente into est from var_agente where agent_id = p_agent_id; end if;
  select id, turno, estado, lider_uid, es_na into prev from var_asignacion where fecha = p_fecha and agent_id = p_agent_id and vigente;
  if found and prev.turno = p_turno and prev.estado = est and prev.lider_uid = p_lider and prev.es_na = p_es_na then return prev.id; end if;
  update var_asignacion set vigente = false where fecha = p_fecha and agent_id = p_agent_id and vigente;
  insert into var_asignacion (fecha, agent_id, turno, estado, lider_uid, vigente, reemplaza_id, creado_por, es_na)
    values (p_fecha, p_agent_id, p_turno, est, p_lider, true, prev.id, p_actor, p_es_na) returning id into nid;
  return nid;
end $fn$;
drop function if exists public.var_asignar(date, text, char, text, uuid, uuid);

-- Config: meta del % de error de auditoría (por definir → null = sin cumplimiento todavía)
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
        'novedades', jsonb_build_object('nombre', 'Gestión de Novedades', 'medible', false, 'valor', 100000, 'liquida_fuera', true),
        'apoyo', jsonb_build_object('nombre', 'Apoyo', 'medible', false),
        'lider', jsonb_build_object('valor', 200000, 'bloques', jsonb_build_object('operacion', 0.70, 'novedades', 0.30)))) $$;

-- ---------- RESUMEN v2: Real · Meta · Cumplimiento por día (p_dia) y acumulado; cumplimiento general ----------
drop function if exists public.var_resumen_mes(date);
create or replace function public.var_resumen_mes(p_mes date, p_dia date default null) returns jsonb
language plpgsql stable set search_path = public, pg_temp as $fn$
declare
  cfg jsonb := var_config_vigente(p_mes); hoy date := var_hoy_col(); ahora timestamp := var_ahora_col();
  d_fin date := least((p_mes + interval '1 month' - interval '1 day')::date, hoy);
  dia date := coalesce(p_dia, d_fin);
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
    where e.ev_date between p_mes and d_fin and not var_es_excluido(e.agent)),
  sin_alias as (select nombre, count(*)::int gest from ev where agent_id is null group by nombre),
  dd as (select agent_id, ev_date as fecha, count(*)::int gest, count(*) filter (where type = 0)::int conf, count(*) filter (where type = 1)::int canc, count(*) filter (where type = 2)::int reprog, min(halfhour)::int primera_hh from ev where agent_id is not null group by 1, 2),
  asg as (select fecha, agent_id, turno, estado, lider_uid, es_na from var_asignacion where vigente and fecha between p_mes and d_fin),
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
  agc as (select agent_id, estado as cargo, count(*)::int dias, sum(gest)::int gest, sum(conf)::int conf, sum(canc)::int canc, sum(reprog)::int reprog, sum(case when domingo then 0 else gest end)::int gest_ritmo, sum(horas)::numeric horas from ad where estado is not null group by 1, 2),
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
  -- el día p_dia por agente
  dx as (select a.*, m.meta_ef, m.meta_ca, m.w_ef, m.w_ca, m.medible,
      case when a.gest > 0 then round((a.conf + a.canc) * 100::numeric / a.gest, 1) end as ef_real,
      case when a.gest > 0 and m.meta_ef > 0 then least(150.0, round((a.conf + a.canc) * 10000::numeric / (a.gest * m.meta_ef), 1)) end as ef_cumpl,
      case when a.conf + a.canc > 0 then round(a.canc * 100::numeric / (a.conf + a.canc), 1) end as ca_real,
      case when a.conf + a.canc = 0 then null when a.canc = 0 then 150.0 when m.meta_ca > 0 then least(150.0, round(m.meta_ca * (a.conf + a.canc)::numeric / a.canc, 1)) end as ca_cumpl,
      case when a.fecha = hoy then var_ritmo_vivo(a.fecha, a.turno, a.primera_hh, a.gest, ahora, cfg)
           when a.horas > 0 and not a.domingo then round(a.gest::numeric / a.horas, 1) end as ritmo
    from ad a left join metas m on m.cargo = a.estado where a.fecha = dia),
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
      case when c.gest > 0 and m.meta_ef > 0 then least(150.0, round((c.conf + c.canc) * 10000::numeric / (c.gest * m.meta_ef), 1)) end as ef_cumpl,
      case when c.conf + c.canc = 0 then null when c.canc = 0 then 150.0 when m.meta_ca > 0 then least(150.0, round(m.meta_ca * (c.conf + c.canc)::numeric / c.canc, 1)) end as ca_cumpl
    from con_c c left join metas m on m.cargo = c.cargo),
  con as (select turno, sum(gest)::int gest, sum(conf)::int conf, sum(canc)::int canc,
      case when sum(gest) > 0 then round(sum(conf + canc) * 100::numeric / sum(gest), 1) end ef_real,
      case when sum(conf + canc) > 0 then round(sum(canc) * 100::numeric / sum(conf + canc), 1) end ca_real,
      round(sum(gest * ef_cumpl) filter (where ef_cumpl is not null) / nullif(sum(gest) filter (where ef_cumpl is not null), 0), 1) ef_cumpl,
      round(sum(gest * ca_cumpl) filter (where ca_cumpl is not null) / nullif(sum(gest) filter (where ca_cumpl is not null), 0), 1) ca_cumpl,
      case when sum(horas) > 0 then round(sum(gest_ritmo)::numeric / sum(horas), 1) end ritmo,
      max(w_ef) w_ef, max(w_ca) w_ca
    from con_cx group by turno),
  lid as (select ls.turno, u.nombre, u.etiqueta from var_lider_semana ls join var_usuarios u on u.auth_uid = ls.lider_uid where ls.semana = v_semana),
  hoyasg as (select distinct on (agent_id) agent_id, estado, turno, fecha, es_na from asg order by agent_id, fecha desc),
  agentes as (select g.agent_id, g.nombre, g.cargo_permanente from var_agente g where g.activo or exists (select 1 from ad where ad.agent_id = g.agent_id))
  select jsonb_build_object(
    'mes', to_char(p_mes, 'YYYY-MM'), 'hoy', hoy, 'hasta', d_fin, 'dia', dia, 'estado', var_estado_mes(p_mes), 'config_version', cfg->'_version',
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
    'sin_asignar', coalesce((select jsonb_agg(jsonb_build_object('agent_id', d.agent_id, 'fecha', d.fecha, 'gest', d.gest, 'estado', d.estado) order by d.fecha, d.agent_id) from ad d where d.gest > 0 and (d.estado is null or d.estado in ('ausencia','incapacidad'))), '[]'::jsonb),
    'sin_alias', coalesce((select jsonb_agg(jsonb_build_object('nombre', s.nombre, 'gest', s.gest) order by s.gest desc, s.nombre) from sin_alias s), '[]'::jsonb),
    'asignaciones_hoy', (select count(*) from asg where fecha = hoy)
  ) into res;
  return res;
end $fn$;
