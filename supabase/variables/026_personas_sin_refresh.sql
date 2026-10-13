-- ============================================================================
-- Módulo de Variables · 026 · Personas que no están en Refresh (input 32, 13-oct-2026)
--  El primer cargo de la escalera es Agente de Novedades: trabaja en la app de Novedades (SGN), no en Refresh.
--  · var_nov_sin_enlazar: usuarios activos de la app de Novedades que aún no están enlazados a nadie del equipo (para el alta).
--  · var_persona_agregar(..., p_correo): el alta puede traer el correo de la app de Novedades y enlaza de una vez.
--  · var_persona_cruzar: cuando la persona asciende y empieza a gestionar en Refresh, se le cruza el nombre con el que
--    Refresh la trae (alias); su id y su historial no cambian.
--  · var_roster: expone 'refresh' (ya está cruzada con Refresh) y 'cruces' (nombres de Refresh cruzados; puede haber varios:
--    nombre distinto en Refresh o persona duplicada en Refresh) para la columna de Personas del equipo.
-- ============================================================================
create or replace function public.var_nov_sin_enlazar() returns jsonb language sql stable set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object('nombre', p.full_name, 'correo', p.email, 'rol', p.role) order by p.full_name), '[]'::jsonb)
  from nov_profiles p
  where p.agent_id is null and p.active and coalesce(p.role, 'agente') = 'agente' and p.email is not null
    and not exists (select 1 from var_agente a where a.correo is not null and lower(a.correo) = lower(p.email));
$$;
revoke all on function public.var_nov_sin_enlazar() from public, anon, authenticated;

drop function if exists public.var_persona_agregar(text, text, date, boolean, uuid, boolean);
create or replace function public.var_persona_agregar(p_nombre text, p_cargo text, p_desde date, p_apoyo boolean, p_actor uuid, p_es_admin boolean default false, p_correo text default null) returns text
language plpgsql set search_path = public, pg_temp as $fn$
declare norm text := var_norm(coalesce(p_nombre, '')); vid text; cargo text := coalesce(p_cargo, 'verificacion'); existente record; v_correo text := nullif(lower(trim(coalesce(p_correo, ''))), '');
begin
  if length(norm) < 3 then raise exception 'Escribe el nombre completo' using errcode = 'P0021'; end if;
  if cargo not in ('verificacion','v_historica','novedades','agente_whatsapp') then raise exception 'Cargo permanente inválido' using errcode = 'P0021'; end if;
  if p_apoyo then cargo := 'verificacion'; end if;
  if v_correo is not null and exists (select 1 from var_agente a where lower(a.correo) = v_correo and var_norm(a.nombre) <> norm) then
    raise exception 'Ese correo ya está asignado a otra persona del equipo' using errcode = 'P0023';
  end if;
  select g.* into existente from var_agente g join var_agente_alias al on al.agent_id = g.agent_id where al.nombre_norm = norm limit 1;
  if found then
    if existente.activo and (existente.hasta is null or existente.hasta >= var_hoy_col()) then raise exception 'Esa persona ya está en el equipo' using errcode = 'P0022'; end if;
    update var_agente set activo = true, hasta = null, desde = coalesce(p_desde, desde),
      cargo_permanente = case when p_es_admin then cargo else cargo_permanente end,
      es_apoyo = case when p_es_admin then coalesce(p_apoyo, false) else es_apoyo end,
      correo = coalesce(v_correo, var_agente.correo)
      where agent_id = existente.agent_id;
    perform var_nov_puente();
    return existente.agent_id;
  end if;
  select m.id into vid from agent_map m where var_norm(m.name) = norm limit 1;
  if vid is null then vid := 'manual:' || substr(md5(norm), 1, 12); end if;   -- no está en Refresh: se cruza después con var_persona_cruzar (o solo, si aparece con este nombre exacto)
  insert into var_agente (agent_id, nombre, activo, desde, cargo_permanente, es_apoyo, correo, creado_por)
    values (vid, trim(p_nombre), true, p_desde, cargo, coalesce(p_apoyo, false), v_correo, p_actor)
    on conflict (agent_id) do update set nombre = excluded.nombre, activo = true, hasta = null, desde = excluded.desde, cargo_permanente = excluded.cargo_permanente, es_apoyo = excluded.es_apoyo, correo = coalesce(excluded.correo, var_agente.correo);
  insert into var_agente_alias (agent_id, nombre_norm, creado_por) values (vid, norm, p_actor) on conflict do nothing;
  perform var_nov_puente();
  return vid;
end $fn$;
revoke all on function public.var_persona_agregar(text, text, date, boolean, uuid, boolean, text) from public, anon, authenticated;

create or replace function public.var_persona_cruzar(p_agent_id text, p_nombre_refresh text, p_actor uuid) returns jsonb
language plpgsql set search_path = public, pg_temp as $fn$
declare norm text := var_norm(coalesce(p_nombre_refresh, '')); otro record; n_ev int;
begin
  if length(norm) < 3 then raise exception 'Escribe el nombre tal como lo trae Refresh' using errcode = 'P0021'; end if;
  if not exists (select 1 from var_agente g where g.agent_id = p_agent_id) then raise exception 'Persona no encontrada' using errcode = 'P0021'; end if;
  if not exists (select 1 from agent_map m where var_norm(m.name) = norm) and not exists (select 1 from events_history e where var_norm(e.agent) = norm) then
    raise exception 'Ese nombre no aparece en Refresh todavía: elige uno de la lista' using errcode = 'P0024';
  end if;
  select g.agent_id, g.nombre into otro from var_agente_alias al join var_agente g on g.agent_id = al.agent_id where al.nombre_norm = norm and al.agent_id <> p_agent_id limit 1;
  if found then raise exception 'Ese nombre de Refresh ya está cruzado con %', otro.nombre using errcode = 'P0025'; end if;
  insert into var_agente_alias (agent_id, nombre_norm, creado_por) values (p_agent_id, norm, p_actor) on conflict do nothing;
  select count(*) into n_ev from events_history e where var_norm(e.agent) = norm;
  return jsonb_build_object('ok', true, 'nombre_norm', norm, 'gestiones_historicas', n_ev);
end $fn$;
revoke all on function public.var_persona_cruzar(text, text, uuid) from public, anon, authenticated;

create or replace function public.var_roster(p_fecha date default null, p_incluir_salidos boolean default false) returns jsonb language sql stable set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object('agent_id', g.agent_id, 'nombre', g.nombre, 'cargo_permanente', g.cargo_permanente, 'es_apoyo', g.es_apoyo, 'desde', g.desde, 'hasta', g.hasta,
                                                'salio', (g.hasta is not null and g.hasta < var_hoy_col()), 'correo', g.correo,
                                                'sgn', exists (select 1 from nov_profiles p where p.agent_id = g.agent_id),
                                                'refresh', (g.agent_id not like 'manual:%' or exists (select 1 from var_agente_alias al join agent_map m on var_norm(m.name) = al.nombre_norm where al.agent_id = g.agent_id)),
                                                'cruces', (select coalesce(jsonb_agg(distinct m.name), '[]'::jsonb) from var_agente_alias al join agent_map m on var_norm(m.name) = al.nombre_norm where al.agent_id = g.agent_id and (al.hasta is null or al.hasta >= var_hoy_col()))) order by g.nombre), '[]'::jsonb)
  from var_agente g
  where g.activo
    and case when p_fecha is not null then (g.desde is null or g.desde <= p_fecha) and (g.hasta is null or g.hasta >= p_fecha)
             when p_incluir_salidos then true
             else (g.hasta is null or g.hasta >= var_hoy_col()) end;
$$;
revoke all on function public.var_roster(date, boolean) from public, anon, authenticated;
