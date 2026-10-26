-- ============================================================================
-- Módulo de Variables · 029 · Correcciones de la revisión adversarial de la 028 (23-oct-2026)
--  1/2/7/9) var_replicar_asignacion: el origen solo dentro de la misma semana (el martes copia el lunes; tras un lunes festivo sin
--     asignación el martes queda manual), solo filas copiables; el líder se re-resuelve por semana y turno (titular activo; si ese día
--     tiene ausencia registrada, el reemplazo); sin líder válido la fila no se replica; es_na toma el cargo permanente vigente.
--     Los festivos sí se replican: la operación trabaja festivos (4,5 h efectivas en la configuración).
--  4) Borrar ausencias del líder de un mes liquidado queda bloqueado (trigger before delete).
--  5) var_asignacion_quitar: solo personas de apoyo (admin puede cualquiera), sin fechas futuras, con rastro (quitado_por/quitado_en).
--  10) var_asignacion.revisada_por/revisada_en: el líder puede confirmar una réplica sin cambios.
--  14) var_reemplazos_mes: solo los días en que el titular tenía ausencia registrada (un día es del titular o del reemplazo, nunca de ambos).
--  15) var_resumen_mes: la fila del líder muestra al reemplazo los días en que el titular está ausente.
-- ============================================================================
alter table public.var_asignacion add column if not exists quitado_por uuid, add column if not exists quitado_en timestamptz,
                                  add column if not exists revisada_por uuid, add column if not exists revisada_en timestamptz;

create or replace function public.var_replicar_asignacion(p_fecha date) returns jsonb language plpgsql set search_path = public, pg_temp as $fn$
declare origen date; n int := 0; lunes date := (p_fecha - (extract(isodow from p_fecha)::int - 1))::date;
begin
  if extract(isodow from p_fecha) not between 2 and 6 then return jsonb_build_object('fecha', p_fecha, 'replicadas', 0, 'motivo', 'solo de martes a sábado'); end if;
  if exists (select 1 from var_asignacion where fecha = p_fecha and vigente) then return jsonb_build_object('fecha', p_fecha, 'replicadas', 0, 'motivo', 'ya hay asignación'); end if;
  select max(s.fecha) into origen from var_asignacion s join var_agente g on g.agent_id = s.agent_id
   where s.vigente and s.fecha < p_fecha and s.fecha >= lunes and not g.es_apoyo and s.estado not in ('ausencia','incapacidad');
  if origen is null then return jsonb_build_object('fecha', p_fecha, 'replicadas', 0, 'motivo', 'sin asignación copiable en esta semana: el líder debe asignar a mano'); end if;
  insert into var_asignacion (fecha, agent_id, turno, estado, lider_uid, vigente, creado_por, es_na, replicada)
  select p_fecha, x.agent_id, x.turno, x.estado, x.lider, true, x.lider, x.es_na, true
  from (
    select s.agent_id, s.turno, case when s.es_na then g.cargo_permanente else s.estado end estado, s.es_na,
           coalesce(
             (select ls.lider_uid from var_lider_semana ls join var_usuarios u on u.auth_uid = ls.lider_uid and u.activo
               where ls.semana = lunes and ls.turno = s.turno
               order by exists (select 1 from var_lider_dia ld where ld.lider_uid = ls.lider_uid and ld.fecha = p_fecha) asc, (ls.reemplazo_de is null) desc, ls.lider_uid limit 1),
             (select u.auth_uid from var_usuarios u where u.auth_uid = s.lider_uid and u.activo
               and not exists (select 1 from var_lider_dia ld where ld.lider_uid = u.auth_uid and ld.fecha = p_fecha))) lider
    from var_asignacion s join var_agente g on g.agent_id = s.agent_id
    where s.vigente and s.fecha = origen and g.activo and (g.hasta is null or g.hasta >= p_fecha) and not g.es_apoyo and s.estado not in ('ausencia','incapacidad')
  ) x where x.lider is not null;
  get diagnostics n = row_count;
  return jsonb_build_object('fecha', p_fecha, 'origen', origen, 'replicadas', n);
end $fn$;
revoke all on function public.var_replicar_asignacion(date) from public, anon, authenticated;

-- 4) nada se borra de un mes liquidado
create or replace function public.var_bloquear_mes_liquidado_del() returns trigger language plpgsql set search_path = public, pg_temp as $fn$
begin
  if exists (select 1 from public.var_liquidacion l where l.estado = 'liquidado' and l.mes = date_trunc('month', old.fecha)::date) then
    raise exception 'El mes % está liquidado: no se puede modificar', to_char(old.fecha, 'YYYY-MM') using errcode = 'P0001';
  end if;
  return old;
end $fn$;
drop trigger if exists trg_var_lider_dia_liq_del on public.var_lider_dia;
create trigger trg_var_lider_dia_liq_del before delete on public.var_lider_dia for each row execute function public.var_bloquear_mes_liquidado_del();

-- 5) quitar solo apoyo, con rastro
create or replace function public.var_asignacion_quitar(p_fecha date, p_agent_id text, p_actor uuid) returns int language plpgsql set search_path = public, pg_temp as $fn$
declare n int;
begin
  if p_fecha > var_hoy_col() then raise exception 'No se puede modificar una fecha futura' using errcode = 'P0002'; end if;
  if not exists (select 1 from var_agente g where g.agent_id = p_agent_id and g.es_apoyo)
     and not exists (select 1 from var_usuarios u where u.auth_uid = p_actor and u.rol = 'admin') then
    raise exception 'Solo se puede quitar de la asignación a personas de apoyo' using errcode = 'P0031';
  end if;
  update var_asignacion set vigente = false, quitado_por = p_actor, quitado_en = now() where fecha = p_fecha and agent_id = p_agent_id and vigente;
  get diagnostics n = row_count;
  return n;
end $fn$;
revoke all on function public.var_asignacion_quitar(date, text, uuid) from public, anon, authenticated;

-- 14) reemplazo: solo los días con ausencia registrada del titular
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
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'var_reemplazos_mes';
  d := pg_temp.sub(d, 'where a.vigente and a.fecha between p_mes and d_fin),
  ev as', 'where a.vigente and a.fecha between p_mes and d_fin
           and exists (select 1 from var_lider_dia ld where ld.lider_uid = ls.reemplazo_de and ld.fecha = a.fecha)),
  ev as');
  execute d;
  -- 15) fila del líder en el Resumen: el reemplazo los días en que el titular está ausente
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'var_resumen_mes';
  d := pg_temp.sub(d, 'lid as (select distinct on (ls.turno) ls.turno, u.nombre, u.etiqueta from var_lider_semana ls join var_usuarios u on u.auth_uid = coalesce(ls.reemplazo_de, ls.lider_uid) where ls.semana = v_semana order by ls.turno, (ls.reemplazo_de is null) desc, u.nombre),',
                      'lid as (select distinct on (ls.turno) ls.turno, u.nombre, u.etiqueta from var_lider_semana ls join var_usuarios u on u.auth_uid = ls.lider_uid where ls.semana = v_semana order by ls.turno, exists (select 1 from var_lider_dia ld where ld.lider_uid = ls.lider_uid and ld.fecha = dia) asc, (ls.reemplazo_de is null) desc, u.nombre),');
  execute d;
end $do$;
