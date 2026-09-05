-- ============================================================================
-- Módulo de Variables · 003 · Funciones SQL (DISENO_TECNICO_VARIABLES.md §5)
-- Sprint 1: ayudantes, configuración, asignación atómica y RESUMEN DE PORCENTAJES.
-- Sin dinero (var_calcular_mes y var_liquidar llegan en el Sprint 2 con panel adversarial).
-- Toda aritmética en numeric; una sola división por cumplimiento; round() de numeric
-- redondea empates alejándose de cero (= half-up para positivos).
-- ============================================================================

-- ---------- Tiempo (siempre hora Colombia) ----------
create or replace function public.var_hoy_col() returns date
language sql stable as $$ select (now() at time zone 'America/Bogota')::date $$;

create or replace function public.var_ahora_col() returns timestamp
language sql stable as $$ select (now() at time zone 'America/Bogota') $$;

-- ---------- Texto: mismo comportamiento que norm() de _shared/rules.ts ----------
create or replace function public.var_norm(s text) returns text
language sql immutable as $$
  select lower(regexp_replace(trim(translate(coalesce(s,''),
    'áéíóúüñÁÉÍÓÚÜÑàèìòùÀÈÌÒÙâêîôûÂÊÎÔÛ', 'aeiouunAEIOUUNaeiouAEIOUaeiouAEIOU')), '\s+', ' ', 'g'))
$$;

-- Pseudo-agentes (buzones internos) — mismos patrones que EXCLUDED_AGENT_PATTERNS de rules.ts.
create or replace function public.var_es_excluido(nombre text) returns boolean
language sql immutable as $$
  select public.var_norm(nombre) ~ '(postfecha|reprogramadas operacion|sin gestion|seguimiento historico)'
$$;

-- ---------- Calendario ----------
create or replace function public.var_es_festivo(d date) returns boolean
language sql stable as $$
  select exists (
    select 1 from public.app_config c, jsonb_array_elements_text(c.value::jsonb) f
    where c.key = 'festivos_co' and f = to_char(d, 'YYYY-MM-DD'))
$$;

-- Día hábil = lunes a sábado (K1). El domingo NUNCA es hábil, aunque sea festivo.
create or replace function public.var_es_habil(d date) returns boolean
language sql immutable as $$ select extract(isodow from d) between 1 and 6 $$;

create or replace function public.var_dias_habiles(p_mes date) returns integer
language sql immutable as $$
  select count(*)::integer from generate_series(p_mes, (p_mes + interval '1 month' - interval '1 day')::date, interval '1 day') d
  where public.var_es_habil(d::date)
$$;

-- ---------- Configuración del mes (spec §2, diseño §4.1) ----------
create or replace function public.var_config_default(p_mes date) returns jsonb
language sql immutable as $$
  select jsonb_build_object(
    'fin_revision', to_char((p_mes + interval '1 month' + interval '6 days')::date, 'YYYY-MM-DD'),
    'horas_efectivas', jsonb_build_object(
        'M', jsonb_build_object('1-4', 6.5, '5', 5.5, '6', 4.5, 'festivo', 4.5),
        'T', jsonb_build_object('1-4', 6.5, '5', 6.5, '6', 5.5, 'festivo', 5.5)),
    'compuerta_ritmo', 38,
    'escalera', jsonb_build_array(
        jsonb_build_object('desde_excl', 110.0, 'factor', 1.5),
        jsonb_build_object('desde', 100.0, 'hasta', 110.0, 'factor', 'parte_entera'),
        jsonb_build_object('desde', 95.0, 'factor', 0.95),
        jsonb_build_object('desde', 90.0, 'factor', 0.80),
        jsonb_build_object('factor', 0)),
    'cargos', jsonb_build_object(
        'verificacion', jsonb_build_object('nombre', 'Verificación', 'medible', true, 'valor', 100000, 'variables', jsonb_build_array(
            jsonb_build_object('clave', 'efectividad', 'tipo', 'prop', 'dir', 'mas',   'meta', 75, 'peso', 50),
            jsonb_build_object('clave', 'cancelacion', 'tipo', 'prop', 'dir', 'menos', 'meta', 18, 'peso', 35),
            jsonb_build_object('clave', 'puntualidad', 'tipo', 'todo_o_nada', 'regla', 'dias_tarde<3', 'peso', 15))),
        'v_historica', jsonb_build_object('nombre', 'Verificación Histórica', 'medible', true, 'valor', 100000, 'variables', jsonb_build_array(
            jsonb_build_object('clave', 'efectividad', 'tipo', 'prop', 'dir', 'mas',   'meta', 85, 'peso', 50),
            jsonb_build_object('clave', 'cancelacion', 'tipo', 'prop', 'dir', 'menos', 'meta', 45, 'peso', 35),
            jsonb_build_object('clave', 'puntualidad', 'tipo', 'todo_o_nada', 'regla', 'dias_tarde<3', 'peso', 15))),
        'novedades', jsonb_build_object('nombre', 'Gestión de Novedades', 'medible', false, 'valor', 100000, 'liquida_fuera', true),
        'apoyo',     jsonb_build_object('nombre', 'Apoyo', 'medible', false),
        'lider',     jsonb_build_object('valor', 200000, 'bloques', jsonb_build_object('operacion', 0.70, 'novedades', 0.30))))
$$;

-- Config vigente: la última versión del mes; si no hay, la del mes anterior más reciente
-- (heredada, con fin_revision recalculado); si no hay ninguna, la de fábrica.
create or replace function public.var_config_vigente(p_mes date) returns jsonb
language plpgsql stable set search_path = public, pg_temp as $fn$
declare r record; cfg jsonb;
begin
  select c.config, c.version, c.mes into r from var_config_mes c where c.mes = p_mes order by c.version desc limit 1;
  if found then
    return r.config || jsonb_build_object('_version', r.version, '_mes_origen', to_char(r.mes,'YYYY-MM-DD'));
  end if;
  select c.config, c.version, c.mes into r from var_config_mes c where c.mes < p_mes order by c.mes desc, c.version desc limit 1;
  if found then
    cfg := r.config || jsonb_build_object('_version', r.version, '_mes_origen', to_char(r.mes,'YYYY-MM-DD'), '_heredada', true);
    return cfg || jsonb_build_object('fin_revision', var_config_default(p_mes)->>'fin_revision');
  end if;
  return var_config_default(p_mes) || jsonb_build_object('_version', 0, '_default', true, '_mes_origen', to_char(p_mes,'YYYY-MM-DD'));
end $fn$;

-- Guardar config: valida (pesos suman 100 por cargo medible; metas > 0); antes del día 1 es libre,
-- desde el día 1 exige motivo (principio "reglas al inicio del mes"). Siempre crea versión nueva.
create or replace function public.var_config_guardar(p_mes date, p_config jsonb, p_motivo text, p_actor uuid) returns integer
language plpgsql set search_path = public, pg_temp as $fn$
declare k text; suma numeric; v jsonb; nueva integer;
begin
  if extract(day from p_mes) <> 1 then raise exception 'El mes debe ser el día 1' using errcode = 'P0010'; end if;
  if p_mes <= var_hoy_col() and coalesce(length(trim(p_motivo)),0) < 5 then
    raise exception 'El mes ya empezó: la corrección exige un motivo' using errcode = 'P0011';
  end if;
  for k in select key from jsonb_each(p_config->'cargos') loop
    if coalesce((p_config->'cargos'->k->>'medible')::boolean, false) then
      select sum((x->>'peso')::numeric) into suma from jsonb_array_elements(p_config->'cargos'->k->'variables') x;
      if coalesce(suma,0) <> 100 then raise exception 'Los pesos del cargo % suman %, deben sumar 100', k, coalesce(suma,0) using errcode = 'P0012'; end if;
      for v in select x from jsonb_array_elements(p_config->'cargos'->k->'variables') x loop
        if v->>'tipo' = 'prop' and coalesce((v->>'meta')::numeric, 0) <= 0 then
          raise exception 'La meta de % en % debe ser > 0', v->>'clave', k using errcode = 'P0013';
        end if;
      end loop;
    end if;
  end loop;
  if coalesce((p_config->>'compuerta_ritmo')::numeric, 0) <= 0 then raise exception 'La compuerta de ritmo debe ser > 0' using errcode = 'P0013'; end if;
  select coalesce(max(version),0) + 1 into nueva from var_config_mes where mes = p_mes;
  insert into var_config_mes (mes, version, config, motivo, creado_por) values (p_mes, nueva, p_config, p_motivo, p_actor);
  return nueva;
end $fn$;

-- Horas efectivas de un día según turno (spec §3.3). Domingo = 0. Festivo gana a L–S, domingo gana a festivo.
create or replace function public.var_horas_efectivas(d date, turno char, cfg jsonb) returns numeric
language plpgsql stable set search_path = public, pg_temp as $fn$
declare dow int := extract(isodow from d); k text;
begin
  if dow = 7 then return 0; end if;
  if var_es_festivo(d) then k := 'festivo'; elsif dow <= 4 then k := '1-4'; else k := dow::text; end if;
  return coalesce((cfg->'horas_efectivas'->turno->>k)::numeric, 0);
end $fn$;

-- Estado del mes (spec §3.6): liquidado / en_revision (pasó el cierre de datos) / abierto.
create or replace function public.var_estado_mes(p_mes date) returns text
language plpgsql stable set search_path = public, pg_temp as $fn$
declare est text; ult date := (p_mes + interval '1 month' - interval '1 day')::date; dow int; cierre timestamp;
begin
  select l.estado into est from var_liquidacion l where l.mes = p_mes;
  if est = 'liquidado' then return 'liquidado'; end if;
  dow := extract(isodow from ult);
  cierre := ult + case when dow = 5 then time '20:00'
                       when dow in (6,7) or var_es_festivo(ult) then time '19:00'
                       else time '22:00' end;
  if var_ahora_col() >= cierre then return 'en_revision'; end if;
  return 'abierto';
end $fn$;

-- ---------- Asignación atómica (diseño §5.5) ----------
-- Una vigente por (fecha, agente). Si ya existe una idéntica, no crea nada y devuelve su id.
-- Corregir = apagar la vigente + insertar la nueva en la MISMA transacción.
-- Concurrencia: dos correcciones a la vez → unique_violation (23505) → la Edge responde 409.
create or replace function public.var_asignar(p_fecha date, p_agent_id text, p_turno char, p_estado text, p_lider uuid, p_actor uuid) returns bigint
language plpgsql set search_path = public, pg_temp as $fn$
declare prev record; nid bigint;
begin
  if p_fecha > var_hoy_col() then raise exception 'No se puede asignar una fecha futura (%)', p_fecha using errcode = 'P0002'; end if;
  if not exists (select 1 from var_agente a where a.agent_id = p_agent_id and a.activo) then
    raise exception 'El agente % no está en el roster activo', p_agent_id using errcode = 'P0003';
  end if;
  if not exists (select 1 from var_usuarios u where u.auth_uid = p_lider and u.activo) then
    raise exception 'Líder inválido' using errcode = 'P0004';
  end if;
  select id, turno, estado, lider_uid into prev from var_asignacion where fecha = p_fecha and agent_id = p_agent_id and vigente;
  if found and prev.turno = p_turno and prev.estado = p_estado and prev.lider_uid = p_lider then
    return prev.id;
  end if;
  update var_asignacion set vigente = false where fecha = p_fecha and agent_id = p_agent_id and vigente;
  insert into var_asignacion (fecha, agent_id, turno, estado, lider_uid, vigente, reemplaza_id, creado_por)
    values (p_fecha, p_agent_id, p_turno, p_estado, p_lider, true, prev.id, p_actor) returning id into nid;
  return nid;
end $fn$;

-- Usuarios de Auth (para que Admin asigne roles a las personas ya invitadas). Solo service_role la llama.
create or replace function public.var_auth_usuarios() returns table (id uuid, email text, creado timestamptz, ultimo_ingreso timestamptz)
language sql stable security definer set search_path = public, pg_temp as $$
  select u.id, u.email::text, u.created_at, u.last_sign_in_at from auth.users u order by u.created_at
$$;
revoke all on function public.var_auth_usuarios() from public, anon, authenticated;

-- ---------- Ritmo en vivo (spec §3.4; orientativo, no paga) ----------
-- primera_hh = media hora (0..47, hora Colombia) de la primera gestión del día.
create or replace function public.var_ritmo_vivo(d date, turno char, primera_hh integer, gest integer, ahora timestamp, cfg jsonb)
returns numeric language plpgsql stable set search_path = public, pg_temp as $fn$
declare dow int := extract(isodow from d); fest boolean := var_es_festivo(d);
        inicio timestamp; fin timestamp; brk timestamp; tope time; desc_min numeric := 0; horas numeric;
begin
  if primera_hh is null or gest is null or gest = 0 or dow = 7 then return null; end if;
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
  -- descuento del break: solo la parte del intervalo [brk, brk+30min] que cae dentro de [inicio, fin]
  desc_min := greatest(0, extract(epoch from (least(fin, brk + interval '30 minutes') - greatest(inicio, brk))) / 60);
  horas := (extract(epoch from (fin - inicio)) / 3600) - (desc_min / 60);
  if horas < 1 then return null; end if;                            -- primera hora de gestión: "—"
  return round(gest::numeric / horas::numeric, 1);
end $fn$;

-- ---------- RESUMEN DEL MES EN PORCENTAJES (spec §3.1–§3.3, §4.1) — sin dinero ----------
create or replace function public.var_resumen_mes(p_mes date) returns jsonb
language plpgsql stable set search_path = public, pg_temp as $fn$
declare
  cfg   jsonb := var_config_vigente(p_mes);
  hoy   date  := var_hoy_col();
  ahora timestamp := var_ahora_col();
  d_fin date  := least((p_mes + interval '1 month' - interval '1 day')::date, hoy);
  comp  numeric := coalesce((cfg->>'compuerta_ritmo')::numeric, 38);
  res   jsonb;
begin
  if extract(day from p_mes) <> 1 then raise exception 'El mes debe ser el día 1' using errcode = 'P0010'; end if;
  if p_mes > hoy then return jsonb_build_object('mes', to_char(p_mes,'YYYY-MM'), 'hoy', hoy, 'agentes', '[]'::jsonb, 'consolidado', '{}'::jsonb, 'sin_asignar', '[]'::jsonb, 'sin_alias', '[]'::jsonb); end if;

  with
  ev as (                                     -- gestiones del período con agente resuelto por alias
    select e.ev_date, e.type, e.halfhour, e.agent as nombre, a.agent_id
    from events_history e
    left join lateral (
      select al.agent_id from var_agente_alias al
      where al.nombre_norm = var_norm(e.agent) and e.ev_date >= al.desde and (al.hasta is null or e.ev_date <= al.hasta)
      order by al.desde desc limit 1) a on true
    where e.ev_date between p_mes and d_fin and not var_es_excluido(e.agent)
  ),
  sin_alias as (select nombre, count(*)::int gest from ev where agent_id is null group by nombre),
  dia as (                                    -- conteo por agente-día (gestiones = conf + canc + reprog)
    select agent_id, ev_date as fecha, count(*)::int gest,
           count(*) filter (where type = 0)::int conf, count(*) filter (where type = 1)::int canc, count(*) filter (where type = 2)::int reprog,
           min(halfhour)::int primera_hh
    from ev where agent_id is not null group by 1, 2
  ),
  asg as (select fecha, agent_id, turno, estado, lider_uid from var_asignacion where vigente and fecha between p_mes and d_fin),
  ad as (                                     -- agente-día = días con gestiones ∪ días con asignación
    select coalesce(d.agent_id, s.agent_id) agent_id, coalesce(d.fecha, s.fecha) fecha,
           coalesce(d.gest,0) gest, coalesce(d.conf,0) conf, coalesce(d.canc,0) canc, coalesce(d.reprog,0) reprog, d.primera_hh,
           s.turno, s.estado, s.lider_uid,
           case when s.turno is null then 0 else var_horas_efectivas(coalesce(d.fecha, s.fecha), s.turno, cfg) end as horas,
           (extract(isodow from coalesce(d.fecha, s.fecha)) = 7) as domingo
    from dia d full join asg s on s.fecha = d.fecha and s.agent_id = d.agent_id
  ),
  agc as (                                    -- por agente × cargo (solo días asignados a ese cargo)
    select agent_id, estado as cargo, count(*)::int dias, sum(gest)::int gest, sum(conf)::int conf, sum(canc)::int canc, sum(reprog)::int reprog,
           sum(case when domingo then 0 else gest end)::int gest_ritmo, sum(horas)::numeric horas
    from ad where estado is not null group by 1, 2
  ),
  agcc as (
    select a.*,
      (select (v->>'meta')::numeric from jsonb_array_elements(coalesce(cfg->'cargos'->a.cargo->'variables','[]'::jsonb)) v where v->>'clave' = 'efectividad') meta_ef,
      (select (v->>'meta')::numeric from jsonb_array_elements(coalesce(cfg->'cargos'->a.cargo->'variables','[]'::jsonb)) v where v->>'clave' = 'cancelacion') meta_ca,
      coalesce((cfg->'cargos'->a.cargo->>'medible')::boolean, false) medible
    from agc a
  ),
  agcx as (                                   -- cumplimientos: UNA división, 1 decimal, tope 150,0; denominador 0 → null (no medible)
    select *,
      case when gest > 0 then round((conf + canc) * 100::numeric / gest, 1) end as ef_real,
      case when gest > 0 and meta_ef > 0 then least(150.0, round((conf + canc) * 10000::numeric / (gest * meta_ef), 1)) end as ef_cumpl,
      case when conf + canc > 0 then round(canc * 100::numeric / (conf + canc), 1) end as ca_real,
      case when conf + canc = 0 then null when canc = 0 then 150.0
           when meta_ca > 0 then least(150.0, round(meta_ca * (conf + canc)::numeric / canc, 1)) end as ca_cumpl,
      case when horas > 0 then round(gest_ritmo::numeric / horas, 1) end as ritmo
    from agcc
  ),
  con_c as (                                  -- consolidado por turno y cargo medible
    select turno, estado as cargo, sum(gest)::int gest, sum(conf)::int conf, sum(canc)::int canc,
           sum(case when domingo then 0 else gest end)::int gest_ritmo, sum(horas)::numeric horas
    from ad where turno is not null and coalesce((cfg->'cargos'->estado->>'medible')::boolean, false) group by 1, 2
  ),
  con_cc as (
    select c.*,
      (select (v->>'meta')::numeric from jsonb_array_elements(cfg->'cargos'->c.cargo->'variables') v where v->>'clave' = 'efectividad') meta_ef,
      (select (v->>'meta')::numeric from jsonb_array_elements(cfg->'cargos'->c.cargo->'variables') v where v->>'clave' = 'cancelacion') meta_ca
    from con_c c
  ),
  con_cx as (
    select *,
      case when gest > 0 and meta_ef > 0 then least(150.0, round((conf + canc) * 10000::numeric / (gest * meta_ef), 1)) end as ef_cumpl,
      case when conf + canc = 0 then null when canc = 0 then 150.0
           when meta_ca > 0 then least(150.0, round(meta_ca * (conf + canc)::numeric / canc, 1)) end as ca_cumpl
    from con_cc
  ),
  con as (                                    -- consolidación ponderada por gestiones, cada cargo contra su meta (decisión 31)
    select turno, sum(gest)::int gest, sum(conf)::int conf, sum(canc)::int canc,
      case when sum(gest) > 0 then round(sum(conf + canc) * 100::numeric / sum(gest), 1) end ef_real,
      case when sum(conf + canc) > 0 then round(sum(canc) * 100::numeric / sum(conf + canc), 1) end ca_real,
      round(sum(gest * ef_cumpl) filter (where ef_cumpl is not null) / nullif(sum(gest) filter (where ef_cumpl is not null), 0), 1) ef_cumpl,
      round(sum(gest * ca_cumpl) filter (where ca_cumpl is not null) / nullif(sum(gest) filter (where ca_cumpl is not null), 0), 1) ca_cumpl,
      case when sum(horas) > 0 then round(sum(gest_ritmo)::numeric / sum(horas), 1) end ritmo
    from con_cx group by turno
  ),
  hoyasg as (                                 -- cargo/turno "de hoy" = última asignación vigente hasta d_fin
    select distinct on (agent_id) agent_id, estado, turno, fecha from asg order by agent_id, fecha desc
  ),
  vivo as (                                   -- ritmo en vivo, solo para el día de hoy
    select a.agent_id, var_ritmo_vivo(a.fecha, a.turno, a.primera_hh, a.gest, ahora, cfg) as ritmo, a.gest
    from ad a where a.fecha = hoy and a.turno is not null
  ),
  agentes as (
    select g.agent_id, g.nombre from var_agente g
    where g.activo or exists (select 1 from ad where ad.agent_id = g.agent_id)
  )
  select jsonb_build_object(
    'mes', to_char(p_mes, 'YYYY-MM'), 'hoy', hoy, 'hasta', d_fin, 'estado', var_estado_mes(p_mes),
    'config_version', cfg->'_version', 'compuerta_ritmo', comp, 'dias_habiles', var_dias_habiles(p_mes),
    'agentes', coalesce((
      select jsonb_agg(jsonb_build_object(
        'agent_id', g.agent_id, 'nombre', g.nombre,
        'cargo_hoy', h.estado, 'turno_hoy', h.turno, 'asignado_hasta', h.fecha,
        'en_vivo', (select jsonb_build_object('ritmo', v.ritmo, 'gest', v.gest) from vivo v where v.agent_id = g.agent_id),
        'cargos', coalesce((select jsonb_agg(jsonb_build_object(
            'cargo', x.cargo, 'medible', x.medible, 'dias', x.dias, 'gest', x.gest, 'conf', x.conf, 'canc', x.canc, 'reprog', x.reprog,
            'horas', x.horas, 'efectividad_real', x.ef_real, 'efectividad_cumpl', x.ef_cumpl,
            'cancelacion_real', x.ca_real, 'cancelacion_cumpl', x.ca_cumpl,
            'ritmo', x.ritmo, 'compuerta', case when x.ritmo is null then null else x.ritmo >= comp end)
          order by x.cargo) from agcx x where x.agent_id = g.agent_id), '[]'::jsonb),
        'dias', coalesce((select jsonb_agg(jsonb_build_object(
            'fecha', d.fecha, 'estado', d.estado, 'turno', d.turno, 'gest', d.gest, 'conf', d.conf, 'canc', d.canc, 'reprog', d.reprog, 'horas', d.horas)
          order by d.fecha) from ad d where d.agent_id = g.agent_id), '[]'::jsonb)
      ) order by g.nombre)
      from agentes g left join hoyasg h on h.agent_id = g.agent_id), '[]'::jsonb),
    'consolidado', coalesce((select jsonb_object_agg(c.turno, jsonb_build_object(
        'gest', c.gest, 'conf', c.conf, 'canc', c.canc, 'efectividad_real', c.ef_real, 'efectividad_cumpl', c.ef_cumpl,
        'cancelacion_real', c.ca_real, 'cancelacion_cumpl', c.ca_cumpl, 'ritmo', c.ritmo,
        'compuerta', case when c.ritmo is null then null else c.ritmo >= comp end)) from con c), '{}'::jsonb),
    'sin_asignar', coalesce((select jsonb_agg(jsonb_build_object('agent_id', d.agent_id, 'fecha', d.fecha, 'gest', d.gest, 'estado', d.estado) order by d.fecha, d.agent_id)
        from ad d where d.gest > 0 and (d.estado is null or d.estado in ('ausencia','incapacidad'))), '[]'::jsonb),
    'sin_alias', coalesce((select jsonb_agg(jsonb_build_object('nombre', s.nombre, 'gest', s.gest) order by s.gest desc, s.nombre) from sin_alias s), '[]'::jsonb),
    'asignaciones_hoy', (select count(*) from asg where fecha = hoy)
  ) into res;
  return res;
end $fn$;

create index if not exists var_agente_alias_norm_idx on public.var_agente_alias (nombre_norm);
