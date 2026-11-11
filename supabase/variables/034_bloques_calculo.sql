-- ============================================================================
-- Módulo de Variables · 034 · Cálculo por bloques de cargo (input 39, 11-nov-2026) · continúa la 033
--  Resumen, líderes, reemplazos, cálculo del mes y Novedades leen ahora el bloque: gestiones por media hora, horas × fracción,
--  días = suma de fracciones. La réplica automática copia los dos bloques.
--  La migración se verifica sola: toma la "huella" del mes anterior (cerrado) y del mes en curso hasta ayer antes de cambiar
--  nada, la vuelve a tomar al final y, si algo cambió, falla y se deshace completa. Sin bloques, los resultados deben ser idénticos.
--  Ajustes de la revisión adversarial (11-nov):
--   · La fracción del tramo se calcula sobre la jornada en que de verdad hay gestión: en la mañana desde las 6:00 (7:00 sábado
--     y festivo), porque entre el 11 % y el 17 % de las gestiones del turno ocurren antes de abrir llamadas. Con la ventana de
--     llamadas el primer tramo quedaba con ritmo inflado y el segundo caía bajo la compuerta. La tarde no cambia.
--   · Las gestiones de la app de Novedades también se reparten por media hora: solo cuentan las del tramo de Novedades.
--   · Un mismo cargo no puede estar dos veces el mismo día (índice único); la réplica junta los tramos si quedarían iguales.
--   · var_gestiones_dia: cuántas gestiones tuvo una persona un día (la Edge no deja al líder marcar ausencia retroactiva
--     si ese día hubo gestiones).
-- ============================================================================
-- Jornada con gestión, en medias horas: inicio, fin y descanso (reemplaza la de la 033, que usaba la ventana de llamadas).
create or replace function public.var_bloque_ventana(d date, turno char, out ini_hh int, out fin_hh int, out brk_hh int)
language plpgsql stable set search_path = public, pg_temp as $fn$
declare dow int := extract(isodow from d); sab boolean;
begin
  if dow = 7 or turno is null then return; end if;
  sab := (dow = 6 or var_es_festivo(d));
  if turno = 'M' then
    ini_hh := case when sab then 14 else 12 end;                        -- 7:00 sábado/festivo · 6:00 el resto (hay gestión antes de abrir llamadas)
    fin_hh := case when sab or dow = 5 then 26 else 28 end;             -- 13:00 viernes, sábado y festivo · 14:00 lunes a jueves
    brk_hh := 20;                                                       -- descanso 10:00
  elsif turno = 'T' then
    ini_hh := case when sab or dow = 5 then 26 else 28 end;             -- 13:00 · 14:00
    fin_hh := case when sab then 38 when dow = 5 then 40 else 42 end;   -- 19:00 · 20:00 · 21:00 (de 21 a 22 casi no hay gestión)
    brk_hh := case when sab then 34 else 36 end;                        -- descanso 17:00 sábado/festivo · 18:00 el resto
  end if;
end $fn$;

-- Un cargo no puede repetirse el mismo día en los dos tramos.
create unique index if not exists var_asignacion_cargo_uq on public.var_asignacion (fecha, agent_id, estado) where vigente;

-- Gestiones de una persona en un día (Refresh + app de Novedades). La usa la Edge para no dejar marcar ausencia retroactiva con gestiones.
create or replace function public.var_gestiones_dia(p_agent_id text, p_fecha date) returns integer
language sql stable set search_path = public, pg_temp as $fn$
  select (select count(*) from events_history e where e.ev_date = p_fecha
            and exists (select 1 from var_agente_alias al where al.agent_id = p_agent_id and al.nombre_norm = var_norm(e.agent) and e.ev_date >= al.desde and (al.hasta is null or e.ev_date <= al.hasta)))::int
       + (select count(*) from nov_gestiones ge join nov_profiles p on p.id = ge.agente_id
           where p.agent_id = p_agent_id and ge.created_at >= p_fecha::timestamp at time zone 'America/Bogota' and ge.created_at < (p_fecha + 1)::timestamp at time zone 'America/Bogota')::int;
$fn$;
revoke all on function public.var_gestiones_dia(text, date) from public, anon, authenticated;

-- Réplica automática: copia los dos tramos y recalcula la fracción para el día nuevo.
create or replace function public.var_replicar_asignacion(p_fecha date) returns jsonb
language plpgsql set search_path = public, pg_temp as $fn$
declare origen date; n int := 0; lunes date := (p_fecha - (extract(isodow from p_fecha)::int - 1))::date;
begin
  if extract(isodow from p_fecha) not between 2 and 6 then return jsonb_build_object('fecha', p_fecha, 'replicadas', 0, 'motivo', 'solo de martes a sábado'); end if;
  if exists (select 1 from var_asignacion where fecha = p_fecha and vigente) then return jsonb_build_object('fecha', p_fecha, 'replicadas', 0, 'motivo', 'ya hay asignación'); end if;
  select max(s.fecha) into origen from var_asignacion s join var_agente g on g.agent_id = s.agent_id
   where s.vigente and s.fecha < p_fecha and s.fecha >= lunes and not g.es_apoyo and s.estado not in ('ausencia','incapacidad');
  if origen is null then return jsonb_build_object('fecha', p_fecha, 'replicadas', 0, 'motivo', 'sin asignación copiable en esta semana: el líder debe asignar a mano'); end if;
  insert into var_asignacion (fecha, agent_id, turno, estado, lider_uid, vigente, creado_por, es_na, replicada, bloque, desde_hh, hasta_hh, frac)
  select p_fecha, x.agent_id, x.turno, x.estado, x.lider, true, x.lider, x.es_na, true,
         case when x.f is null then 1 else x.bloque end,
         case when x.f is not null and x.bloque = 2 then x.cambio end,
         case when x.f is not null and x.bloque = 1 then x.cambio end,
         case when x.f is null then 1 when x.bloque = 1 then x.f else 1 - x.f end
  from (
    select s.agent_id, s.turno, q.estado, s.es_na, s.bloque, q.cambio, q.f,
           coalesce(
             (select ls.lider_uid from var_lider_semana ls join var_usuarios u on u.auth_uid = ls.lider_uid and u.activo
               where ls.semana = lunes and ls.turno = s.turno
               order by exists (select 1 from var_lider_dia ld where ld.lider_uid = ls.lider_uid and ld.fecha = p_fecha) asc, (ls.reemplazo_de is null) desc, ls.lider_uid limit 1),
             (select u.auth_uid from var_usuarios u where u.auth_uid = s.lider_uid and u.activo
               and not exists (select 1 from var_lider_dia ld where ld.lider_uid = u.auth_uid and ld.fecha = p_fecha))) lider
    from var_asignacion s join var_agente g on g.agent_id = s.agent_id
    cross join lateral (select case when s.es_na then g.cargo_permanente else s.estado end estado, coalesce(s.hasta_hh, s.desde_hh) cambio,
                               -- el otro tramo quedaría con el mismo cargo (N/A cuyo cargo permanente cambió): se juntan en uno solo
                               exists (select 1 from var_asignacion o where o.vigente and o.fecha = origen and o.agent_id = s.agent_id and o.bloque <> s.bloque
                                         and (case when o.es_na then g.cargo_permanente else o.estado end) = (case when s.es_na then g.cargo_permanente else s.estado end)) dup) q0
    cross join lateral (select q0.estado, q0.cambio, q0.dup, case when q0.dup then null else var_bloque_frac(p_fecha, s.turno, q0.cambio) end f) q
    where s.vigente and s.fecha = origen and g.activo and (g.hasta is null or g.hasta >= p_fecha) and not g.es_apoyo and s.estado not in ('ausencia','incapacidad')
      and (q.cambio is null                              -- día de un solo cargo
           or q.f is not null                            -- dos tramos y la hora de cambio cabe en la jornada del día nuevo
           or (q.dup and s.bloque = 1)                   -- los dos tramos quedarían con el mismo cargo: uno solo
           or (not q.dup and (s.bloque = 2) = (q.cambio * 2 < (select v.ini_hh + v.fin_hh from var_bloque_ventana(p_fecha, s.turno) v))))   -- no cabe: queda el cargo que ocupa la mayor parte
  ) x where x.lider is not null;
  get diagnostics n = row_count;
  return jsonb_build_object('fecha', p_fecha, 'origen', origen, 'replicadas', n);
end $fn$;
revoke all on function public.var_replicar_asignacion(date) from public, anon, authenticated;

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

create or replace function pg_temp.huella(m date) returns text language sql as $$
  select md5(coalesce((select jsonb_agg(jsonb_build_object('a', a->>'agent_id', 'c', a->'cargos', 'd', a->'dias') order by a->>'agent_id') from jsonb_array_elements(r->'agentes') a), '[]'::jsonb)::text)
      || ' ' || md5(coalesce(r->'consolidado', '{}'::jsonb)::text) || ' ' || md5(coalesce(r->'sin_asignar', '[]'::jsonb)::text)
      || ' ' || md5(public.var_reemplazos_mes(m)::text)
      || ' ' || md5((public.var_calcular_mes(m) - 'hasta')::text)
      || ' ' || md5(coalesce((select jsonb_agg(jsonb_build_object('a', a->>'agent_id', 'm', a->'mes', 'd', a->'dias') order by a->>'agent_id') from jsonb_array_elements(public.var_novedades_mes(m)->'agentes') a), '[]'::jsonb)::text)
      || ' ' || md5(public.var_lideres_mes(m)::text)
      || ' ' || coalesce((select md5(coalesce((select jsonb_agg(jsonb_build_object('a', a->>'agent_id', 'c', a->'cargos', 'd', a->'dias') order by a->>'agent_id') from jsonb_array_elements(r2->'agentes') a), '[]'::jsonb)::text)
                          || ' ' || md5(coalesce(r2->'consolidado', '{}'::jsonb)::text)
                   from (select public.var_resumen_mes((m + interval '1 month')::date, null, null, public.var_hoy_col() - 1) r2) q2
                  where public.var_hoy_col() > (m + interval '1 month')::date), 'mes en curso sin días cerrados')
  from (select public.var_resumen_mes(m) r) q;
$$;

do $do$
declare d text; m_ant date := (date_trunc('month', public.var_hoy_col()) - interval '1 month')::date; antes text; despues text;
  -- fragmentos que se repiten en varias funciones
  k_blq text := $b$(case when b.desde_hh is not null and e.halfhour >= b.desde_hh then 2 else 1 end)::smallint bloque$b$;
  k_b2  text := $b$left join var_asignacion b on b.vigente and b.bloque = 2 and b.fecha = e.ev_date and b.agent_id = e.agent_id$b$;
begin
  antes := pg_temp.huella(m_ant);
  -- ── var_resumen_mes ─────────────────────────────────────────────────────────────────────────────────────────────────────
  d := pg_temp.def('var_resumen_mes');
  d := pg_temp.sub(d,
    $a$  dd as (select agent_id, ev_date as fecha, count(*)::int gest, count(*) filter (where type = 0)::int conf, count(*) filter (where type = 1)::int canc, count(*) filter (where type = 2)::int reprog, min(halfhour)::int primera_hh from ev where agent_id is not null group by 1, 2),$a$,
    $b$  b2 as (select fecha, agent_id, desde_hh from var_asignacion where vigente and bloque = 2 and fecha between d_ini and d_fin),
  dd as (select e.agent_id, e.ev_date as fecha, $b$ || k_blq || $b$, count(*)::int gest, count(*) filter (where e.type = 0)::int conf, count(*) filter (where e.type = 1)::int canc, count(*) filter (where e.type = 2)::int reprog, min(e.halfhour)::int primera_hh from ev e left join b2 b on b.fecha = e.ev_date and b.agent_id = e.agent_id where e.agent_id is not null group by 1, 2, 3),$b$);
  d := pg_temp.sub(d,
    $a$  asg as (select fecha, agent_id, turno, estado, lider_uid, es_na from var_asignacion where vigente and fecha between d_ini and d_fin),$a$,
    $b$  asg as (select fecha, agent_id, turno, estado, lider_uid, es_na, bloque, frac, hasta_hh from var_asignacion where vigente and fecha between d_ini and d_fin),$b$);
  d := pg_temp.sub(d,
    $a$  ad as (select coalesce(d.agent_id, s.agent_id) agent_id, coalesce(d.fecha, s.fecha) fecha, coalesce(d.gest,0) gest, coalesce(d.conf,0) conf, coalesce(d.canc,0) canc, coalesce(d.reprog,0) reprog, d.primera_hh, s.turno, s.estado, s.lider_uid, s.es_na,$a$,
    $b$  ad as (select coalesce(d.agent_id, s.agent_id) agent_id, coalesce(d.fecha, s.fecha) fecha, coalesce(d.gest,0) gest, coalesce(d.conf,0) conf, coalesce(d.canc,0) canc, coalesce(d.reprog,0) reprog, d.primera_hh, s.turno, s.estado, s.lider_uid, s.es_na, coalesce(d.bloque, s.bloque) bloque, coalesce(s.frac, 1) frac, s.hasta_hh,$b$);
  d := pg_temp.sub(d,
    $a$           case when s.turno is null then 0 else var_horas_efectivas(coalesce(d.fecha, s.fecha), s.turno, cfg) end as horas,$a$,
    $b$           case when s.turno is null then 0 else var_horas_efectivas(coalesce(d.fecha, s.fecha), s.turno, cfg) * s.frac end as horas,$b$, 2);
  d := pg_temp.sub(d,
    $a$    from dd d full join asg s on s.fecha = d.fecha and s.agent_id = d.agent_id),$a$,
    $b$    from dd d full join asg s on s.fecha = d.fecha and s.agent_id = d.agent_id and s.bloque = d.bloque),$b$);
  d := pg_temp.sub(d,
    $a$count(*) filter (where not domingo)::int dias,$a$,
    $b$coalesce(sum(frac) filter (where not domingo), 0) dias,$b$);
  d := pg_temp.sub(d,
    $a$  dd_d as (select agent_id, ev_date as fecha, count(*)::int gest, count(*) filter (where type = 0)::int conf, count(*) filter (where type = 1)::int canc, count(*) filter (where type = 2)::int reprog, min(halfhour)::int primera_hh from ev_d group by 1, 2),$a$,
    $b$  dd_d as (select e.agent_id, e.ev_date as fecha, $b$ || k_blq || $b$, count(*)::int gest, count(*) filter (where e.type = 0)::int conf, count(*) filter (where e.type = 1)::int canc, count(*) filter (where e.type = 2)::int reprog, min(e.halfhour)::int primera_hh from ev_d e $b$ || k_b2 || $b$ group by 1, 2, 3),$b$);
  d := pg_temp.sub(d,
    $a$  asg_d as (select fecha, agent_id, turno, estado from var_asignacion where vigente and fecha = dia),$a$,
    $b$  asg_d as (select fecha, agent_id, turno, estado, bloque, frac, desde_hh, hasta_hh from var_asignacion where vigente and fecha = dia),$b$);
  d := pg_temp.sub(d,
    $a$  ad_d as (select coalesce(d.agent_id, s.agent_id) agent_id, coalesce(d.fecha, s.fecha) fecha, coalesce(d.gest,0) gest, coalesce(d.conf,0) conf, coalesce(d.canc,0) canc, coalesce(d.reprog,0) reprog, d.primera_hh, s.turno, s.estado,$a$,
    $b$  ad_d as (select coalesce(d.agent_id, s.agent_id) agent_id, coalesce(d.fecha, s.fecha) fecha, coalesce(d.gest,0) gest, coalesce(d.conf,0) conf, coalesce(d.canc,0) canc, coalesce(d.reprog,0) reprog, d.primera_hh, s.turno, s.estado, coalesce(d.bloque, s.bloque) bloque, s.desde_hh, s.hasta_hh,$b$);
  d := pg_temp.sub(d,
    $a$    from dd_d d full join asg_d s on s.fecha = d.fecha and s.agent_id = d.agent_id),$a$,
    $b$    from dd_d d full join asg_d s on s.fecha = d.fecha and s.agent_id = d.agent_id and s.bloque = d.bloque),$b$);
  d := pg_temp.sub(d,
    $a$var_ritmo_vivo(a.fecha, a.turno, a.primera_hh, a.gest, ahora, cfg)$a$,
    $b$var_ritmo_vivo(a.fecha, a.turno, a.primera_hh, a.gest, least(ahora, a.fecha + a.hasta_hh * interval '30 minutes'), cfg)$b$);
  d := pg_temp.sub(d,
    $a$var_horas_vivas(a.fecha, a.turno, a.primera_hh, ahora, cfg) else a.horas end as horas_r$a$,
    $b$var_horas_vivas(a.fecha, a.turno, a.primera_hh, least(ahora, a.fecha + a.hasta_hh * interval '30 minutes'), cfg) else a.horas end as horas_r$b$);
  d := pg_temp.sub(d,
    $a$where vigente and fecha between p_mes and dia order by agent_id, fecha desc),$a$,
    $b$where vigente and fecha between p_mes and dia order by agent_id, fecha desc, bloque),$b$);
  d := pg_temp.sub(d,
    $a$'ritmo', x.ritmo, 'compuerta', x.compuerta, 'general', x.general, 'medible', x.medible) from dxg x where x.agent_id = g.agent_id),$a$,
    $b$'ritmo', x.ritmo, 'compuerta', x.compuerta, 'general', x.general, 'medible', x.medible) from dxg x where x.agent_id = g.agent_id order by x.bloque limit 1),
        'dia_bloques', (select jsonb_agg(jsonb_build_object('bloque', x.bloque, 'desde_hh', x.desde_hh, 'hasta_hh', x.hasta_hh, 'fecha', x.fecha, 'cargo', x.estado, 'turno', x.turno, 'gest', x.gest, 'conf', x.conf, 'canc', x.canc, 'reprog', x.reprog, 'horas', x.horas,
                  'efectividad_real', x.ef_real, 'efectividad_cumpl', x.ef_cumpl, 'cancelacion_real', x.ca_real, 'cancelacion_cumpl', x.ca_cumpl,
                  'ritmo', x.ritmo, 'compuerta', x.compuerta, 'general', x.general, 'medible', x.medible) order by x.bloque)
                from dxg x where x.agent_id = g.agent_id and exists (select 1 from dxg y where y.agent_id = g.agent_id and y.bloque = 2)),$b$);
  d := pg_temp.sub(d,
    $a$'reprog', d.reprog, 'horas', d.horas) order by d.fecha) from ad d where d.agent_id = g.agent_id), '[]'::jsonb)$a$,
    $b$'reprog', d.reprog, 'horas', d.horas) || case when d.bloque = 2 or d.hasta_hh is not null then jsonb_build_object('bloque', d.bloque) else '{}'::jsonb end order by d.fecha, d.bloque) from ad d where d.agent_id = g.agent_id), '[]'::jsonb)$b$);
  execute d;

  -- ── var_lideres_mes y var_reemplazos_mes ────────────────────────────────────────────────────────────────────────────────
  d := pg_temp.def('var_lideres_mes');
  d := pg_temp.sub(d, $a$  ev as (select e.ev_date, e.type, a.agent_id from events_history e$a$, $b$  ev as (select e.ev_date, e.type, e.halfhour, a.agent_id from events_history e$b$);
  d := pg_temp.sub(d,
    $a$  dd as (select agent_id, ev_date fecha, count(*)::int gest, count(*) filter (where type = 0)::int conf, count(*) filter (where type = 1)::int canc from ev group by 1, 2),$a$,
    $b$  dd as (select e.agent_id, e.ev_date fecha, $b$ || k_blq || $b$, count(*)::int gest, count(*) filter (where e.type = 0)::int conf, count(*) filter (where e.type = 1)::int canc from ev e $b$ || k_b2 || $b$ group by 1, 2, 3),$b$);
  d := pg_temp.sub(d, $a$  asg as (select x.* from (select a.fecha, a.agent_id, a.turno, a.estado,$a$, $b$  asg as (select x.* from (select a.fecha, a.agent_id, a.turno, a.estado, a.bloque, a.frac,$b$);
  d := pg_temp.sub(d, $a$           var_horas_efectivas(s.fecha, s.turno, cfg) horas,$a$, $b$           var_horas_efectivas(s.fecha, s.turno, cfg) * s.frac horas,$b$);
  d := pg_temp.sub(d, $a$         from asg s left join dd d on d.fecha = s.fecha and d.agent_id = s.agent_id$a$, $b$         from asg s left join dd d on d.fecha = s.fecha and d.agent_id = s.agent_id and d.bloque = s.bloque$b$);
  execute d;

  d := pg_temp.def('var_reemplazos_mes');
  d := pg_temp.sub(d, $a$  rs as (select a.fecha, a.agent_id, a.turno, a.estado, a.lider_uid, ls.reemplazo_de titular$a$, $b$  rs as (select a.fecha, a.agent_id, a.turno, a.estado, a.bloque, a.frac, a.lider_uid, ls.reemplazo_de titular$b$);
  d := pg_temp.sub(d, $a$  ev as (select e.ev_date, e.type, a.agent_id from events_history e$a$, $b$  ev as (select e.ev_date, e.type, e.halfhour, a.agent_id from events_history e$b$);
  d := pg_temp.sub(d,
    $a$  dd as (select agent_id, ev_date fecha, count(*)::int gest, count(*) filter (where type = 0)::int conf, count(*) filter (where type = 1)::int canc from ev group by 1, 2),$a$,
    $b$  dd as (select e.agent_id, e.ev_date fecha, $b$ || k_blq || $b$, count(*)::int gest, count(*) filter (where e.type = 0)::int conf, count(*) filter (where e.type = 1)::int canc from ev e $b$ || k_b2 || $b$ group by 1, 2, 3),$b$);
  d := pg_temp.sub(d, $a$           var_horas_efectivas(s.fecha, s.turno, cfg) horas,$a$, $b$           var_horas_efectivas(s.fecha, s.turno, cfg) * s.frac horas,$b$);
  d := pg_temp.sub(d, $a$         from rs s left join dd d on d.fecha = s.fecha and d.agent_id = s.agent_id$a$, $b$         from rs s left join dd d on d.fecha = s.fecha and d.agent_id = s.agent_id and d.bloque = s.bloque$b$);
  execute d;

  -- ── var_calcular_mes: los días en el cargo ya pueden tener decimales ────────────────────────────────────────────────────
  d := pg_temp.def('var_calcular_mes');
  d := pg_temp.sub(d, $a$mult_txt text; nov_dias integer; medibles integer;$a$, $b$mult_txt text; nov_dias numeric; medibles integer;$b$);
  d := pg_temp.sub(d, $a$nov_dias := (c->>'dias')::int;$a$, $b$nov_dias := (c->>'dias')::numeric;$b$);
  d := pg_temp.sub(d, $a$'dias', (c->>'dias')::int, 'dias_habiles', dh,$a$, $b$'dias', (c->>'dias')::numeric, 'dias_habiles', dh,$b$);
  execute d;

  -- ── var_novedades_mes: horas y días del bloque de Novedades ─────────────────────────────────────────────────────────────
  d := pg_temp.def('var_novedades_mes');
  d := pg_temp.sub(d, $a$  ad as (select s.fecha, s.agent_id, s.turno, p.id as perfil from var_asignacion s$a$, $b$  ad as (select s.fecha, s.agent_id, s.turno, p.id as perfil, s.frac, s.desde_hh, s.hasta_hh from var_asignacion s$b$);
  d := pg_temp.sub(d, $a$  g as (select ad.fecha, ad.agent_id, ad.turno, ge.id,$a$, $b$  g as (select ad.fecha, ad.agent_id, ad.turno, ad.frac, ad.hasta_hh, ge.id,$b$);
  d := pg_temp.sub(d,
    $a$and (ge.created_at at time zone 'America/Bogota')::date = ad.fecha$a$,
    $b$and (ge.created_at at time zone 'America/Bogota')::date = ad.fecha
                                          and (ad.desde_hh is null or extract(hour from ge.created_at at time zone 'America/Bogota')::int * 2 + (extract(minute from ge.created_at at time zone 'America/Bogota')::int / 30) >= ad.desde_hh)
                                          and (ad.hasta_hh is null or extract(hour from ge.created_at at time zone 'America/Bogota')::int * 2 + (extract(minute from ge.created_at at time zone 'America/Bogota')::int / 30) < ad.hasta_hh)$b$);
  d := pg_temp.sub(d, $a$  dd as (select fecha, agent_id, turno,$a$, $b$  dd as (select fecha, agent_id, turno, frac, hasta_hh,$b$);
  d := pg_temp.sub(d, $a$         from gy group by 1, 2, 3),$a$, $b$         from gy group by 1, 2, 3, 4, 5),$b$);
  d := pg_temp.sub(d,
    $a$var_horas_vivas(dd.fecha, dd.turno, dd.primera_hh, ahora, cfg) else nullif(var_horas_efectivas(dd.fecha, dd.turno, cfg), 0) end as horas$a$,
    $b$var_horas_vivas(dd.fecha, dd.turno, dd.primera_hh, least(ahora, dd.fecha + dd.hasta_hh * interval '30 minutes'), cfg) else nullif(var_horas_efectivas(dd.fecha, dd.turno, cfg) * dd.frac, 0) end as horas$b$);
  d := pg_temp.sub(d, $a$  mh as (select agent_id, count(*)::int dias, sum(intentos)::int intentos,$a$, $b$  mh as (select agent_id, sum(frac) dias, sum(intentos)::int intentos,$b$);
  execute d;

  despues := pg_temp.huella(m_ant);
  if despues is distinct from antes then
    raise exception 'El mes % cambió con la migración (antes % · después %): se deshace todo', to_char(m_ant, 'YYYY-MM'), antes, despues;
  end if;
  raise notice 'Huella de % idéntica antes y después: %', to_char(m_ant, 'YYYY-MM'), despues;
end $do$;
