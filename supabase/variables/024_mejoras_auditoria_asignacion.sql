-- ============================================================================
-- Módulo de Variables · 024 · Mejoras de Auditoría, Errores y Asignación (inputs 30/31, maqueta v19 aprobada el 9-oct-2026)
--  A) Asignación: estado 'vacaciones' (igual que ausencia: no hábil, no medido).
--  B) Puntualidad diaria: var_puntualidad_dia (el líder marca "llegó tarde"); var_calcular_mes toma la suma del mes
--     salvo que exista un valor manual vigente (corrección de Admin). var_resumen_mes expone 'tardes' por agente.
--  C) Líderes por semana: columna reemplazo_de (cubre operativamente, sin variable): var_resumen_mes solo muestra titulares
--     en 'lideres'; var_lideres_mes excluye a quien solo fue reemplazo en el mes.
--  D) Medio de gestión: catálogo var_medio_gestion (admin/auditoría agregan) + var_auditoria.medio_id.
--  E) Tablero de auditoría: var_auditoria_tablero (filtros país/agente/color/tienda/medio; por categoría, mes a mes, por agente)
--     y var_auditoria_detalle (registros de un agente con los mismos filtros).
--  Las funciones grandes existentes (var_resumen_mes, var_lideres_mes, var_calcular_mes) se modifican por sustitución
--  textual sobre su definición vigente, con verificación de que cada fragmento exista exactamente una vez.
-- ============================================================================

-- A) vacaciones
alter table public.var_asignacion drop constraint if exists var_asignacion_estado_check;
alter table public.var_asignacion add constraint var_asignacion_estado_check
  check (estado in ('verificacion','v_historica','novedades','agente_whatsapp','apoyo','ausencia','incapacidad','vacaciones'));

-- B) puntualidad diaria
create table if not exists public.var_puntualidad_dia (
  fecha          date not null,
  agent_id       text not null references public.var_agente(agent_id),
  tarde          boolean not null default false,
  registrado_por uuid not null,
  creado_en      timestamptz not null default now(),
  primary key (fecha, agent_id)
);
alter table public.var_puntualidad_dia enable row level security;
create index if not exists var_puntualidad_dia_agente_idx on public.var_puntualidad_dia (agent_id, fecha);

create or replace function public.var_puntualidad_mes(p_mes date) returns jsonb language sql stable set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object('agent_id', g.agent_id, 'nombre', g.nombre,
           'tardes', (select count(*)::int from var_puntualidad_dia p where p.agent_id = g.agent_id and p.tarde and p.fecha >= p_mes and p.fecha < (p_mes + interval '1 month')::date),
           'dias', (select count(*)::int from var_puntualidad_dia p where p.agent_id = g.agent_id and p.fecha >= p_mes and p.fecha < (p_mes + interval '1 month')::date),
           'manual', (select m.valor from var_manual m where m.mes = p_mes and m.sujeto_tipo = 'agente' and m.sujeto_id = g.agent_id and m.cargo is null and m.clave = 'dias_tarde' and m.vigente limit 1)) order by g.nombre), '[]'::jsonb)
  from var_agente g where (g.activo and (g.hasta is null or g.hasta >= p_mes)) or exists (select 1 from var_puntualidad_dia p where p.agent_id = g.agent_id and p.fecha >= p_mes and p.fecha < (p_mes + interval '1 month')::date);
$$;
revoke all on function public.var_puntualidad_mes(date) from public, anon, authenticated;

-- C) reemplazo de líder
alter table public.var_lider_semana add column if not exists reemplazo_de uuid references public.var_usuarios(auth_uid);

-- D) medio de gestión
create table if not exists public.var_medio_gestion (
  id          serial primary key,
  nombre      text not null check (length(trim(nombre)) >= 2),
  nombre_norm text not null unique,
  activo      boolean not null default true,
  orden       int not null default 0,
  creado_por  uuid,
  creado_en   timestamptz not null default now()
);
alter table public.var_medio_gestion enable row level security;
insert into public.var_medio_gestion (nombre, nombre_norm, orden) values
  ('Barrido','barrido',1),('Novedades','novedades',2),('Llamadas','llamadas',3),('Chat','chat',4),('Parámetros','parametros',5),('Histórico','historico',6)
on conflict (nombre_norm) do nothing;
alter table public.var_auditoria add column if not exists medio_id int references public.var_medio_gestion(id);
create index if not exists var_auditoria_medio_idx on public.var_auditoria (medio_id);
create index if not exists var_auditoria_fecha_idx on public.var_auditoria (fecha_auditoria) where anulado_por is null;

-- E) tablero de auditoría
create or replace function public.var_auditoria_tablero(p_mes date, p_pais text default null, p_agent_id text default null, p_color text default null, p_tienda text default null, p_medio_id int default null)
returns jsonb language sql stable set search_path = public, pg_temp as $$
  with
  m6 as (select (p_mes - (i || ' month')::interval)::date mes from generate_series(0, 5) i),
  base as (  -- registros vigentes de los últimos 6 meses con los filtros que no son de mes
    select a.id, a.agent_id, a.orden, a.pais, a.tienda, a.medio_id, a.fecha_auditoria, date_trunc('month', a.fecha_auditoria)::date mes
    from var_auditoria a
    where a.anulado_por is null
      and a.fecha_auditoria >= (p_mes - interval '5 month')::date and a.fecha_auditoria < (p_mes + interval '1 month')::date
      and (p_pais is null or a.pais = p_pais) and (p_agent_id is null or a.agent_id = p_agent_id)
      and (p_tienda is null or a.tienda = p_tienda) and (p_medio_id is null or a.medio_id = p_medio_id)),
  tp as (  -- tipos por registro (tabla puente + tipo principal de registros antiguos)
    select distinct x.auditoria_id, x.tipo_id, t.nombre, t.color
    from (select auditoria_id, tipo_id from var_auditoria_tipo union select id, tipo_id from var_auditoria where tipo_id is not null) x
    join var_error_tipo t on t.id = x.tipo_id
    where p_color is null or t.color = p_color),
  reg as (select b.* from base b where exists (select 1 from tp where tp.auditoria_id = b.id)),   -- con filtro de color, solo registros que tengan ese color
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
  with tp as (
    select distinct x.auditoria_id, x.tipo_id, t.nombre, t.color
    from (select auditoria_id, tipo_id from var_auditoria_tipo union select id, tipo_id from var_auditoria where tipo_id is not null) x
    join var_error_tipo t on t.id = x.tipo_id),
  reg as (
    select a.* from var_auditoria a
    where a.anulado_por is null and a.agent_id = p_agent_id
      and a.fecha_auditoria >= p_mes and a.fecha_auditoria < (p_mes + interval '1 month')::date
      and (p_pais is null or a.pais = p_pais) and (p_tienda is null or a.tienda = p_tienda) and (p_medio_id is null or a.medio_id = p_medio_id)
      and (p_color is null or exists (select 1 from tp where tp.auditoria_id = a.id and tp.color = p_color))
    order by a.fecha_auditoria desc, a.momento desc limit 500)
  select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'orden', r.orden, 'fecha_auditoria', r.fecha_auditoria, 'fecha_gestion', r.fecha_gestion, 'tienda', r.tienda, 'pais', r.pais,
           'medio', (select g.nombre from var_medio_gestion g where g.id = r.medio_id), 'descripcion', r.descripcion,
           'tipos', (select coalesce(jsonb_agg(jsonb_build_object('id', t.tipo_id, 'nombre', t.nombre, 'color', t.color) order by t.nombre), '[]'::jsonb) from tp t where t.auditoria_id = r.id),
           'adjuntos', (select coalesce(jsonb_agg(jsonb_build_object('id', j.id, 'nombre', j.nombre, 'bytes', j.bytes) order by j.id), '[]'::jsonb) from var_auditoria_adjunto j where j.auditoria_id = r.id))
         order by r.fecha_auditoria desc, r.momento desc), '[]'::jsonb)
  from reg r;
$$;
revoke all on function public.var_auditoria_detalle(date, text, text, text, text, int) from public, anon, authenticated;

-- F) sustituciones textuales sobre las funciones vigentes (cada fragmento debe existir exactamente una vez)
create or replace function pg_temp.sub(p_def text, p_old text, p_new text) returns text language plpgsql as $$
begin
  if (length(p_def) - length(replace(p_def, p_old, ''))) / length(p_old) <> 1 then
    raise exception 'fragmento no encontrado exactamente una vez: %', left(p_old, 80);
  end if;
  return replace(p_def, p_old, p_new);
end $$;

do $do$
declare d text;
begin
  -- var_resumen_mes: líderes titulares; vacaciones en sin_asignar; tardes por agente
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'var_resumen_mes';
  d := pg_temp.sub(d, 'from var_lider_semana ls join var_usuarios u on u.auth_uid = ls.lider_uid where ls.semana = v_semana)',
                      'from var_lider_semana ls join var_usuarios u on u.auth_uid = ls.lider_uid where ls.semana = v_semana and ls.reemplazo_de is null)');
  d := pg_temp.sub(d, 'd.estado in (''ausencia'',''incapacidad'')', 'd.estado in (''ausencia'',''incapacidad'',''vacaciones'')');
  d := pg_temp.sub(d, '''errores'', coalesce((select e.errores from aude e where e.agent_id = g.agent_id), 0),',
                      '''errores'', coalesce((select e.errores from aude e where e.agent_id = g.agent_id), 0), ''tardes'', (select count(*)::int from var_puntualidad_dia pd where pd.agent_id = g.agent_id and pd.tarde and pd.fecha between p_mes and fin_mes),');
  execute d;
  -- var_lideres_mes: quien solo fue reemplazo en el mes no entra al pago
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'var_lideres_mes';
  d := pg_temp.sub(d, 'where u.rol <> ''admin'' and ((u.activo and (u.rol = ''equipo'' or u.etiqueta is not null)) or coalesce(d.dias_liderados, 0) > 0);',
                      'where u.rol <> ''admin'' and ((u.activo and (u.rol = ''equipo'' or u.etiqueta is not null)) or coalesce(d.dias_liderados, 0) > 0)
    and not (exists (select 1 from var_lider_semana ls where ls.lider_uid = u.auth_uid and ls.reemplazo_de is not null and ls.semana >= (p_mes - interval ''6 day'')::date and ls.semana < (p_mes + interval ''1 month'')::date)
             and not exists (select 1 from var_lider_semana ls where ls.lider_uid = u.auth_uid and ls.reemplazo_de is null and ls.semana >= (p_mes - interval ''6 day'')::date and ls.semana < (p_mes + interval ''1 month'')::date));');
  execute d;
  -- var_calcular_mes: días tarde = valor manual vigente, o la suma de los días marcados por el líder
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'var_calcular_mes';
  d := pg_temp.sub(d, 'if dias_tarde is null then f_pu := null; pend := pend || ''"puntualidad sin digitar (se estima como cumplida)"''::jsonb; else f_pu := case when dias_tarde < 3 then 1 else 0 end; end if;',
                      'if dias_tarde is null then
      if exists (select 1 from var_puntualidad_dia pd where pd.agent_id = ag->>''agent_id'' and pd.fecha >= p_mes and pd.fecha < (p_mes + interval ''1 month'')::date) then
        select count(*) into dias_tarde from var_puntualidad_dia pd where pd.agent_id = ag->>''agent_id'' and pd.tarde and pd.fecha >= p_mes and pd.fecha < (p_mes + interval ''1 month'')::date;
      end if;
    end if;
    if dias_tarde is null then f_pu := null; pend := pend || ''"puntualidad sin registros del líder (se estima como cumplida)"''::jsonb; else f_pu := case when dias_tarde < 3 then 1 else 0 end; end if;');
  execute d;
end $do$;
