-- ============================================================================
-- Módulo de Variables · 023 · Configuración del mes para el cargo Novedades (25-sep-2026, pedido de Daniel)
--  · var_config_vigente: si la configuración guardada (o heredada) no trae las variables de Novedades (configs anteriores a la 019),
--    las completa con las de fábrica, para que el formulario y var_novedades_mes vean siempre metas y pesos.
--  · var_config_guardar: valida también los cargos con `variables` aunque no sean medibles (Novedades): pesos suman 100 y metas > 0
--    (la meta de Gestiones/hora es numérica aunque el tipo sea todo o nada).
-- ============================================================================
create or replace function public.var_config_vigente(p_mes date) returns jsonb
language plpgsql stable set search_path = public, pg_temp as $fn$
declare r record; cfg jsonb; def jsonb := var_config_default(p_mes);
begin
  select c.config, c.version, c.mes into r from var_config_mes c where c.mes = p_mes order by c.version desc limit 1;
  if found then
    cfg := r.config || jsonb_build_object('_version', r.version, '_mes_origen', to_char(r.mes,'YYYY-MM-DD'));
  else
    select c.config, c.version, c.mes into r from var_config_mes c where c.mes < p_mes order by c.mes desc, c.version desc limit 1;
    if found then
      cfg := r.config || jsonb_build_object('_version', r.version, '_mes_origen', to_char(r.mes,'YYYY-MM-DD'), '_heredada', true) || jsonb_build_object('fin_revision', def->>'fin_revision');
    else
      return def || jsonb_build_object('_version', 0, '_default', true, '_mes_origen', to_char(p_mes,'YYYY-MM-DD'));
    end if;
  end if;
  if cfg->'cargos'->'novedades'->'variables' is null then
    cfg := jsonb_set(cfg, '{cargos,novedades}', coalesce(cfg->'cargos'->'novedades', '{}'::jsonb) || (def->'cargos'->'novedades'));
  end if;
  return cfg;
end $fn$;
revoke all on function public.var_config_vigente(date) from public, anon, authenticated;

create or replace function public.var_config_guardar(p_mes date, p_config jsonb, p_motivo text, p_actor uuid) returns integer
language plpgsql set search_path = public, pg_temp as $fn$
declare k text; suma numeric; v jsonb; nueva integer;
begin
  if extract(day from p_mes) <> 1 then raise exception 'El mes debe ser el día 1' using errcode = 'P0010'; end if;
  if p_mes <= var_hoy_col() and coalesce(length(trim(p_motivo)),0) < 5 then
    raise exception 'El mes ya empezó: la corrección exige un motivo' using errcode = 'P0011';
  end if;
  for k in select key from jsonb_each(p_config->'cargos') loop
    if coalesce((p_config->'cargos'->k->>'medible')::boolean, false) or jsonb_typeof(p_config->'cargos'->k->'variables') = 'array' then
      select sum((x->>'peso')::numeric) into suma from jsonb_array_elements(p_config->'cargos'->k->'variables') x;
      if coalesce(suma,0) <> 100 then raise exception 'Los pesos del cargo % suman %, deben sumar 100', k, coalesce(suma,0) using errcode = 'P0012'; end if;
      for v in select x from jsonb_array_elements(p_config->'cargos'->k->'variables') x loop
        if (v->>'tipo' = 'prop' or v ? 'meta') and coalesce((v->>'meta')::numeric, 0) <= 0 then
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
revoke all on function public.var_config_guardar(date, jsonb, text, uuid) from public, anon, authenticated;
