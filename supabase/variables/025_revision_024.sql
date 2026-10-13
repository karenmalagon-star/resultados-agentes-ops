-- ============================================================================
-- Módulo de Variables · 025 · Correcciones de la revisión adversarial de la 024 (9-oct-2026)
--  1) var_lideres_mes: los días firmados por un reemplazo se le acreditan al titular (reemplazo_de) de esa semana.
--  2/3) var_resumen_mes: un solo líder por turno en `lid` (titular; si solo hay fila de reemplazo, el titular que cubre).
--  4/5) tardes: solo cuentan los días con asignación trabajada; el valor manual de Admin manda; sin registros = null (no 0).
--  7) var_auditoria.actualizado_en para que la alarma del equipo suene cuando se agrega un tipo a un registro existente.
--  15) var_auditoria_tablero / var_auditoria_detalle: la CTE de tipos se restringe a los registros del período.
-- ============================================================================
alter table public.var_auditoria add column if not exists actualizado_en timestamptz not null default now();
create index if not exists var_auditoria_actualizado_idx on public.var_auditoria (actualizado_en);

create or replace function public.var_puntualidad_mes(p_mes date) returns jsonb language sql stable set search_path = public, pg_temp as $$
  with pd as (
    select p.agent_id, p.fecha, p.tarde from var_puntualidad_dia p
    where p.fecha >= p_mes and p.fecha < (p_mes + interval '1 month')::date
      and exists (select 1 from var_asignacion s where s.vigente and s.fecha = p.fecha and s.agent_id = p.agent_id and s.estado not in ('ausencia','incapacidad','vacaciones')))
  select coalesce(jsonb_agg(jsonb_build_object('agent_id', g.agent_id, 'nombre', g.nombre,
           'tardes', (select count(*)::int from pd where pd.agent_id = g.agent_id and pd.tarde),
           'dias', (select count(*)::int from pd where pd.agent_id = g.agent_id),
           'manual', (select m.valor from var_manual m where m.mes = p_mes and m.sujeto_tipo = 'agente' and m.sujeto_id = g.agent_id and m.cargo is null and m.clave = 'dias_tarde' and m.vigente limit 1)) order by g.nombre), '[]'::jsonb)
  from var_agente g where (g.activo and (g.hasta is null or g.hasta >= p_mes)) or exists (select 1 from pd where pd.agent_id = g.agent_id);
$$;
revoke all on function public.var_puntualidad_mes(date) from public, anon, authenticated;

create or replace function public.var_auditoria_tablero(p_mes date, p_pais text default null, p_agent_id text default null, p_color text default null, p_tienda text default null, p_medio_id int default null)
returns jsonb language sql stable set search_path = public, pg_temp as $$
  with
  m6 as (select (p_mes - (i || ' month')::interval)::date mes from generate_series(0, 5) i),
  base as (
    select a.id, a.agent_id, a.orden, a.pais, a.tienda, a.medio_id, a.tipo_id, a.fecha_auditoria, date_trunc('month', a.fecha_auditoria)::date mes
    from var_auditoria a
    where a.anulado_por is null
      and a.fecha_auditoria >= (p_mes - interval '5 month')::date and a.fecha_auditoria < (p_mes + interval '1 month')::date
      and (p_pais is null or a.pais = p_pais) and (p_agent_id is null or a.agent_id = p_agent_id)
      and (p_tienda is null or a.tienda = p_tienda) and (p_medio_id is null or a.medio_id = p_medio_id)),
  tp as (
    select distinct x.auditoria_id, x.tipo_id, t.nombre, t.color
    from (select at.auditoria_id, at.tipo_id from var_auditoria_tipo at where at.auditoria_id in (select id from base)
          union select b.id, b.tipo_id from base b where b.tipo_id is not null) x
    join var_error_tipo t on t.id = x.tipo_id
    where p_color is null or t.color = p_color),
  reg as (select b.* from base b where exists (select 1 from tp where tp.auditoria_id = b.id)),
  reg_m as (select * from reg where mes = p_mes),
  aud_m as (select coalesce(sum(t.total), 0)::int total from var_auditadas t where t.mes = p_mes and t.vigente and (p_agent_id is null or t.agent_id = p_agent_id)),
  col as (select t.color, count(*)::int n from tp t join reg_m r on r.id = t.auditoria_id group by 1),
  cat as (select t.tipo_id, t.nombre, t.color,
            count(*) filter (where r.mes = p_mes)::int n,
            count(*) filter (where r.mes = (p_mes - interval '1 month')::date)::int n_prev
          from tp t join reg r on r.id = t.auditoria_id group by 1, 2, 3 having count(*) filter (where r.mes = p_mes) > 0 or count(*) filter (where r.mes = (p_mes - interval '1 month')::date) > 0),
  med as (select coalesce(g.nombre, 'Sin medio') nombre, count(*)::int n from reg_m r left join var_medio_gestion g on g.id = r.medio_id group by 1),
  mm as (select m.mes,
            (select coalesce(sum(t.total), 0)::int from var_auditadas t where t.mes = m.mes and t.vigente and (p_agent_id is null or t.agent_id = p_agent_id)) auditadas,
            (select count(*)::int from reg r where r.mes = m.mes) con_error,
            (select count(*)::int from tp t join reg r on r.id = t.auditoria_id where r.mes = m.mes and t.color = 'rojo') rojo,
            (select count(*)::int from tp t join reg r on r.id = t.auditoria_id where r.mes = m.mes and t.color = 'amarillo') amarillo,
            (select count(*)::int from tp t join reg r on r.id = t.auditoria_id where r.mes = m.mes and t.color = 'verde') verde
         from m6 m),
  ag as (select g.agent_id, g.nombre,
            (select coalesce(sum(t.total), 0)::int from var_auditadas t where t.mes = p_mes and t.vigente and t.agent_id = g.agent_id) auditadas,
            (select count(*)::int from reg_m r where r.agent_id = g.agent_id) con_error,
            (select count(*)::int from tp t join reg_m r on r.id = t.auditoria_id where r.agent_id = g.agent_id and t.color = 'rojo') rojo,
            (select count(*)::int from tp t join reg_m r on r.id = t.auditoria_id where r.agent_id = g.agent_id and t.color = 'amarillo') amarillo,
            (select count(*)::int from tp t join reg_m r on r.id = t.auditoria_id where r.agent_id = g.agent_id and t.color = 'verde') verde
         from var_agente g
         where (p_agent_id is null or g.agent_id = p_agent_id)
           and (exists (select 1 from reg_m r where r.agent_id = g.agent_id) or exists (select 1 from var_auditadas t where t.mes = p_mes and t.vigente and t.agent_id = g.agent_id and t.total > 0)))
  select jsonb_build_object(
    'mes', to_char(p_mes, 'YYYY-MM'),
    'filtros', jsonb_build_object('pais', p_pais, 'agent_id', p_agent_id, 'color', p_color, 'tienda', p_tienda, 'medio_id', p_medio_id),
    'resumen', jsonb_build_object('auditadas', (select total from aud_m), 'con_error', (select count(*) from reg_m),
       'pct', (select case when total > 0 then round((select count(*) from reg_m) * 100::numeric / total, 1) end from aud_m),
       'rojo', coalesce((select n from col where color = 'rojo'), 0), 'amarillo', coalesce((select n from col where color = 'amarillo'), 0), 'verde', coalesce((select n from col where color = 'verde'), 0),
       'medios', coalesce((select jsonb_agg(jsonb_build_object('nombre', nombre, 'n', n) order by n desc, nombre) from med), '[]'::jsonb)),
    'por_categoria', coalesce((select jsonb_agg(jsonb_build_object('tipo_id', tipo_id, 'nombre', nombre, 'color', color, 'n', n, 'n_prev', n_prev) order by n desc, n_prev desc, nombre) from cat), '[]'::jsonb),
    'mes_a_mes', coalesce((select jsonb_agg(jsonb_build_object('mes', to_char(mes, 'YYYY-MM'), 'auditadas', auditadas, 'con_error', con_error,
       'pct', case when auditadas > 0 then round(con_error * 100::numeric / auditadas, 1) end, 'rojo', rojo, 'amarillo', amarillo, 'verde', verde) order by mes) from mm), '[]'::jsonb),
    'por_agente', coalesce((select jsonb_agg(jsonb_build_object('agent_id', agent_id, 'nombre', nombre, 'auditadas', auditadas, 'con_error', con_error,
       'pct', case when auditadas > 0 then round(con_error * 100::numeric / auditadas, 1) end, 'rojo', rojo, 'amarillo', amarillo, 'verde', verde) order by nombre) from ag), '[]'::jsonb),
    'paises', coalesce((select jsonb_agg(distinct pais) from var_auditoria where pais is not null), '[]'::jsonb),
    'tiendas', coalesce((select jsonb_agg(distinct tienda) from var_auditoria where tienda is not null and (p_pais is null or pais = p_pais)), '[]'::jsonb)
  );
$$;
revoke all on function public.var_auditoria_tablero(date, text, text, text, text, int) from public, anon, authenticated;

create or replace function public.var_auditoria_detalle(p_mes date, p_agent_id text, p_pais text default null, p_color text default null, p_tienda text default null, p_medio_id int default null)
returns jsonb language sql stable set search_path = public, pg_temp as $$
  with cand as (
    select a.* from var_auditoria a
    where a.anulado_por is null and a.agent_id = p_agent_id
      and a.fecha_auditoria >= p_mes and a.fecha_auditoria < (p_mes + interval '1 month')::date
      and (p_pais is null or a.pais = p_pais) and (p_tienda is null or a.tienda = p_tienda) and (p_medio_id is null or a.medio_id = p_medio_id)),
  tp as (
    select distinct x.auditoria_id, x.tipo_id, t.nombre, t.color
    from (select at.auditoria_id, at.tipo_id from var_auditoria_tipo at where at.auditoria_id in (select id from cand)
          union select c.id, c.tipo_id from cand c where c.tipo_id is not null) x
    join var_error_tipo t on t.id = x.tipo_id),
  reg as (select c.* from cand c where p_color is null or exists (select 1 from tp where tp.auditoria_id = c.id and tp.color = p_color) order by c.fecha_auditoria desc, c.momento desc limit 500)
  select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'orden', r.orden, 'fecha_auditoria', r.fecha_auditoria, 'fecha_gestion', r.fecha_gestion, 'tienda', r.tienda, 'pais', r.pais,
           'medio', (select g.nombre from var_medio_gestion g where g.id = r.medio_id), 'descripcion', r.descripcion,
           'tipos', (select coalesce(jsonb_agg(jsonb_build_object('id', t.tipo_id, 'nombre', t.nombre, 'color', t.color) order by t.nombre), '[]'::jsonb) from tp t where t.auditoria_id = r.id),
           'adjuntos', (select coalesce(jsonb_agg(jsonb_build_object('id', j.id, 'nombre', j.nombre, 'bytes', j.bytes) order by j.id), '[]'::jsonb) from var_auditoria_adjunto j where j.auditoria_id = r.id))
         order by r.fecha_auditoria desc, r.momento desc), '[]'::jsonb)
  from reg r;
$$;
revoke all on function public.var_auditoria_detalle(date, text, text, text, text, int) from public, anon, authenticated;

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
  -- 1) var_lideres_mes: la firma del reemplazo se acredita al titular de esa semana
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'var_lideres_mes';
  d := pg_temp.sub(d, 'asg as (select fecha, agent_id, turno, estado, lider_uid from var_asignacion where vigente and fecha between p_mes and d_fin),',
                      'asg as (select a.fecha, a.agent_id, a.turno, a.estado,
       coalesce((select ls.reemplazo_de from var_lider_semana ls where ls.lider_uid = a.lider_uid and ls.reemplazo_de is not null
                   and ls.semana = (a.fecha - (extract(isodow from a.fecha)::int - 1))::date), a.lider_uid) lider_uid
     from var_asignacion a where a.vigente and a.fecha between p_mes and d_fin),');
  execute d;
  -- 2/3/5) var_resumen_mes
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'var_resumen_mes';
  d := pg_temp.sub(d, 'lid as (select ls.turno, u.nombre, u.etiqueta from var_lider_semana ls join var_usuarios u on u.auth_uid = ls.lider_uid where ls.semana = v_semana and ls.reemplazo_de is null),',
                      'lid as (select distinct on (ls.turno) ls.turno, u.nombre, u.etiqueta from var_lider_semana ls join var_usuarios u on u.auth_uid = coalesce(ls.reemplazo_de, ls.lider_uid) where ls.semana = v_semana order by ls.turno, (ls.reemplazo_de is null) desc, u.nombre),');
  d := pg_temp.sub(d, '''tardes'', (select count(*)::int from var_puntualidad_dia pd where pd.agent_id = g.agent_id and pd.tarde and pd.fecha between p_mes and fin_mes),',
                      '''tardes'', coalesce((select m.valor::int from var_manual m where m.mes = p_mes and m.sujeto_tipo = ''agente'' and m.sujeto_id = g.agent_id and m.cargo is null and m.clave = ''dias_tarde'' and m.vigente limit 1),
                   (select case when count(*) = 0 then null else count(*) filter (where pd.tarde) end from var_puntualidad_dia pd where pd.agent_id = g.agent_id and pd.fecha between p_mes and fin_mes
                      and exists (select 1 from var_asignacion s where s.vigente and s.fecha = pd.fecha and s.agent_id = pd.agent_id and s.estado not in (''ausencia'',''incapacidad'',''vacaciones'')))),');
  execute d;
  -- 4) var_calcular_mes: solo días con asignación trabajada
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'var_calcular_mes';
  d := pg_temp.sub(d, 'pd.fecha < (p_mes + interval ''1 month'')::date',
                      'pd.fecha < (p_mes + interval ''1 month'')::date and exists (select 1 from var_asignacion s where s.vigente and s.fecha = pd.fecha and s.agent_id = pd.agent_id and s.estado not in (''ausencia'',''incapacidad'',''vacaciones''))', 2);
  execute d;
end $do$;
