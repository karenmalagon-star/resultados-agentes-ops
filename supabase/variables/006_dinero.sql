-- ============================================================================
-- Módulo de Variables · 006 · MOTOR DE DINERO (Sprint 2) — spec v1.7 §2, §3.5, §3.7; K1–K5
-- Solo lo lee el rol Admin (acción `dinero` de la Edge Function). Ninguna cifra viaja a Líder/Auditoría.
-- Aritmética en numeric; pesos como fracciones exactas; una sola división por cumplimiento (viene del resumen).
-- "Acumulado del mes": el denominador del prorrateo es días hábiles del MES (K1), así el monto crece día a día.
-- Mientras faltan datos manuales (puntualidad, multiplicador) el monto es ESTIMADO y se listan los pendientes;
-- la liquidación (var_liquidar, siguiente entrega) se bloquea con pendientes (K2, K3).
-- ============================================================================

-- Escalera (spec §2, decisiones 17 y 24): el cumplimiento llega ya redondeado a 1 decimal y topado en 150.
create or replace function public.var_escalera(c numeric) returns numeric
language sql immutable set search_path = public, pg_temp as $$
  select case when c is null then null
              when c > 110.0 then 1.5
              when c >= 100.0 then floor(c) / 100
              when c >= 95.0 then 0.95
              when c >= 90.0 then 0.80
              else 0 end
$$;

-- Consolidado por LÍDER (agentes-día firmados por él, cargos medibles) — spec §3.7 / decisión 31.
create or replace function public.var_lideres_mes(p_mes date) returns jsonb
language plpgsql stable set search_path = public, pg_temp as $fn$
declare cfg jsonb := var_config_vigente(p_mes); hoy date := var_hoy_col();
        d_fin date := least((p_mes + interval '1 month' - interval '1 day')::date, hoy);
        comp numeric := coalesce((cfg->>'compuerta_ritmo')::numeric, 38); res jsonb;
begin
  with
  ev as (select e.ev_date, e.type, a.agent_id from events_history e
    left join lateral (select al.agent_id from var_agente_alias al where al.nombre_norm = var_norm(e.agent) and e.ev_date >= al.desde and (al.hasta is null or e.ev_date <= al.hasta) order by al.desde desc limit 1) a on true
    where e.ev_date between p_mes and d_fin and not var_es_excluido(e.agent) and a.agent_id is not null),
  dd as (select agent_id, ev_date fecha, count(*)::int gest, count(*) filter (where type = 0)::int conf, count(*) filter (where type = 1)::int canc from ev group by 1, 2),
  asg as (select fecha, agent_id, turno, estado, lider_uid from var_asignacion where vigente and fecha between p_mes and d_fin),
  ad as (select s.lider_uid, s.estado cargo, s.fecha, coalesce(d.gest,0) gest, coalesce(d.conf,0) conf, coalesce(d.canc,0) canc,
           var_horas_efectivas(s.fecha, s.turno, cfg) horas, (extract(isodow from s.fecha) = 7) domingo
         from asg s left join dd d on d.fecha = s.fecha and d.agent_id = s.agent_id
         where coalesce((cfg->'cargos'->s.estado->>'medible')::boolean, false)),
  metas as (select k cargo,
      (select (v->>'meta')::numeric from jsonb_array_elements(coalesce(cfg->'cargos'->k->'variables','[]'::jsonb)) v where v->>'clave' = 'efectividad') meta_ef,
      (select (v->>'meta')::numeric from jsonb_array_elements(coalesce(cfg->'cargos'->k->'variables','[]'::jsonb)) v where v->>'clave' = 'cancelacion') meta_ca
    from jsonb_object_keys(cfg->'cargos') k),
  lc as (select lider_uid, cargo, sum(gest)::int gest, sum(conf)::int conf, sum(canc)::int canc, sum(case when domingo then 0 else gest end)::int gest_ritmo, sum(horas)::numeric horas from ad group by 1, 2),
  lcx as (select l.*,   -- sin redondear por cargo: el único round(…,1) va en el consolidado (spec §3.7)
      case when l.gest > 0 and m.meta_ef > 0 then least(150.0, (l.conf + l.canc) * 10000::numeric / (l.gest * m.meta_ef)) end ef_cumpl,
      case when l.conf + l.canc = 0 then null when l.canc = 0 then 150.0 when m.meta_ca > 0 then least(150.0, m.meta_ca * (l.conf + l.canc)::numeric / l.canc) end ca_cumpl
    from lc l left join metas m on m.cargo = l.cargo),
  lider as (select lider_uid, sum(gest)::int gest,
      round(sum(gest * ef_cumpl) filter (where ef_cumpl is not null) / nullif(sum(gest) filter (where ef_cumpl is not null), 0), 1) ef_cumpl,
      round(sum(gest * ca_cumpl) filter (where ca_cumpl is not null) / nullif(sum(gest) filter (where ca_cumpl is not null), 0), 1) ca_cumpl,
      case when sum(horas) > 0 then round(sum(gest_ritmo)::numeric / sum(horas), 1) end ritmo
    from lcx group by lider_uid),
  dl as (select lider_uid, count(distinct fecha) filter (where var_es_habil(fecha))::int dias_liderados from asg group by 1),
  aus as (select ld.lider_uid, count(*)::int n from var_lider_dia ld join var_usuarios u on u.auth_uid = ld.lider_uid
          where ld.fecha between greatest(p_mes, coalesce(u.fecha_ingreso, p_mes)) and (p_mes + interval '1 month' - interval '1 day')::date and var_es_habil(ld.fecha) group by 1)
  select coalesce(jsonb_agg(jsonb_build_object(
      'lider_uid', u.auth_uid, 'nombre', u.nombre, 'etiqueta', u.etiqueta, 'fecha_ingreso', u.fecha_ingreso,
      'dias_liderados', coalesce(d.dias_liderados, 0), 'ausencias', coalesce(a.n, 0),
      'gest', l.gest, 'efectividad_cumpl', l.ef_cumpl, 'cancelacion_cumpl', l.ca_cumpl, 'ritmo', l.ritmo,
      'compuerta', case when l.ritmo is null then null else l.ritmo >= comp end) order by u.nombre), '[]'::jsonb)
  into res
  from var_usuarios u
  left join lider l on l.lider_uid = u.auth_uid
  left join dl d on d.lider_uid = u.auth_uid
  left join aus a on a.lider_uid = u.auth_uid
  where u.rol <> 'admin' and ((u.activo and (u.rol = 'equipo' or u.etiqueta is not null)) or coalesce(d.dias_liderados, 0) > 0);  -- un líder retirado con días liderados sí cobra; Admin nunca es líder
  return res;
end $fn$;

-- MOTOR: monto estimado del mes por agente y por líder (Admin). Spec §3.5 y §3.7.
create or replace function public.var_calcular_mes(p_mes date) returns jsonb
language plpgsql stable set search_path = public, pg_temp as $fn$
declare
  cfg jsonb := var_config_vigente(p_mes); r jsonb := var_resumen_mes(p_mes); L jsonb := var_lideres_mes(p_mes);
  dh integer := var_dias_habiles(p_mes);
  ag jsonb; c jsonb; out_ag jsonb := '[]'::jsonb; out_li jsonb := '[]'::jsonb; li jsonb;
  cargos jsonb; pend jsonb; valor numeric; w_ef numeric; w_ca numeric; w_pu numeric;
  f_ef numeric; f_ca numeric; f_pu numeric; sum_w numeric; suma numeric; subtotal numeric; pago numeric; total_ag numeric := 0; total_li numeric := 0;
  dias_tarde numeric; mult numeric; mult_txt text; nov_dias integer; medibles integer;
  v_lider numeric := coalesce((cfg->'cargos'->'lider'->>'valor')::numeric, 200000);
  b_oper numeric := coalesce((cfg->'cargos'->'lider'->'bloques'->>'operacion')::numeric, 0.70);
  dias_debia integer; razon numeric; lw_ef numeric; lw_ca numeric; n_sa integer;
begin
  -- pesos del bloque Operación del líder = los del cargo Verificación en la config (no hardcodeados)
  select coalesce(max(case when v->>'clave'='efectividad' then (v->>'peso')::numeric end),50), coalesce(max(case when v->>'clave'='cancelacion' then (v->>'peso')::numeric end),35)
    into lw_ef, lw_ca from jsonb_array_elements(coalesce(cfg->'cargos'->'verificacion'->'variables','[]'::jsonb)) v;
  -- ---------------- AGENTES ----------------
  for ag in select * from jsonb_array_elements(r->'agentes') loop
    cargos := '[]'::jsonb; pend := '[]'::jsonb; pago := 0; nov_dias := 0; medibles := 0;
    -- puntualidad: un valor por agente-mes (var_manual, cargo null, clave 'dias_tarde')
    select m.valor into dias_tarde from var_manual m where m.mes = p_mes and m.sujeto_tipo = 'agente' and m.sujeto_id = ag->>'agent_id' and m.cargo is null and m.clave = 'dias_tarde' and m.vigente;
    if dias_tarde is null then f_pu := null; pend := pend || '"puntualidad sin digitar (se estima como cumplida)"'::jsonb; else f_pu := case when dias_tarde < 3 then 1 else 0 end; end if;
    select m.valor into mult from var_manual m where m.mes = p_mes and m.sujeto_tipo = 'agente' and m.sujeto_id = ag->>'agent_id' and m.cargo is null and m.clave = 'multiplicador' and m.vigente;
    if mult is null then mult_txt := 'pendiente (se estima 100 %)'; pend := pend || '"multiplicador de auditoría sin digitar (se estima 100 %)"'::jsonb; mult := 100; else mult_txt := mult::text || ' %'; end if;

    for c in select * from jsonb_array_elements(ag->'cargos') loop
      if c->>'cargo' = 'novedades' then nov_dias := (c->>'dias')::int; continue; end if;
      if not coalesce((c->>'medible')::boolean, false) then continue; end if;
      medibles := medibles + 1;
      valor := coalesce((cfg->'cargos'->(c->>'cargo')->>'valor')::numeric, 0);
      select coalesce(max(case when v->>'clave'='efectividad' then (v->>'peso')::numeric end),0), coalesce(max(case when v->>'clave'='cancelacion' then (v->>'peso')::numeric end),0), coalesce(max(case when v->>'clave'='puntualidad' then (v->>'peso')::numeric end),0)
        into w_ef, w_ca, w_pu from jsonb_array_elements(cfg->'cargos'->(c->>'cargo')->'variables') v;
      -- factores (spec §3.5): compuerta apaga Efectividad; no medible = null → su peso se redistribuye (decisión 27)
      -- Efectividad: no medible si no hay cumplimiento o si no hay ritmo evaluable; 0 si la compuerta está cerrada; escalera si abierta
      f_ef := case when (c->>'efectividad_cumpl') is null or (c->>'ritmo') is null then null when coalesce((c->>'compuerta')::boolean,false) then var_escalera((c->>'efectividad_cumpl')::numeric) else 0 end;
      f_ca := var_escalera((c->>'cancelacion_cumpl')::numeric);
      if f_ef is null then pend := pend || to_jsonb(format('%s: Efectividad no medible (su peso se redistribuye)', cfg->'cargos'->(c->>'cargo')->>'nombre')); end if;
      if f_ca is null then pend := pend || to_jsonb(format('%s: Cancelación no medible (su peso se redistribuye)', cfg->'cargos'->(c->>'cargo')->>'nombre')); end if;
      if f_ef is null and f_ca is null then   -- spec §3.5/§6: sin ninguna variable proporcional medible, el cargo paga $0 hasta corregir o digitar
        suma := 0; pend := pend || to_jsonb(format('%s: ninguna variable medible → $0 hasta corregir la asignación o digitar', cfg->'cargos'->(c->>'cargo')->>'nombre'));
      else
        sum_w := coalesce(case when f_ef is not null then w_ef end,0) + coalesce(case when f_ca is not null then w_ca end,0) + w_pu;   -- puntualidad siempre viva (todo-o-nada; vacía → estimada cumplida)
        suma := (coalesce(f_ef * w_ef, 0) + coalesce(f_ca * w_ca, 0) + coalesce(f_pu, 1) * w_pu) / sum_w;
      end if;
      subtotal := valor * ((c->>'dias')::numeric / dh) * suma;
      pago := pago + subtotal;
      cargos := cargos || jsonb_build_object('cargo', c->>'cargo', 'nombre', cfg->'cargos'->(c->>'cargo')->>'nombre', 'valor', valor, 'dias', (c->>'dias')::int, 'dias_habiles', dh,
        'efectividad_cumpl', c->'efectividad_cumpl', 'factor_efectividad', f_ef, 'compuerta', c->'compuerta',
        'cancelacion_cumpl', c->'cancelacion_cumpl', 'factor_cancelacion', f_ca,
        'dias_tarde', dias_tarde, 'factor_puntualidad', f_pu,
        'pesos', jsonb_build_object('efectividad', w_ef, 'cancelacion', w_ca, 'puntualidad', w_pu),
        'reconocimiento', round(suma * 100, 1), 'subtotal', round(subtotal, 0));
    end loop;
    if nov_dias > 0 then pend := pend || to_jsonb(format('Novedades: %s día(s) se liquidan por fuera', nov_dias)); end if;
    if medibles = 0 and nov_dias = 0 then pend := pend || '"sin días en cargo medible este mes"'::jsonb; end if;
    select count(*) into n_sa from jsonb_array_elements(r->'sin_asignar') x where x->>'agent_id' = ag->>'agent_id';
    if n_sa > 0 then pend := pend || to_jsonb(format('%s día(s) con gestiones sin asignación o marcados ausencia: esas gestiones no entran a ningún cargo', n_sa)); end if;
    out_ag := out_ag || jsonb_build_object('agent_id', ag->>'agent_id', 'nombre', ag->>'nombre', 'cargo_permanente', ag->>'cargo_permanente',
      'cargos', cargos, 'novedades_dias', nov_dias, 'multiplicador', mult, 'multiplicador_txt', mult_txt,
      'pago_variables', round(pago, 0), 'pago_estimado', round(pago * mult / 100, 0), 'pendientes', pend);
    total_ag := total_ag + round(pago * mult / 100, 0);
  end loop;

  -- ---------------- LÍDERES (spec §3.7; bloque Novedades vacío hasta P8 → Operación 100 %) ----------------
  for li in select * from jsonb_array_elements(L) loop
    pend := '[]'::jsonb;
    -- días que debía liderar = hábiles del mes (desde su ingreso) − ausencias/descansos registrados
    select count(*)::int into dias_debia from generate_series(greatest(p_mes, coalesce((li->>'fecha_ingreso')::date, p_mes)), (p_mes + interval '1 month' - interval '1 day')::date, interval '1 day') d where var_es_habil(d::date);
    dias_debia := greatest(dias_debia - coalesce((li->>'ausencias')::int, 0), 0);
    razon := case when dias_debia > 0 then least(1, (li->>'dias_liderados')::numeric / dias_debia) else 0 end;
    f_ef := case when (li->>'efectividad_cumpl') is null or (li->>'ritmo') is null then null when coalesce((li->>'compuerta')::boolean,false) then var_escalera((li->>'efectividad_cumpl')::numeric) else 0 end;
    f_ca := var_escalera((li->>'cancelacion_cumpl')::numeric);
    if f_ef is null then pend := pend || '"Efectividad del turno no medible"'::jsonb; end if;
    if f_ca is null then pend := pend || '"Cancelación del turno no medible"'::jsonb; end if;
    sum_w := coalesce(case when f_ef is not null then lw_ef end,0) + coalesce(case when f_ca is not null then lw_ca end,0);
    suma := case when sum_w = 0 then 0 else (coalesce(f_ef * lw_ef, 0) + coalesce(f_ca * lw_ca, 0)) / sum_w end;
    if dias_debia = 0 and (li->>'dias_liderados')::int > 0 then pend := pend || '"días que debía liderar = 0: revisar fecha de ingreso o ausencias"'::jsonb; end if;
    pend := pend || '"bloque Novedades (30 %) vacío hasta que exista su fuente: Operación pesa 100 %"'::jsonb;
    if (li->>'dias_liderados')::int = 0 then pend := pend || '"no ha firmado ninguna asignación este mes"'::jsonb; end if;
    select m.valor into mult from var_manual m where m.mes = p_mes and m.sujeto_tipo = 'lider' and m.sujeto_id = li->>'lider_uid' and m.cargo is null and m.clave = 'multiplicador' and m.vigente;
    if mult is null then mult_txt := 'pendiente (se estima 100 %)'; pend := pend || '"multiplicador de auditoría sin digitar (se estima 100 %)"'::jsonb; mult := 100; else mult_txt := mult::text || ' %'; end if;
    subtotal := v_lider * razon * suma;
    out_li := out_li || jsonb_build_object('lider_uid', li->>'lider_uid', 'nombre', li->>'nombre', 'etiqueta', li->>'etiqueta',
      'valor', v_lider, 'dias_liderados', (li->>'dias_liderados')::int, 'dias_debia', dias_debia, 'ausencias', (li->>'ausencias')::int,
      'efectividad_cumpl', li->'efectividad_cumpl', 'factor_efectividad', f_ef, 'compuerta', li->'compuerta', 'ritmo', li->'ritmo',
      'cancelacion_cumpl', li->'cancelacion_cumpl', 'factor_cancelacion', f_ca,
      'bloque_operacion', b_oper, 'bloque_operacion_efectivo', 1.0, 'pesos', jsonb_build_object('efectividad', lw_ef, 'cancelacion', lw_ca), 'reconocimiento', round(suma * 100, 1), 'multiplicador', mult, 'multiplicador_txt', mult_txt,
      'pago_variables', round(subtotal, 0), 'pago_estimado', round(subtotal * mult / 100, 0), 'pendientes', pend);
    total_li := total_li + round(subtotal * mult / 100, 0);
  end loop;

  return jsonb_build_object('mes', to_char(p_mes,'YYYY-MM'), 'hasta', r->'hasta', 'dias_habiles', dh, 'estado', r->'estado', 'config_version', cfg->'_version',
    'agentes', out_ag, 'lideres', out_li,
    'totales', jsonb_build_object('agentes', total_ag, 'lideres', total_li, 'total', total_ag + total_li),
    'sin_alias', r->'sin_alias', 'sin_asignar_n', jsonb_array_length(coalesce(r->'sin_asignar','[]'::jsonb)),
    'nota', 'Montos ESTIMADOS al día: el prorrateo divide por los días hábiles del mes completo; puntualidad y multiplicador pendientes se estiman como cumplidos / 100 %. La liquidación exige digitarlos.');
end $fn$;

-- Admin que corrige sin indicar líder conserva el líder original del agente-día (spec §3.7 / diseño §5.5).
create or replace function public.var_asignar(p_fecha date, p_agent_id text, p_turno char, p_estado text, p_lider uuid, p_actor uuid, p_es_na boolean default false) returns bigint
language plpgsql set search_path = public, pg_temp as $fn$
declare prev record; nid bigint; est text := p_estado; lid uuid := p_lider;
begin
  if p_fecha > var_hoy_col() then raise exception 'No se puede asignar una fecha futura (%)', p_fecha using errcode = 'P0002'; end if;
  if not exists (select 1 from var_agente a where a.agent_id = p_agent_id and a.activo) then raise exception 'El agente % no está en el roster activo', p_agent_id using errcode = 'P0003'; end if;
  if not exists (select 1 from var_usuarios u where u.auth_uid = p_lider and u.activo) then raise exception 'Líder inválido' using errcode = 'P0004'; end if;
  if p_es_na then select cargo_permanente into est from var_agente where agent_id = p_agent_id; end if;
  select id, turno, estado, lider_uid, es_na into prev from var_asignacion where fecha = p_fecha and agent_id = p_agent_id and vigente;
  if found and p_lider = p_actor and exists (select 1 from var_usuarios u where u.auth_uid = p_actor and u.rol = 'admin') then lid := prev.lider_uid; end if;
  if found and prev.turno = p_turno and prev.estado = est and prev.lider_uid = lid and prev.es_na = p_es_na then return prev.id; end if;
  update var_asignacion set vigente = false where fecha = p_fecha and agent_id = p_agent_id and vigente;
  insert into var_asignacion (fecha, agent_id, turno, estado, lider_uid, vigente, reemplaza_id, creado_por, es_na)
    values (p_fecha, p_agent_id, p_turno, est, lid, true, prev.id, p_actor, p_es_na) returning id into nid;
  return nid;
end $fn$;

-- Mientras "digitar el valor real de una variable" (decisión 27) no esté implementado en el motor, no se permite guardarlo
-- (evita que un dato digitado se ignore en silencio). Se levanta cuando se implemente.
alter table public.var_manual drop constraint if exists var_manual_clave_implementada;
alter table public.var_manual add constraint var_manual_clave_implementada check (clave in ('dias_tarde','multiplicador'));

-- var_resumen_mes: los días asignados en DOMINGO no cuentan como días del cargo (domingo no es hábil, K1) y el consolidado
-- por turno se redondea una sola vez.
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
