-- Pruebas de var_horas_vivas y del consolidado del día (solo lectura). Todas deben dar ok = true.
with cfg as (select var_config_vigente(date '2026-09-01') c)
select * from (
  select 'horas vivas M, 6:30 → 12:00 con break = 5,0' prueba, public.var_horas_vivas(date '2026-09-07','M',13,timestamp '2026-09-07 12:00',(select c from cfg)) = 5.0 ok
  union all select 'coherente con el ritmo vivo (20 gestiones → 4,0)', round(20 / public.var_horas_vivas(date '2026-09-07','M',13,timestamp '2026-09-07 12:00',(select c from cfg)),1) = public.var_ritmo_vivo(date '2026-09-07','M',13,20,timestamp '2026-09-07 12:00',(select c from cfg))
  union all select 'primera hora → null', public.var_horas_vivas(date '2026-09-07','M',13,timestamp '2026-09-07 07:15',(select c from cfg)) is null
  union all select 'domingo → null', public.var_horas_vivas(date '2026-09-06','M',13,timestamp '2026-09-06 12:00',(select c from cfg)) is null
  union all select 'sin primera gestión → null', public.var_horas_vivas(date '2026-09-07','M',null,timestamp '2026-09-07 12:00',(select c from cfg)) is null
  union all select 'consolidado_dia existe y tiene la misma forma que consolidado',
    (select bool_and(r->'consolidado_dia'->t ? k) from var_resumen_mes(date '2026-09-01', date '2026-09-05') r, jsonb_object_keys(r->'consolidado_dia') t, unnest(array['gest','conf','canc','efectividad_real','efectividad_cumpl','cancelacion_real','cancelacion_cumpl','ritmo','compuerta','general','lider']) k)
  union all select 'día sin asignaciones → consolidado_dia vacío', (var_resumen_mes(date '2026-08-01', date '2026-08-20')->'consolidado_dia') = '{}'::jsonb
) t;
