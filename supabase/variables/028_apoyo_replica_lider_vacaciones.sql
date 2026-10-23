-- ============================================================================
-- Módulo de Variables · 028 · Réplica automática de la asignación, apoyo aparte y vacaciones del líder (input 34 / D-036, 23-oct-2026)
--  A) Réplica: de martes a sábado a las 5:00 a. m. (Colombia) el sistema copia la asignación vigente más reciente (hasta 6 días atrás)
--     sin el apoyo ni los marcados ausencia/incapacidad (vacaciones sí se arrastran). El lunes es manual. var_asignacion.replicada marca las copias.
--  B) var_asignacion_quitar: desmarcar a una persona de apoyo que no trabaja ese día.
--  C) Vacaciones/ausencias del líder por rango (var_lider_dia con tipo 'vacaciones'): los días con ausencia registrada NO se le acreditan
--     al titular (ni días liderados ni métricas) y se restan de los días que debía liderar (ya lo hacía var_lideres_mes).
--  D) var_reemplazos_mes: rendimiento del reemplazo (días, efectividad, cancelación, ritmo) como información; no entra en ninguna medición pagada.
-- ============================================================================

-- A) réplica automática
alter table public.var_asignacion add column if not exists replicada boolean not null default false;

create or replace function public.var_replicar_asignacion(p_fecha date) returns jsonb language plpgsql set search_path = public, pg_temp as $fn$
declare origen date; n int := 0;
begin
  if extract(isodow from p_fecha) not between 2 and 6 then return jsonb_build_object('fecha', p_fecha, 'replicadas', 0, 'motivo', 'solo de martes a sábado'); end if;
  if exists (select 1 from var_asignacion where fecha = p_fecha and vigente) then return jsonb_build_object('fecha', p_fecha, 'replicadas', 0, 'motivo', 'ya hay asignación'); end if;
  select max(fecha) into origen from var_asignacion where vigente and fecha < p_fecha and fecha >= p_fecha - 6;
  if origen is null then return jsonb_build_object('fecha', p_fecha, 'replicadas', 0, 'motivo', 'sin asignación en los últimos 6 días'); end if;
  insert into var_asignacion (fecha, agent_id, turno, estado, lider_uid, vigente, creado_por, es_na, replicada)
  select p_fecha, s.agent_id, s.turno, s.estado, s.lider_uid, true, s.lider_uid, s.es_na, true
  from var_asignacion s join var_agente g on g.agent_id = s.agent_id
  where s.vigente and s.fecha = origen and g.activo and (g.hasta is null or g.hasta >= p_fecha) and not g.es_apoyo and s.estado not in ('ausencia','incapacidad');
  get diagnostics n = row_count;
  return jsonb_build_object('fecha', p_fecha, 'origen', origen, 'replicadas', n);
end $fn$;
revoke all on function public.var_replicar_asignacion(date) from public, anon, authenticated;

select cron.unschedule(jobid) from cron.job where jobname = 'asignacion-replica-diaria';
select cron.schedule('asignacion-replica-diaria', '0 10 * * 2-6', $$select public.var_replicar_asignacion(public.var_hoy_col())$$);   -- 10:00 UTC = 05:00 Colombia

-- B) quitar a alguien de la asignación del día (apoyo que no trabaja)
create or replace function public.var_asignacion_quitar(p_fecha date, p_agent_id text, p_actor uuid) returns int language plpgsql set search_path = public, pg_temp as $fn$
declare n int;
begin
  update var_asignacion set vigente = false where fecha = p_fecha and agent_id = p_agent_id and vigente;
  get diagnostics n = row_count;
  return n;
end $fn$;
revoke all on function public.var_asignacion_quitar(date, text, uuid) from public, anon, authenticated;

-- C) vacaciones y ausencias del líder por rango
alter table public.var_lider_dia drop constraint if exists var_lider_dia_tipo_check;
alter table public.var_lider_dia add constraint var_lider_dia_tipo_check check (tipo in ('ausencia','incapacidad','descanso','vacaciones'));

create or replace function public.var_lider_ausencia_set(p_lider uuid, p_desde date, p_hasta date, p_tipo text, p_actor uuid) returns int language plpgsql set search_path = public, pg_temp as $fn$
declare n int;
begin
  if p_tipo not in ('ausencia','incapacidad','descanso','vacaciones') then raise exception 'Tipo inválido' using errcode = 'P0030'; end if;
  if p_hasta < p_desde or p_hasta - p_desde > 92 then raise exception 'Rango inválido (máximo 92 días)' using errcode = 'P0030'; end if;
  if not exists (select 1 from var_usuarios u where u.auth_uid = p_lider and u.activo) then raise exception 'Líder inválido' using errcode = 'P0030'; end if;
  insert into var_lider_dia (lider_uid, fecha, tipo, registrado_por)
  select p_lider, d::date, p_tipo, p_actor from generate_series(p_desde, p_hasta, interval '1 day') d
  on conflict (lider_uid, fecha) do update set tipo = excluded.tipo, registrado_por = excluded.registrado_por;
  get diagnostics n = row_count;
  return n;
end $fn$;
revoke all on function public.var_lider_ausencia_set(uuid, date, date, text, uuid) from public, anon, authenticated;

create or replace function public.var_lider_ausencia_quitar(p_lider uuid, p_desde date, p_hasta date) returns int language plpgsql set search_path = public, pg_temp as $fn$
declare n int;
begin
  delete from var_lider_dia where lider_uid = p_lider and fecha between p_desde and p_hasta;
  get diagnostics n = row_count;
  return n;
end $fn$;
revoke all on function public.var_lider_ausencia_quitar(uuid, date, date) from public, anon, authenticated;

create or replace function public.var_lider_ausencias(p_desde date default null) returns jsonb language sql stable set search_path = public, pg_temp as $$
  with d as (select ld.lider_uid, ld.tipo, ld.fecha, ld.fecha - (row_number() over (partition by ld.lider_uid, ld.tipo order by ld.fecha))::int grp
             from var_lider_dia ld where p_desde is null or ld.fecha >= p_desde),
       r as (select lider_uid, tipo, min(fecha) desde, max(fecha) hasta, count(*) filter (where var_es_habil(fecha))::int dias_habiles from d group by lider_uid, tipo, grp)
  select coalesce(jsonb_agg(jsonb_build_object('lider_uid', r.lider_uid, 'nombre', u.nombre, 'tipo', r.tipo, 'desde', r.desde, 'hasta', r.hasta, 'dias_habiles', r.dias_habiles) order by r.desde desc, u.nombre), '[]'::jsonb)
  from r join var_usuarios u on u.auth_uid = r.lider_uid;
$$;
revoke all on function public.var_lider_ausencias(date) from public, anon, authenticated;

-- var_lideres_mes: los días con ausencia registrada del titular no se le acreditan
create or replace function pg_temp.sub(p_def text, p_old text, p_new text, p_n int default 1) returns text language plpgsql as $$
begin
  if (length(p_def) - length(replace(p_def, p_old, ''))) / length(p_old) <> p_n then
    raise exception 'fragmento no encontrado % vez/veces: %', p_n, left(p_old, 80);
  end if;
  return replace(p_def, p_old, p_new);
end $$;
do $do$
declare d text;
begin
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'var_lideres_mes';
  d := pg_temp.sub(d, 'asg as (select a.fecha, a.agent_id, a.turno, a.estado,
       coalesce((select ls.reemplazo_de from var_lider_semana ls where ls.lider_uid = a.lider_uid and ls.reemplazo_de is not null
                   and ls.semana = (a.fecha - (extract(isodow from a.fecha)::int - 1))::date), a.lider_uid) lider_uid
     from var_asignacion a where a.vigente and a.fecha between p_mes and d_fin),',
    'asg as (select x.* from (select a.fecha, a.agent_id, a.turno, a.estado,
       coalesce((select ls.reemplazo_de from var_lider_semana ls where ls.lider_uid = a.lider_uid and ls.reemplazo_de is not null
                   and ls.semana = (a.fecha - (extract(isodow from a.fecha)::int - 1))::date), a.lider_uid) lider_uid
     from var_asignacion a where a.vigente and a.fecha between p_mes and d_fin) x
     where not exists (select 1 from var_lider_dia ld where ld.lider_uid = x.lider_uid and ld.fecha = x.fecha)),');
  execute d;
end $do$;

-- D) rendimiento del reemplazo (informativo)
create or replace function public.var_reemplazos_mes(p_mes date) returns jsonb
language plpgsql stable set search_path = public, pg_temp as $fn$
declare cfg jsonb := var_config_vigente(p_mes); hoy date := var_hoy_col();
        d_fin date := least((p_mes + interval '1 month' - interval '1 day')::date, hoy);
        comp numeric := coalesce((cfg->>'compuerta_ritmo')::numeric, 38); res jsonb;
begin
  with
  rs as (select a.fecha, a.agent_id, a.turno, a.estado, a.lider_uid, ls.reemplazo_de titular
         from var_asignacion a join var_lider_semana ls on ls.lider_uid = a.lider_uid and ls.reemplazo_de is not null
              and ls.semana = (a.fecha - (extract(isodow from a.fecha)::int - 1))::date
         where a.vigente and a.fecha between p_mes and d_fin),
  ev as (select e.ev_date, e.type, a.agent_id from events_history e
    left join lateral (select al.agent_id from var_agente_alias al where al.nombre_norm = var_norm(e.agent) and e.ev_date >= al.desde and (al.hasta is null or e.ev_date <= al.hasta) order by al.desde desc limit 1) a on true
    where e.ev_date between p_mes and d_fin and not var_es_excluido(e.agent) and a.agent_id is not null),
  dd as (select agent_id, ev_date fecha, count(*)::int gest, count(*) filter (where type = 0)::int conf, count(*) filter (where type = 1)::int canc from ev group by 1, 2),
  ad as (select s.lider_uid, s.titular, s.estado cargo, s.fecha, coalesce(d.gest,0) gest, coalesce(d.conf,0) conf, coalesce(d.canc,0) canc,
           var_horas_efectivas(s.fecha, s.turno, cfg) horas, (extract(isodow from s.fecha) = 7) domingo
         from rs s left join dd d on d.fecha = s.fecha and d.agent_id = s.agent_id
         where coalesce((cfg->'cargos'->s.estado->>'medible')::boolean, false)),
  metas as (select k cargo,
      (select (v->>'meta')::numeric from jsonb_array_elements(coalesce(cfg->'cargos'->k->'variables','[]'::jsonb)) v where v->>'clave' = 'efectividad') meta_ef,
      (select (v->>'meta')::numeric from jsonb_array_elements(coalesce(cfg->'cargos'->k->'variables','[]'::jsonb)) v where v->>'clave' = 'cancelacion') meta_ca
    from jsonb_object_keys(cfg->'cargos') k),
  lc as (select lider_uid, titular, cargo, sum(gest)::int gest, sum(conf)::int conf, sum(canc)::int canc, sum(case when domingo then 0 else gest end)::int gest_ritmo, sum(horas)::numeric horas from ad group by 1, 2, 3),
  lcx as (select l.*,
      case when l.gest > 0 and m.meta_ef > 0 then least(150.0, (l.conf + l.canc) * 10000::numeric / (l.gest * m.meta_ef)) end ef_cumpl,
      case when l.conf + l.canc = 0 then null when l.canc = 0 then 150.0 when m.meta_ca > 0 then least(150.0, m.meta_ca * (l.conf + l.canc)::numeric / l.canc) end ca_cumpl
    from lc l left join metas m on m.cargo = l.cargo),
  lider as (select lider_uid, titular, sum(gest)::int gest,
      round(sum(gest * ef_cumpl) filter (where ef_cumpl is not null) / nullif(sum(gest) filter (where ef_cumpl is not null), 0), 1) ef_cumpl,
      round(sum(gest * ca_cumpl) filter (where ca_cumpl is not null) / nullif(sum(gest) filter (where ca_cumpl is not null), 0), 1) ca_cumpl,
      case when sum(horas) > 0 then round(sum(gest_ritmo)::numeric / sum(horas), 1) end ritmo
    from lcx group by lider_uid, titular),
  dl as (select lider_uid, titular, count(distinct fecha) filter (where var_es_habil(fecha))::int dias, min(fecha) desde, max(fecha) hasta from rs group by 1, 2)
  select coalesce(jsonb_agg(jsonb_build_object(
      'lider_uid', d.lider_uid, 'nombre', u.nombre, 'titular', t.nombre, 'desde', d.desde, 'hasta', d.hasta, 'dias', d.dias,
      'gest', l.gest, 'efectividad_cumpl', l.ef_cumpl, 'cancelacion_cumpl', l.ca_cumpl, 'ritmo', l.ritmo,
      'compuerta', case when l.ritmo is null then null else l.ritmo >= comp end) order by u.nombre, d.desde), '[]'::jsonb)
  into res
  from dl d join var_usuarios u on u.auth_uid = d.lider_uid join var_usuarios t on t.auth_uid = d.titular
  left join lider l on l.lider_uid = d.lider_uid and l.titular = d.titular;
  return res;
end $fn$;
revoke all on function public.var_reemplazos_mes(date) from public, anon, authenticated;
