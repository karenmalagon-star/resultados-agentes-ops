-- ============================================================================
-- Módulo de Variables · 030 · Rendimiento y Pago del mes por rango (input 35, 4-nov-2026)
--  A) var_personas_historico tardaba ~10 s (aplicaba var_norm/var_es_excluido a las 148.000 gestiones): ahora toma primero los
--     nombres distintos (31) y filtra después; índice por agente. Era la causa de los "statement timeout" al abrir Asignación.
--  B) var_calcular_mes(p_mes, p_desde, p_hasta): el pago estimado de los agentes se puede ver por un rango de fechas dentro del mes
--     (los días en el cargo son los del rango; el prorrateo sigue siendo sobre los días hábiles del mes completo). Los líderes siguen
--     siendo del mes completo.
-- ============================================================================
create index if not exists events_history_agent_idx on public.events_history (agent);

create or replace function public.var_personas_historico() returns jsonb language sql stable set search_path = public, pg_temp as $$
  with ag as materialized (select distinct e.agent as nombre from events_history e where e.agent is not null),   -- materialized: sin esto el planificador empuja var_es_excluido (immutable) debajo del DISTINCT y lo evalúa 148.000 veces
  n as (
    select m.name as nombre, m.id as agent_id, 1 as pri from agent_map m where m.name is not null and not var_es_excluido(m.name)
    union all
    select ag.nombre, null, 2 from ag where not var_es_excluido(ag.nombre)
  ), d as (select distinct on (var_norm(nombre)) var_norm(nombre) norm, nombre, agent_id from n order by var_norm(nombre), pri, nombre)
  select coalesce(jsonb_agg(jsonb_build_object('nombre', d.nombre, 'agent_id', d.agent_id) order by d.nombre), '[]'::jsonb)
  from d where length(d.norm) >= 3 and not exists (select 1 from var_agente_alias al where al.nombre_norm = d.norm);
$$;
revoke all on function public.var_personas_historico() from public, anon, authenticated;

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
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'var_calcular_mes' and pg_get_function_identity_arguments(p.oid) = 'p_mes date';
  d := pg_temp.sub(d, 'CREATE OR REPLACE FUNCTION public.var_calcular_mes(p_mes date)', 'CREATE OR REPLACE FUNCTION public.var_calcular_mes(p_mes date, p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL)');
  d := pg_temp.sub(d, 'r jsonb := var_resumen_mes(p_mes);', 'r jsonb := var_resumen_mes(p_mes, null, p_desde, p_hasta);');
  drop function public.var_calcular_mes(date);
  execute d;
end $do$;
revoke all on function public.var_calcular_mes(date, date, date) from public, anon, authenticated;
