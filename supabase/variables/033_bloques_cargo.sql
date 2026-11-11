-- ============================================================================
-- Módulo de Variables · 033 · Dos cargos en una misma jornada ("bloques") (input 39, 11-nov-2026)
--  Un agente puede tener hasta dos cargos el mismo día: el primero desde el inicio del turno hasta la "hora de cambio" y el
--  segundo desde esa hora hasta el final (ej.: 7–9 Verificación Histórica y 9–14 Novedades).
--   · var_asignacion gana bloque (1|2), desde_hh / hasta_hh (media hora del día: hora*2 + (min>=30)) y frac (parte de las horas
--     efectivas del día que le toca al bloque). Un día sin segundo cargo es bloque 1, frac 1: todo lo anterior queda igual.
--   · Las gestiones de Refresh se reparten por su media hora: desde la hora de cambio en adelante son del segundo bloque.
--   · Días en el cargo = suma de fracciones (un día partido cuenta, p. ej., 0,31 en un cargo y 0,69 en el otro); las horas
--     efectivas de cada bloque = horas del día × fracción. En vivo, el ritmo del primer bloque se corta en la hora de cambio.
--   · La réplica automática copia los dos bloques y recalcula la fracción para el día nuevo (viernes y sábado tienen otra
--     jornada); si la hora de cambio no cabe en la jornada del día nuevo, queda un solo cargo (el que ocupa la mayor parte).
--  Esta migración solo prepara la tabla, las funciones de la jornada y var_asignar; el cálculo por bloques va en la 034.
-- ============================================================================
alter table public.var_asignacion
  add column if not exists bloque smallint not null default 1,
  add column if not exists desde_hh smallint,
  add column if not exists hasta_hh smallint,
  add column if not exists frac numeric not null default 1;
alter table public.var_asignacion drop constraint if exists var_asignacion_bloque_ck;
alter table public.var_asignacion add constraint var_asignacion_bloque_ck check (
  bloque in (1, 2) and frac > 0 and frac <= 1
  and (bloque = 1 or (desde_hh is not null and hasta_hh is null and frac < 1))
  and (bloque = 2 or desde_hh is null)
  and (hasta_hh is null or frac < 1));
drop index if exists public.var_asignacion_vigente_uq;
create unique index var_asignacion_vigente_uq on public.var_asignacion (fecha, agent_id, bloque) where vigente;

-- Jornada de llamadas del día, en medias horas (reglamento §5): inicio, fin y descanso (media hora).
create or replace function public.var_bloque_ventana(d date, turno char, out ini_hh int, out fin_hh int, out brk_hh int)
language plpgsql stable set search_path = public, pg_temp as $fn$
declare dow int := extract(isodow from d); sab boolean;
begin
  if dow = 7 or turno is null then return; end if;
  sab := (dow = 6 or var_es_festivo(d));
  if turno = 'M' then
    ini_hh := case when sab then 16 else 14 end;                        -- 8:00 sábado/festivo · 7:00 el resto
    fin_hh := case when sab or dow = 5 then 26 else 28 end;             -- 13:00 viernes, sábado y festivo · 14:00 lunes a jueves
    brk_hh := 20;                                                       -- descanso 10:00
  elsif turno = 'T' then
    ini_hh := case when sab or dow = 5 then 26 else 28 end;             -- 13:00 · 14:00
    fin_hh := case when sab then 38 when dow = 5 then 40 else 42 end;   -- 19:00 · 20:00 · 21:00
    brk_hh := case when sab then 34 else 36 end;                        -- descanso 17:00 sábado/festivo · 18:00 el resto
  end if;
end $fn$;
revoke all on function public.var_bloque_ventana(date, char) from public, anon, authenticated;

-- Parte de las horas efectivas del día que cae ANTES de la hora de cambio (primer bloque). Nulo si la hora no parte la jornada
-- en dos tramos de al menos una hora cada uno.
create or replace function public.var_bloque_frac(d date, turno char, cambio_hh int) returns numeric
language plpgsql stable set search_path = public, pg_temp as $fn$
declare v record; tot numeric; h1 numeric;
begin
  select * into v from var_bloque_ventana(d, turno);
  if v.ini_hh is null or cambio_hh is null then return null; end if;
  tot := (v.fin_hh - v.ini_hh) - 1;                                                   -- medias horas efectivas (sin el descanso)
  h1 := (cambio_hh - v.ini_hh) - case when cambio_hh > v.brk_hh then 1 else 0 end;    -- medias horas efectivas antes del cambio
  if h1 < 2 or tot - h1 < 2 then return null; end if;
  return round(h1 / tot, 4);
end $fn$;
revoke all on function public.var_bloque_frac(date, char, int) from public, anon, authenticated;

-- Asignar: ahora con segundo cargo opcional (p_estado2) desde la hora de cambio (p_cambio_hh).
drop function if exists public.var_asignar(date, text, char, text, uuid, uuid, boolean);
create or replace function public.var_asignar(p_fecha date, p_agent_id text, p_turno char, p_estado text, p_lider uuid, p_actor uuid,
                                              p_es_na boolean default false, p_estado2 text default null, p_cambio_hh int default null)
returns bigint language plpgsql set search_path = public, pg_temp as $fn$
declare prev record; prev2 record; hay1 boolean; hay2 boolean; nid bigint; est text := p_estado; lid uuid := p_lider; f numeric := 1; cambio int := null;
begin
  if p_fecha > var_hoy_col() then raise exception 'No se puede asignar una fecha futura (%)', p_fecha using errcode = 'P0002'; end if;
  if not exists (select 1 from var_agente a where a.agent_id = p_agent_id and a.activo) then raise exception 'El agente % no está en el roster activo', p_agent_id using errcode = 'P0003'; end if;
  if not exists (select 1 from var_usuarios u where u.auth_uid = p_lider and u.activo) then raise exception 'Líder inválido' using errcode = 'P0004'; end if;
  if p_es_na then select cargo_permanente into est from var_agente where agent_id = p_agent_id; end if;
  if p_estado2 is not null then
    if est in ('ausencia','incapacidad','vacaciones') or p_estado2 in ('ausencia','incapacidad','vacaciones') then
      raise exception 'Un día de ausencia, incapacidad o vacaciones no admite segundo cargo' using errcode = 'P0041'; end if;
    if p_estado2 = est then raise exception 'El segundo cargo debe ser distinto del primero' using errcode = 'P0042'; end if;
    f := var_bloque_frac(p_fecha, p_turno, p_cambio_hh);
    if f is null then raise exception 'La hora de cambio debe quedar dentro de la jornada de llamadas y dejar al menos una hora en cada cargo' using errcode = 'P0043'; end if;
    cambio := p_cambio_hh;
  end if;
  select id, turno, estado, lider_uid, es_na, hasta_hh into prev from var_asignacion where fecha = p_fecha and agent_id = p_agent_id and vigente and bloque = 1;
  hay1 := found;
  select id, turno, estado, lider_uid, desde_hh into prev2 from var_asignacion where fecha = p_fecha and agent_id = p_agent_id and vigente and bloque = 2;
  hay2 := found;
  if hay1 and p_lider = p_actor and exists (select 1 from var_usuarios u where u.auth_uid = p_actor and u.rol = 'admin') then lid := prev.lider_uid; end if;
  if hay1 and prev.turno = p_turno and prev.estado = est and prev.lider_uid = lid and prev.es_na = p_es_na
     and prev.hasta_hh is not distinct from cambio and hay2 = (p_estado2 is not null)
     and (not hay2 or (prev2.estado = p_estado2 and prev2.turno = p_turno and prev2.lider_uid = lid and prev2.desde_hh = cambio)) then
    return prev.id;
  end if;
  update var_asignacion set vigente = false where fecha = p_fecha and agent_id = p_agent_id and vigente;
  insert into var_asignacion (fecha, agent_id, turno, estado, lider_uid, vigente, reemplaza_id, creado_por, es_na, bloque, hasta_hh, frac)
    values (p_fecha, p_agent_id, p_turno, est, lid, true, prev.id, p_actor, p_es_na, 1, cambio, f) returning id into nid;
  if p_estado2 is not null then
    insert into var_asignacion (fecha, agent_id, turno, estado, lider_uid, vigente, reemplaza_id, creado_por, es_na, bloque, desde_hh, frac)
      values (p_fecha, p_agent_id, p_turno, p_estado2, lid, true, prev2.id, p_actor, false, 2, cambio, 1 - f);
  end if;
  return nid;
end $fn$;
revoke all on function public.var_asignar(date, text, char, text, uuid, uuid, boolean, text, int) from public, anon, authenticated;
