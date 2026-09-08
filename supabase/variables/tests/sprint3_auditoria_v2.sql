-- Pruebas de la migración 013 (solo lectura). Todas deben dar ok = true.
select * from (
  select 'catálogo: 27 tipos sembrados' prueba, (select count(*) from var_error_tipo where activo) >= 27 ok
  union all select '12 rojos, 7 amarillos, 8 verdes', (select array_agg(n order by color) from (select color, count(*)::int n from var_error_tipo where orden between 1 and 27 group by color) x) = array[7,12,8]
  union all select 'nombre_norm coincide con var_norm', not exists (select 1 from var_error_tipo where nombre_norm <> var_norm(nombre))
  union all select 'tiendas por país: países en mayúsculas', (select bool_and(k = upper(k)) from jsonb_object_keys(var_tiendas_pais()) k)
  union all select 'ninguna tienda en dos países', (select count(*) from (select t, count(*) from jsonb_each(var_tiendas_pais()) p, jsonb_array_elements_text(p.value) t group by t having count(*) > 1) x) = 0
  union all select 'contacto: orden inválida → no encontrada', (var_orden_contacto('abc')->>'encontrada')::boolean = false
  union all select 'contacto: orden con celular → encontrada y solo dígitos', (select (c->>'encontrada')::boolean and (c->>'celular') ~ '^\d+$' from (select var_orden_contacto((select order_id::text from orders_contact where phone is not null limit 1)) c) x)
  union all select 'roster con fecha excluye salidas anteriores', coalesce((select bool_and((g->>'hasta') is null or (g->>'hasta')::date >= date '2026-09-08') from jsonb_array_elements(var_roster(date '2026-09-08')) g), true)
  union all select 'histórico: no incluye a nadie ya enlazado', not exists (select 1 from jsonb_array_elements(var_personas_historico()) p join var_agente_alias al on al.nombre_norm = var_norm(p->>'nombre'))
  union all select 'auditoría del mes se cuenta por fecha_auditoria', (select pg_get_functiondef('public.var_resumen_mes(date,date,date,date)'::regprocedure) ~ 'e.fecha_auditoria between p_mes')
  union all select 'adjuntos: bucket privado', (select not public from storage.buckets where id = 'auditoria-evidencias')
  union all select 'cargo agente_whatsapp permitido', (select pg_get_constraintdef(oid) ~ 'agente_whatsapp' from pg_constraint where conname = 'var_agente_cargo_permanente_check')
) t;

-- Pruebas de la 014 (revisión adversarial). Todas deben dar ok = true.
select * from (
  select 'resumen: CTE agentes filtra por hasta' prueba, (select pg_get_functiondef('public.var_resumen_mes(date,date,date,date)'::regprocedure) ~ 'g.hasta >= p_mes') ok
  union all select 'roster con fecha pasada devuelve al equipo de ese día', jsonb_array_length(var_roster(date '2026-09-05')) > 0
  union all select 'roster trae la bandera salio', (select bool_and(g ? 'salio') from jsonb_array_elements(var_roster()) g)
  union all select 'histórico sin pseudo-agentes', not exists (select 1 from jsonb_array_elements(var_personas_historico()) p where var_es_excluido(p->>'nombre'))
  union all select 'índice único parcial creado', exists (select 1 from pg_indexes where indexname = 'var_auditoria_unica_idx')
  union all select 'bucket privado con mime permitidos', (select allowed_mime_types @> array['application/pdf'] and not public from storage.buckets where id = 'auditoria-evidencias')
  union all select 'persona_agregar tiene p_es_admin', exists (select 1 from pg_proc where proname = 'var_persona_agregar' and pronargs = 6)
) t;
