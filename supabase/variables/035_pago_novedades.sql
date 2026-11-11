-- ============================================================================
-- Módulo de Variables · 035 · Pago de Gestión de Novedades y bloque Novedades del líder (input 39, 11-nov-2026)
--  A) Agentes: el cargo Gestión de Novedades ya se paga dentro del dashboard (antes decía "se liquida por fuera"):
--       valor del cargo × (días en el cargo ÷ días hábiles) × Σ(peso × factor) ÷ Σ(pesos medibles)
--     Solución y Gestión Ácida por la escalera de siempre; Gestiones por hora todo o nada (cumple la meta = 1, no = 0);
--     Puntualidad igual que en los demás cargos. Lo que no se pueda medir redistribuye su peso. El multiplicador de auditoría
--     se aplica al total de la persona, como hasta ahora.
--  B) Líder: el bloque Novedades (30 %) ya tiene fuente. Se mide con los resultados de las personas de Novedades que el líder
--     firmó en la asignación (mismas reglas que Operación: el reemplazo cuenta para el titular; los días de ausencia del
--     líder no cuentan). Pesos 35/25/25 de la configuración de Novedades, sin Puntualidad.
--       total = 70 % × Operación + 30 % × Novedades; si un bloque entero no tiene resultados, el otro pesa 100 %.
--  C) var_novedades_mes devuelve además 'por_lider' (resultados de Novedades agrupados por líder).
--  Ajustes de la revisión adversarial (11-nov):
--   · Sin gestiones en el panel de Novedades (Solución y Gestión Ácida sin dato) el cargo paga $0 y el bloque del líder queda
--     "sin resultados" (antes la Puntualidad sola pagaba 37,5 % y un día sin gestiones hundía el bloque del líder).
--   · Si la medición de Novedades falla, el Pago del mes sigue funcionando (Novedades queda en $0 con un aviso visible).
--   · La migración termina con una llamada de prueba a var_calcular_mes (mes en curso, mes anterior y un rango).
-- ============================================================================
create or replace function pg_temp.sub(p_def text, p_old text, p_new text, p_n int default 1) returns text language plpgsql as $$
begin
  if (length(p_def) - length(replace(p_def, p_old, ''))) / length(p_old) <> p_n then
    raise exception 'fragmento no encontrado % vez/veces: %', p_n, left(p_old, 90);
  end if;
  return replace(p_def, p_old, p_new);
end $$;
create or replace function pg_temp.def(p_nombre text) returns text language sql as $$
  select pg_get_functiondef(p.oid) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = p_nombre;
$$;

do $do$
declare d text;
begin
  -- ── var_novedades_mes: resultados por líder ─────────────────────────────────────────────────────────────────────────────
  d := pg_temp.def('var_novedades_mes');
  d := pg_temp.sub(d,
    $a$  ad as (select s.fecha, s.agent_id, s.turno, p.id as perfil, s.frac, s.desde_hh, s.hasta_hh from var_asignacion s join nov_profiles p on p.agent_id = s.agent_id$a$,
    $b$  ad as (select x.*, not exists (select 1 from var_lider_dia ld where ld.lider_uid = x.lider_uid and ld.fecha = x.fecha) lider_ok
         from (select s.fecha, s.agent_id, s.turno, p.id as perfil, s.frac, s.desde_hh, s.hasta_hh,
                 coalesce((select ls.reemplazo_de from var_lider_semana ls where ls.lider_uid = s.lider_uid and ls.reemplazo_de is not null
                             and ls.semana = (s.fecha - (extract(isodow from s.fecha)::int - 1))::date limit 1), s.lider_uid) lider_uid
         from var_asignacion s join nov_profiles p on p.agent_id = s.agent_id$b$);
  d := pg_temp.sub(d,
    $a$         where s.vigente and s.estado = 'novedades' and s.fecha between r_ini and r_fin),$a$,
    $b$         where s.vigente and s.estado = 'novedades' and s.fecha between r_ini and r_fin) x),$b$);
  d := pg_temp.sub(d, $a$  g as (select ad.fecha, ad.agent_id, ad.turno, ad.frac, ad.hasta_hh, ge.id,$a$, $b$  g as (select ad.fecha, ad.agent_id, ad.turno, ad.frac, ad.hasta_hh, ad.lider_uid, ad.lider_ok, ge.id,$b$);
  d := pg_temp.sub(d, $a$  dd as (select fecha, agent_id, turno, frac, hasta_hh,$a$, $b$  dd as (select fecha, agent_id, turno, frac, hasta_hh, lider_uid, lider_ok,$b$);
  d := pg_temp.sub(d, $a$         from gy group by 1, 2, 3, 4, 5),$a$, $b$         from gy group by 1, 2, 3, 4, 5, 6, 7),$b$);
  d := pg_temp.sub(d,
    $a$  agentes as (select distinct a.agent_id, a.nombre from var_agente a join ad on ad.agent_id = a.agent_id),$a$,
    $b$  lh as (select lider_uid, sum(frac) dias, sum(intentos)::int intentos,
                sum(case when fecha = hoy then 0 else coalesce(horas, 0) end)::numeric horas_cerradas,
                sum(case when fecha = hoy or horas is null then 0 else intentos end)::int intentos_cerrados
         from ddx where lider_ok and fecha between d_ini and d_fin group by 1),
  lo as (select lider_uid, count(distinct order_id)::int ordenes, count(distinct order_id) filter (where solucion_ok)::int ordenes_sol,
                count(id) filter (where not dev_excluida and coalesce(final_tipo,'') <> 'excluido')::int intentos_validos,
                count(distinct order_id) filter (where acida)::int ordenes_acidas
         from gy where lider_ok and fecha between d_ini and d_fin group by 1),
  lx as (select lh.lider_uid, lh.dias, lh.intentos, lh.horas_cerradas, lo.ordenes,
                case when lo.ordenes > 0 then round(lo.ordenes_sol * 100.0 / lo.ordenes, 1) end as sol_real,
                case when lo.intentos_validos > 0 then round(lo.ordenes_acidas * 100.0 / lo.intentos_validos, 1) end as aci_real,
                case when lh.horas_cerradas > 0 then round(lh.intentos_cerrados / lh.horas_cerradas, 1) end as gh_real
         from lh join lo on lo.lider_uid = lh.lider_uid),
  agentes as (select distinct a.agent_id, a.nombre from var_agente a join ad on ad.agent_id = a.agent_id),$b$);
  d := pg_temp.sub(d,
    $a$    'sin_puente', coalesce((select jsonb_agg($a$,
    $b$    'por_lider', coalesce((select jsonb_agg(jsonb_build_object('lider_uid', l.lider_uid, 'dias', l.dias, 'intentos', l.intentos, 'ordenes', l.ordenes, 'horas', round(l.horas_cerradas, 2),
        'solucion_real', l.sol_real, 'solucion_cumpl', case when l.sol_real is not null and m_sol > 0 then least(150.0, round(l.sol_real * 100 / m_sol, 1)) end,
        'acida_real', l.aci_real, 'acida_cumpl', case when l.aci_real is null then null when l.aci_real = 0 then 150.0 when m_aci > 0 then least(150.0, round(m_aci * 100 / l.aci_real, 1)) end,
        'gest_h', l.gh_real, 'gest_h_cumpl', case when l.gh_real is null then null when l.gh_real >= m_gh then 100.0 else 0.0 end) order by l.lider_uid) from lx l), '[]'::jsonb),
    'sin_puente', coalesce((select jsonb_agg($b$);
  execute d;

  -- ── var_calcular_mes: paga Novedades y arma el bloque Novedades del líder ───────────────────────────────────────────────
  d := pg_temp.def('var_calcular_mes');
  d := pg_temp.sub(d,
    $a$  dias_debia integer; razon numeric; lw_ef numeric; lw_ca numeric; n_sa integer;$a$,
    $b$  dias_debia integer; razon numeric; lw_ef numeric; lw_ca numeric; n_sa integer;
  nv jsonb := '{}'::jsonb; nvl jsonb := '{}'::jsonb; nm jsonb; nl jsonb; nov_err boolean := false;
  v_nov numeric := coalesce((cfg->'cargos'->'novedades'->>'valor')::numeric, 0);
  b_nov numeric := coalesce((cfg->'cargos'->'lider'->'bloques'->>'novedades')::numeric, 0.30);
  wn_sol numeric; wn_aci numeric; wn_gh numeric; wn_pu numeric; fn_sol numeric; fn_aci numeric; fn_gh numeric;
  suma_o numeric; suma_n numeric; b_o numeric; b_n numeric;$b$);
  d := pg_temp.sub(d,
    $a$    into lw_ef, lw_ca from jsonb_array_elements(coalesce(cfg->'cargos'->'verificacion'->'variables','[]'::jsonb)) v;$a$,
    $b$    into lw_ef, lw_ca from jsonb_array_elements(coalesce(cfg->'cargos'->'verificacion'->'variables','[]'::jsonb)) v;
  select coalesce(max(case when v->>'clave'='solucion' then (v->>'peso')::numeric end),35), coalesce(max(case when v->>'clave'='gestion_acida' then (v->>'peso')::numeric end),25),
         coalesce(max(case when v->>'clave'='gestiones_hora' then (v->>'peso')::numeric end),25), coalesce(max(case when v->>'clave'='puntualidad' then (v->>'peso')::numeric end),15)
    into wn_sol, wn_aci, wn_gh, wn_pu from jsonb_array_elements(coalesce(cfg->'cargos'->'novedades'->'variables','[]'::jsonb)) v;
  if p_mes <= var_hoy_col() then
    begin
      nv := var_novedades_mes(p_mes, null, p_desde, p_hasta);
      nvl := case when p_desde is null and p_hasta is null then nv else var_novedades_mes(p_mes) end;   -- los líderes siempre son del mes completo
    exception when others then
      nv := '{}'::jsonb; nvl := '{}'::jsonb; nov_err := true;   -- la medición de Novedades falló: el resto del pago sigue; Novedades queda en $0 con aviso
    end;
  end if;$b$);
  d := pg_temp.sub(d,
    $a$      if c->>'cargo' = 'novedades' then nov_dias := (c->>'dias')::numeric; continue; end if;$a$,
    $b$      if c->>'cargo' = 'novedades' then
        nov_dias := (c->>'dias')::numeric;
        select x->'mes' into nm from jsonb_array_elements(nv->'agentes') x where x->>'agent_id' = ag->>'agent_id';
        fn_sol := var_escalera((nm->>'solucion_cumpl')::numeric);
        fn_aci := var_escalera((nm->>'acida_cumpl')::numeric);
        fn_gh := case when (nm->>'gest_h_cumpl') is null then null when (nm->>'gest_h_cumpl')::numeric >= 100 then 1 else 0 end;
        if fn_sol is null and fn_aci is null then   -- sin gestiones en el panel de Novedades esos días: no hay qué medir
          suma := 0; pend := pend || to_jsonb(case when nov_err then 'Gestión de Novedades: la medición no está disponible en este momento → $0 por ahora'
                                                   else 'Gestión de Novedades: sin gestiones en el panel de Novedades en esos días → $0 hasta enlazar a la persona con el panel o corregir la asignación' end);
        else
          if fn_sol is null then pend := pend || '"Gestión de Novedades: Solución no medible (su peso se redistribuye)"'::jsonb; end if;
          if fn_aci is null then pend := pend || '"Gestión de Novedades: Gestión Ácida no medible (su peso se redistribuye)"'::jsonb; end if;
          if fn_gh is null then pend := pend || '"Gestión de Novedades: Gestiones por hora no medible (su peso se redistribuye)"'::jsonb; end if;
          sum_w := coalesce(case when fn_sol is not null then wn_sol end,0) + coalesce(case when fn_aci is not null then wn_aci end,0) + coalesce(case when fn_gh is not null then wn_gh end,0) + wn_pu;
          suma := coalesce((coalesce(fn_sol * wn_sol, 0) + coalesce(fn_aci * wn_aci, 0) + coalesce(fn_gh * wn_gh, 0) + coalesce(f_pu, 1) * wn_pu) / nullif(sum_w, 0), 0);
        end if;
        subtotal := v_nov * (nov_dias / dh) * suma;
        pago := pago + subtotal;
        cargos := cargos || jsonb_build_object('cargo', 'novedades', 'nombre', coalesce(cfg->'cargos'->'novedades'->>'nombre', 'Gestión de Novedades'), 'valor', v_nov, 'dias', nov_dias, 'dias_habiles', dh,
          'solucion_real', nm->'solucion_real', 'solucion_cumpl', nm->'solucion_cumpl', 'factor_solucion', fn_sol,
          'acida_real', nm->'acida_real', 'acida_cumpl', nm->'acida_cumpl', 'factor_acida', fn_aci,
          'gest_h', nm->'gest_h', 'gest_h_cumpl', nm->'gest_h_cumpl', 'factor_gest_h', fn_gh,
          'dias_tarde', dias_tarde, 'factor_puntualidad', f_pu,
          'pesos', jsonb_build_object('solucion', wn_sol, 'gestion_acida', wn_aci, 'gestiones_hora', wn_gh, 'puntualidad', wn_pu),
          'reconocimiento', round(suma * 100, 1), 'subtotal', round(subtotal, 0));
        continue;
      end if;$b$);
  d := pg_temp.sub(d,
    $a$    if nov_dias > 0 then pend := pend || to_jsonb(format('Novedades: %s día(s) se liquidan por fuera', nov_dias)); end if;$a$,
    $b$    if nov_dias > 0 and v_nov = 0 then pend := pend || '"Gestión de Novedades: el valor del cargo no está configurado para este mes"'::jsonb; end if;$b$);
  d := pg_temp.sub(d,
    $a$    suma := case when sum_w = 0 then 0 else (coalesce(f_ef * lw_ef, 0) + coalesce(f_ca * lw_ca, 0)) / sum_w end;$a$,
    $b$    suma_o := case when sum_w = 0 then null else (coalesce(f_ef * lw_ef, 0) + coalesce(f_ca * lw_ca, 0)) / sum_w end;
    nl := null;
    select x into nl from jsonb_array_elements(nvl->'por_lider') x where x->>'lider_uid' = li->>'lider_uid';
    fn_sol := var_escalera((nl->>'solucion_cumpl')::numeric);
    fn_aci := var_escalera((nl->>'acida_cumpl')::numeric);
    fn_gh := case when (nl->>'gest_h_cumpl') is null then null when (nl->>'gest_h_cumpl')::numeric >= 100 then 1 else 0 end;
    sum_w := coalesce(case when fn_sol is not null then wn_sol end,0) + coalesce(case when fn_aci is not null then wn_aci end,0) + coalesce(case when fn_gh is not null then wn_gh end,0);
    suma_n := case when sum_w = 0 or (fn_sol is null and fn_aci is null) then null else (coalesce(fn_sol * wn_sol, 0) + coalesce(fn_aci * wn_aci, 0) + coalesce(fn_gh * wn_gh, 0)) / sum_w end;   -- sin gestiones de Novedades: bloque sin resultados
    b_o := case when suma_o is null then 0 when suma_n is null or b_oper + b_nov = 0 then 1 else b_oper / (b_oper + b_nov) end;
    b_n := case when suma_n is null then 0 else 1 - b_o end;
    suma := coalesce(suma_o, 0) * b_o + coalesce(suma_n, 0) * b_n;$b$);
  d := pg_temp.sub(d,
    $a$    pend := pend || '"bloque Novedades (30 %) vacío hasta que exista su fuente: Operación pesa 100 %"'::jsonb;$a$,
    $b$    if suma_n is null and suma_o is not null then pend := pend || '"sin resultados de Novedades a su cargo este mes: Operación pesa 100 %"'::jsonb; end if;
    if suma_o is null and suma_n is not null then pend := pend || '"sin resultados de Operación a su cargo este mes: Novedades pesa 100 %"'::jsonb; end if;$b$);
  d := pg_temp.sub(d,
    $a$      'bloque_operacion', b_oper, 'bloque_operacion_efectivo', 1.0, 'pesos', jsonb_build_object('efectividad', lw_ef, 'cancelacion', lw_ca), 'reconocimiento', round(suma * 100, 1),$a$,
    $b$      'bloque_operacion', b_oper, 'bloque_novedades', b_nov, 'bloque_operacion_efectivo', round(b_o, 4), 'bloque_novedades_efectivo', round(b_n, 4),
      'reconocimiento_operacion', round(suma_o * 100, 1), 'reconocimiento_novedades', round(suma_n * 100, 1),
      'novedades', case when nl is null or suma_n is null then null else jsonb_build_object('dias', nl->'dias', 'intentos', nl->'intentos', 'ordenes', nl->'ordenes',
          'solucion_real', nl->'solucion_real', 'solucion_cumpl', nl->'solucion_cumpl', 'factor_solucion', fn_sol,
          'acida_real', nl->'acida_real', 'acida_cumpl', nl->'acida_cumpl', 'factor_acida', fn_aci,
          'gest_h', nl->'gest_h', 'gest_h_cumpl', nl->'gest_h_cumpl', 'factor_gest_h', fn_gh,
          'pesos', jsonb_build_object('solucion', wn_sol, 'gestion_acida', wn_aci, 'gestiones_hora', wn_gh)) end,
      'pesos', jsonb_build_object('efectividad', lw_ef, 'cancelacion', lw_ca), 'reconocimiento', round(suma * 100, 1),$b$);
  d := pg_temp.sub(d, $a$    'sin_alias', r->'sin_alias',$a$, $b$    'novedades_error', nov_err, 'sin_alias', r->'sin_alias',$b$);
  execute d;

  -- Prueba de humo: si el cálculo falla con datos reales, la migración se deshace.
  perform public.var_calcular_mes(date_trunc('month', public.var_hoy_col())::date);
  perform public.var_calcular_mes((date_trunc('month', public.var_hoy_col()) - interval '1 month')::date);
  perform public.var_calcular_mes(date_trunc('month', public.var_hoy_col())::date, date_trunc('month', public.var_hoy_col())::date, public.var_hoy_col());
  if (public.var_calcular_mes(date_trunc('month', public.var_hoy_col())::date)->>'novedades_error')::boolean then
    raise exception 'La medición de Novedades falla dentro de var_calcular_mes: se deshace la migración';
  end if;
end $do$;
