-- ============================================================================
-- Módulo de Variables · 027 · El alta solo acepta usuarios existentes (input 33, 16-oct-2026)
--  Como en Refresh, en la app de Novedades también se crean usuarios: la persona se elige de una de las dos listas
--  (usuario de la app de Novedades por correo, o usuario de Refresh por nombre). Ya no se admite un nombre libre.
-- ============================================================================
create or replace function public.var_persona_agregar(p_nombre text, p_cargo text, p_desde date, p_apoyo boolean, p_actor uuid, p_es_admin boolean default false, p_correo text default null) returns text
language plpgsql set search_path = public, pg_temp as $fn$
declare norm text := var_norm(coalesce(p_nombre, '')); vid text; cargo text := coalesce(p_cargo, 'verificacion'); existente record; v_correo text := nullif(lower(trim(coalesce(p_correo, ''))), '');
begin
  if length(norm) < 3 then raise exception 'Elige la persona de la lista' using errcode = 'P0021'; end if;
  if cargo not in ('verificacion','v_historica','novedades','agente_whatsapp') then raise exception 'Cargo permanente inválido' using errcode = 'P0021'; end if;
  if p_apoyo then cargo := 'verificacion'; end if;
  -- Solo usuarios existentes: por correo en la app de Novedades, o por nombre en Refresh (agent_map / gestiones).
  if v_correo is not null then
    if not exists (select 1 from nov_profiles p where lower(p.email) = v_correo and p.active) then
      raise exception 'Ese correo no es de un usuario activo de la app de Novedades' using errcode = 'P0026';
    end if;
    if exists (select 1 from var_agente a where lower(a.correo) = v_correo and var_norm(a.nombre) <> norm) then
      raise exception 'Ese correo ya está asignado a otra persona del equipo' using errcode = 'P0023';
    end if;
  elsif not exists (select 1 from agent_map m where var_norm(m.name) = norm) and not exists (select 1 from events_history e where var_norm(e.agent) = norm) then
    raise exception 'Esa persona no existe como usuario en Refresh ni en la app de Novedades: elígela de la lista' using errcode = 'P0026';
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
  if vid is null then vid := 'manual:' || substr(md5(norm), 1, 12); end if;   -- usuario de la app de Novedades que aún no está en Refresh: se cruza después con var_persona_cruzar
  insert into var_agente (agent_id, nombre, activo, desde, cargo_permanente, es_apoyo, correo, creado_por)
    values (vid, trim(p_nombre), true, p_desde, cargo, coalesce(p_apoyo, false), v_correo, p_actor)
    on conflict (agent_id) do update set nombre = excluded.nombre, activo = true, hasta = null, desde = excluded.desde, cargo_permanente = excluded.cargo_permanente, es_apoyo = excluded.es_apoyo, correo = coalesce(excluded.correo, var_agente.correo);
  insert into var_agente_alias (agent_id, nombre_norm, creado_por) values (vid, norm, p_actor) on conflict do nothing;
  perform var_nov_puente();
  return vid;
end $fn$;
revoke all on function public.var_persona_agregar(text, text, date, boolean, uuid, boolean, text) from public, anon, authenticated;
