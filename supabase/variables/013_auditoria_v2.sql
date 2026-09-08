-- ============================================================================
-- Módulo de Variables · 013 · Errores de auditoría v2 (input 18) · cargo Agente WhatsApp · personas del equipo
--  · Cargo `agente_whatsapp` (no medible hasta que Daniel pase sus datos) en cargo permanente y cargo del día
--  · var_error_tipo: catálogo de tipos de error con color del semáforo (rojo/amarillo/verde); sembrado con la lista de Daniel
--  · var_auditoria: fecha_auditoria (el error cuenta en el mes de ESTE día), fecha_gestion, pais, celular, tipo_id; producto deja de usarse
--  · var_auditoria_adjunto + bucket privado `auditoria-evidencias`: las evidencias NUNCA se borran ni se modifican (historial legal)
--  · var_tiendas_pais(): países y tiendas salen del historial de gestiones (un país nuevo aparece solo)
--  · var_orden_contacto(): celular/tienda/país de una orden ya traída a Supabase
--  · Personas del equipo: var_personas_historico(), var_persona_agregar(), var_persona_salida(), var_roster(p_fecha)
--  · var_resumen_mes: la auditoría del mes se cuenta por fecha_auditoria; todo lo demás idéntico a 012
-- ============================================================================

-- 1) Cargo Agente WhatsApp
alter table public.var_agente drop constraint if exists var_agente_cargo_permanente_check;
alter table public.var_agente add constraint var_agente_cargo_permanente_check check (cargo_permanente in ('verificacion','v_historica','novedades','agente_whatsapp'));
alter table public.var_asignacion drop constraint if exists var_asignacion_estado_check;
alter table public.var_asignacion add constraint var_asignacion_estado_check check (estado in ('verificacion','v_historica','novedades','agente_whatsapp','apoyo','ausencia','incapacidad'));
alter table public.var_agente add column if not exists es_apoyo boolean not null default false;   -- persona de otra área que viene en apoyo

-- 2) Tipos de error (semáforo)
create table if not exists public.var_error_tipo (
  id          serial primary key,
  nombre      text not null check (length(trim(nombre)) >= 3),
  nombre_norm text not null unique,
  color       text not null check (color in ('rojo','amarillo','verde')),
  activo      boolean not null default true,
  orden       int not null default 0,
  creado_por  uuid,
  creado_en   timestamptz not null default now()
);
alter table public.var_error_tipo enable row level security;
create or replace function public.var_error_tipo_norm() returns trigger language plpgsql as $t$
begin new.nombre := trim(new.nombre); new.nombre_norm := var_norm(new.nombre); return new; end $t$;
drop trigger if exists var_error_tipo_norm_tg on public.var_error_tipo;
create trigger var_error_tipo_norm_tg before insert or update on public.var_error_tipo for each row execute function public.var_error_tipo_norm();
insert into public.var_error_tipo (nombre, nombre_norm, color, orden) select t.nombre, var_norm(t.nombre), t.color, t.orden from (values
  ('Pedido de oficina enviado por transportadora incorrecta', 'rojo', 1),
  ('Confirmación de orden a ciudad equivocada', 'rojo', 2),
  ('Confirmación de pedido repetido', 'rojo', 3),
  ('No realiza cambios solicitados por el cliente', 'rojo', 4),
  ('Cancela orden deseada sin justificación válida', 'rojo', 5),
  ('Envía orden previamente cancelada', 'rojo', 6),
  ('Cancela pedido sin recaudo', 'rojo', 7),
  ('La respuesta en la plataforma no responde al motivo de la novedad — Novedades', 'rojo', 8),
  ('Realiza validación incorrecta de conversación en Chateapro — Novedades', 'rojo', 9),
  ('La respuesta NO es diferente a la gestión del intento anterior — Novedades', 'rojo', 10),
  ('Devuelve orden sin recaudo al remitente — Novedades', 'rojo', 11),
  ('Confirma una orden que era una garantía de producto — Verificación', 'rojo', 12),
  ('Sobrepasa el costo de flete acordado con la tienda', 'amarillo', 13),
  ('Supera el % de devolución sin solicitar anticipo', 'amarillo', 14),
  ('Confirma con precio incorrecto', 'amarillo', 15),
  ('Envía pedido que supera el % de devolución', 'amarillo', 16),
  ('No valida el número de intentos realizados en la gestión de cada orden — Novedades', 'amarillo', 17),
  ('No asegura que la dirección de entrega no sea oficina de transportadora diferente a la asignada — Novedades', 'amarillo', 18),
  ('No realiza los intentos de llamada cuando no hay conversación en Chateapro y la causal corresponde a dirección no existente — Novedades', 'amarillo', 19),
  ('Dirección con formato incorrecto', 'verde', 20),
  ('No coloca etiquetas internas de cancelación', 'verde', 21),
  ('Omite nota interna sin costo directo', 'verde', 22),
  ('Incumple parámetro menor sin generar reintegro ni cancelación', 'verde', 23),
  ('Usa plantilla de mensaje incorrecta sin afectar la confirmación', 'verde', 24),
  ('No hace uso correcto de las plantillas — Novedades', 'verde', 25),
  ('La gestión de la novedad no es clara para complementar futuros intentos — Novedades', 'verde', 26),
  ('No valida duplicado de producto por tienda, proveedor o guía diferente — Novedades', 'verde', 27)
) as t(nombre, color, orden)
where not exists (select 1 from public.var_error_tipo x where x.nombre_norm = var_norm(t.nombre));

-- 3) var_auditoria: campos nuevos
alter table public.var_auditoria
  add column if not exists fecha_auditoria date not null default var_hoy_col(),
  add column if not exists fecha_gestion   date,
  add column if not exists pais            text,
  add column if not exists celular         text,
  add column if not exists tipo_id         int references public.var_error_tipo(id);
create index if not exists var_auditoria_fecha_aud_idx on public.var_auditoria (fecha_auditoria desc);

-- 4) Evidencias: tabla inmutable + bucket privado
create table if not exists public.var_auditoria_adjunto (
  id            bigserial primary key,
  auditoria_id  bigint not null references public.var_auditoria(id),
  ruta          text not null unique,          -- ruta dentro del bucket auditoria-evidencias
  nombre        text not null,
  mime          text,
  bytes         bigint,
  subido_por    uuid not null,
  creado_en     timestamptz not null default now()
);
alter table public.var_auditoria_adjunto enable row level security;
create index if not exists var_auditoria_adjunto_aud_idx on public.var_auditoria_adjunto (auditoria_id);
create or replace function public.var_adjunto_inmutable() returns trigger language plpgsql as $t$
begin raise exception 'Las evidencias de auditoría no se modifican ni se borran (historial legal)' using errcode = 'P0020'; end $t$;
drop trigger if exists var_auditoria_adjunto_inmutable on public.var_auditoria_adjunto;
create trigger var_auditoria_adjunto_inmutable before update or delete on public.var_auditoria_adjunto for each row execute function public.var_adjunto_inmutable();
insert into storage.buckets (id, name, public, file_size_limit)
  values ('auditoria-evidencias', 'auditoria-evidencias', false, 10485760)
  on conflict (id) do update set public = false, file_size_limit = 10485760;

-- 5) Países/tiendas y contacto de la orden
create or replace function public.var_tiendas_pais() returns jsonb language sql stable set search_path = public, pg_temp as $$
  select coalesce(jsonb_object_agg(y.country, y.tiendas order by y.country), '{}'::jsonb)
  from (select x.country, jsonb_agg(x.store order by x.store) tiendas
        from (select distinct e.country, e.store from events_history e where e.country is not null and e.store is not null and e.store <> '(sin tienda)') x
        group by x.country) y;
$$;
create or replace function public.var_orden_contacto(p_orden text) returns jsonb language plpgsql stable set search_path = public, pg_temp as $fn$
declare o bigint; cel text; ti text; pa text;
begin
  if p_orden is null or p_orden !~ '^\d{1,15}$' then return jsonb_build_object('celular', null, 'tienda', null, 'pais', null, 'encontrada', false); end if;
  o := p_orden::bigint;
  select nullif(regexp_replace(c.phone, '\D', '', 'g'), '') into cel from orders_contact c where c.order_id = o;
  select e.store, e.country into ti, pa from (select store, country from events_history where order_id = o order by ev_date desc limit 1) e;
  if ti is null then select c.store into ti from orders_contact c where c.order_id = o; end if;
  return jsonb_build_object('celular', cel, 'tienda', ti, 'pais', pa, 'encontrada', cel is not null);
end $fn$;

-- 6) Personas del equipo
create or replace function public.var_roster(p_fecha date default null) returns jsonb language sql stable set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object('agent_id', g.agent_id, 'nombre', g.nombre, 'cargo_permanente', g.cargo_permanente, 'es_apoyo', g.es_apoyo, 'desde', g.desde, 'hasta', g.hasta) order by g.nombre), '[]'::jsonb)
  from var_agente g
  where g.activo and (p_fecha is null or ((g.desde is null or g.desde <= p_fecha) and (g.hasta is null or g.hasta >= p_fecha)));
$$;
create or replace function public.var_personas_historico() returns jsonb language sql stable set search_path = public, pg_temp as $$
  -- nombres que Refresh ha traído (agent_map) o que aparecen en las gestiones, menos los ya enlazados a alguien del equipo
  with n as (
    select m.name as nombre, m.id as agent_id, 1 as pri from agent_map m where m.name is not null
    union all
    select distinct e.agent, null, 2 from events_history e where e.agent is not null and not var_es_excluido(e.agent)
  ), d as (select distinct on (var_norm(nombre)) var_norm(nombre) norm, nombre, agent_id from n order by var_norm(nombre), pri, nombre)
  select coalesce(jsonb_agg(jsonb_build_object('nombre', d.nombre, 'agent_id', d.agent_id) order by d.nombre), '[]'::jsonb)
  from d where length(d.norm) >= 3 and not exists (select 1 from var_agente_alias al where al.nombre_norm = d.norm);
$$;
create or replace function public.var_persona_agregar(p_nombre text, p_cargo text, p_desde date, p_apoyo boolean, p_actor uuid) returns text
language plpgsql set search_path = public, pg_temp as $fn$
declare norm text := var_norm(coalesce(p_nombre, '')); vid text; cargo text := coalesce(p_cargo, 'verificacion'); existente record;
begin
  if length(norm) < 3 then raise exception 'Escribe el nombre completo' using errcode = 'P0021'; end if;
  if cargo not in ('verificacion','v_historica','novedades','agente_whatsapp') then raise exception 'Cargo permanente inválido' using errcode = 'P0021'; end if;
  if p_apoyo then cargo := 'verificacion'; end if;                          -- apoyo: no tiene cargo del equipo; el líder le pone cargo del día "Apoyo"
  select g.* into existente from var_agente g join var_agente_alias al on al.agent_id = g.agent_id where al.nombre_norm = norm limit 1;
  if found then
    if existente.activo then raise exception 'Esa persona ya está en el equipo' using errcode = 'P0022'; end if;
    update var_agente set activo = true, hasta = null, desde = coalesce(p_desde, desde), cargo_permanente = cargo, es_apoyo = coalesce(p_apoyo, false) where agent_id = existente.agent_id;
    return existente.agent_id;                                               -- vuelve alguien que había salido: mismo id, mismo historial
  end if;
  select m.id into vid from agent_map m where var_norm(m.name) = norm limit 1;
  if vid is null then vid := 'manual:' || substr(md5(norm), 1, 12); end if;  -- aún no existe en Refresh: se enlaza solo cuando aparezca con este nombre
  insert into var_agente (agent_id, nombre, activo, desde, cargo_permanente, es_apoyo, creado_por)
    values (vid, trim(p_nombre), true, p_desde, cargo, coalesce(p_apoyo, false), p_actor)
    on conflict (agent_id) do update set nombre = excluded.nombre, activo = true, hasta = null, desde = excluded.desde, cargo_permanente = excluded.cargo_permanente, es_apoyo = excluded.es_apoyo;
  insert into var_agente_alias (agent_id, nombre_norm, creado_por) values (vid, norm, p_actor) on conflict do nothing;
  return vid;
end $fn$;
create or replace function public.var_persona_salida(p_agent_id text, p_hasta date, p_actor uuid) returns void
language plpgsql set search_path = public, pg_temp as $fn$
begin
  if p_hasta is null then raise exception 'Falta la fecha de salida' using errcode = 'P0021'; end if;
  update var_agente set hasta = p_hasta, activo = (p_hasta >= var_hoy_col()) where agent_id = p_agent_id;   -- si la salida es futura sigue activo hasta ese día (var_roster filtra por fecha)
  if not found then raise exception 'Persona no encontrada' using errcode = 'P0021'; end if;
end $fn$;
revoke all on function public.var_tiendas_pais(), public.var_orden_contacto(text), public.var_roster(date), public.var_personas_historico(),
  public.var_persona_agregar(text, text, date, boolean, uuid), public.var_persona_salida(text, date, uuid) from public, anon, authenticated;

-- 7) var_resumen_mes: auditoría del mes por fecha_auditoria (lo demás idéntico a 012)
create or replace function public.var_resumen_mes(p_mes date, p_dia date default null, p_desde date default null, p_hasta date default null) returns jsonb
language plpgsql stable set search_path = public, pg_temp as $fn$
declare
  cfg jsonb := var_config_vigente(p_mes); hoy date := var_hoy_col(); ahora timestamp := var_ahora_col();
  d_fin date := least(coalesce(p_hasta, (p_mes + interval '1 month' - interval '1 day')::date), (p_mes + interval '1 month' - interval '1 day')::date, hoy);
  d_ini date := greatest(coalesce(p_desde, p_mes), p_mes);     -- rango opcional dentro del mes (filtro de fechas del Resumen)
  fin_mes date := least((p_mes + interval '1 month' - interval '1 day')::date, hoy);
  dia date := coalesce(p_dia, fin_mes);                         -- la tabla del DÍA no depende del rango filtrado de la tabla mensual
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
    where e.ev_date between d_ini and d_fin and not var_es_excluido(e.agent)),
  sin_alias as (select nombre, count(*)::int gest from ev where agent_id is null group by nombre),
  dd as (select agent_id, ev_date as fecha, count(*)::int gest, count(*) filter (where type = 0)::int conf, count(*) filter (where type = 1)::int canc, count(*) filter (where type = 2)::int reprog, min(halfhour)::int primera_hh from ev where agent_id is not null group by 1, 2),
  asg as (select fecha, agent_id, turno, estado, lider_uid, es_na from var_asignacion where vigente and fecha between d_ini and d_fin),
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
  -- el día p_dia por agente: con sus propios eventos y asignaciones (independientes del rango d_ini..d_fin)
  ev_d as (select e.ev_date, e.type, e.halfhour, a.agent_id from events_history e
    left join lateral (select al.agent_id from var_agente_alias al where al.nombre_norm = var_norm(e.agent) and e.ev_date >= al.desde and (al.hasta is null or e.ev_date <= al.hasta) order by al.desde desc limit 1) a on true
    where e.ev_date = dia and not var_es_excluido(e.agent) and a.agent_id is not null),
  dd_d as (select agent_id, ev_date as fecha, count(*)::int gest, count(*) filter (where type = 0)::int conf, count(*) filter (where type = 1)::int canc, count(*) filter (where type = 2)::int reprog, min(halfhour)::int primera_hh from ev_d group by 1, 2),
  asg_d as (select fecha, agent_id, turno, estado from var_asignacion where vigente and fecha = dia),
  ad_d as (select coalesce(d.agent_id, s.agent_id) agent_id, coalesce(d.fecha, s.fecha) fecha, coalesce(d.gest,0) gest, coalesce(d.conf,0) conf, coalesce(d.canc,0) canc, coalesce(d.reprog,0) reprog, d.primera_hh, s.turno, s.estado,
           case when s.turno is null then 0 else var_horas_efectivas(coalesce(d.fecha, s.fecha), s.turno, cfg) end as horas, (extract(isodow from coalesce(d.fecha, s.fecha)) = 7) as domingo
    from dd_d d full join asg_d s on s.fecha = d.fecha and s.agent_id = d.agent_id),
  dx as (select a.*, m.meta_ef, m.meta_ca, m.w_ef, m.w_ca, m.medible,
      case when a.gest > 0 then round((a.conf + a.canc) * 100::numeric / a.gest, 1) end as ef_real,
      case when a.gest > 0 and m.meta_ef > 0 then least(150.0, round((a.conf + a.canc) * 10000::numeric / (a.gest * m.meta_ef), 1)) end as ef_cumpl,
      case when a.conf + a.canc > 0 then round(a.canc * 100::numeric / (a.conf + a.canc), 1) end as ca_real,
      case when a.conf + a.canc = 0 then null when a.canc = 0 then 150.0 when m.meta_ca > 0 then least(150.0, round(m.meta_ca * (a.conf + a.canc)::numeric / a.canc, 1)) end as ca_cumpl,
      case when a.fecha = hoy then var_ritmo_vivo(a.fecha, a.turno, a.primera_hh, a.gest, ahora, cfg)
           when a.horas > 0 and not a.domingo then round(a.gest::numeric / a.horas, 1) end as ritmo
    from ad_d a left join metas m on m.cargo = a.estado),
  dxg as (select *, (ritmo is not null and ritmo >= comp) as compuerta,
      case when medible and (ef_cumpl is not null or ca_cumpl is not null) then
        round((coalesce(case when ritmo is not null and ritmo >= comp then ef_cumpl else 0 end * w_ef, 0) + coalesce(ca_cumpl * w_ca, 0))
              / nullif(coalesce(case when ef_cumpl is not null then w_ef end,0) + coalesce(case when ca_cumpl is not null then w_ca end,0), 0), 1) end as general
    from dx),
  -- auditoría por porcentaje (mes)
  audt as (select t.agent_id, t.total from var_auditadas t where t.mes = p_mes and t.vigente),
  aude as (select e.agent_id, count(*)::int errores from var_auditoria e where e.anulado_por is null and e.fecha_auditoria between p_mes and (p_mes + interval '1 month' - interval '1 day')::date group by 1),   -- el error cuenta en el mes del DÍA DE AUDITORÍA (input 18, decisión 1)
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
  -- consolidado del DÍA por turno (cargos medibles): la fila del líder en la tabla de Hoy / Día. Misma regla que el consolidado del mes:
  --  cumplimientos ponderados por gestiones, ritmo = gestiones ÷ horas (hoy: horas transcurridas, igual que el ritmo vivo de cada agente).
  con_d_a as (select a.turno, a.estado as cargo, a.gest, a.conf, a.canc,
      case when a.domingo then null when a.fecha = hoy then var_horas_vivas(a.fecha, a.turno, a.primera_hh, ahora, cfg) else a.horas end as horas_r
    from ad_d a where a.turno is not null and coalesce((cfg->'cargos'->a.estado->>'medible')::boolean, false)),
  con_d_c as (select turno, cargo, sum(gest)::int gest, sum(conf)::int conf, sum(canc)::int canc,
      sum(case when horas_r is null then 0 else gest end)::int gest_ritmo, sum(horas_r)::numeric horas from con_d_a group by 1, 2),
  con_d_cx as (select c.*, m.meta_ef, m.meta_ca, m.w_ef, m.w_ca,
      case when c.gest > 0 and m.meta_ef > 0 then least(150.0, (c.conf + c.canc) * 10000::numeric / (c.gest * m.meta_ef)) end as ef_cumpl,
      case when c.conf + c.canc = 0 then null when c.canc = 0 then 150.0 when m.meta_ca > 0 then least(150.0, m.meta_ca * (c.conf + c.canc)::numeric / c.canc) end as ca_cumpl
    from con_d_c c left join metas m on m.cargo = c.cargo),
  con_d as (select turno, sum(gest)::int gest, sum(conf)::int conf, sum(canc)::int canc,
      case when sum(gest) > 0 then round(sum(conf + canc) * 100::numeric / sum(gest), 1) end ef_real,
      case when sum(conf + canc) > 0 then round(sum(canc) * 100::numeric / sum(conf + canc), 1) end ca_real,
      round(sum(gest * ef_cumpl) filter (where ef_cumpl is not null) / nullif(sum(gest) filter (where ef_cumpl is not null), 0), 1) ef_cumpl,
      round(sum(gest * ca_cumpl) filter (where ca_cumpl is not null) / nullif(sum(gest) filter (where ca_cumpl is not null), 0), 1) ca_cumpl,
      case when sum(horas) > 0 then round(sum(gest_ritmo)::numeric / sum(horas), 1) end ritmo,
      max(w_ef) w_ef, max(w_ca) w_ca
    from con_d_cx group by turno),
  lid as (select ls.turno, u.nombre, u.etiqueta from var_lider_semana ls join var_usuarios u on u.auth_uid = ls.lider_uid where ls.semana = v_semana),
  hoyasg as (select distinct on (agent_id) agent_id, estado, turno, fecha, es_na from var_asignacion where vigente and fecha between p_mes and dia order by agent_id, fecha desc),
  agentes as (select g.agent_id, g.nombre, g.cargo_permanente from var_agente g where g.activo or exists (select 1 from ad where ad.agent_id = g.agent_id) or exists (select 1 from ad_d where ad_d.agent_id = g.agent_id))
  select jsonb_build_object(
    'mes', to_char(p_mes, 'YYYY-MM'), 'hoy', hoy, 'desde', d_ini, 'hasta', d_fin, 'dia', dia, 'estado', var_estado_mes(p_mes), 'config_version', cfg->'_version',
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
    'consolidado_dia', coalesce((select jsonb_object_agg(c.turno, jsonb_build_object('gest', c.gest, 'conf', c.conf, 'canc', c.canc, 'efectividad_real', c.ef_real, 'efectividad_cumpl', c.ef_cumpl,
        'cancelacion_real', c.ca_real, 'cancelacion_cumpl', c.ca_cumpl, 'ritmo', c.ritmo, 'compuerta', case when c.ritmo is null then null else c.ritmo >= comp end,
        'general', case when c.ef_cumpl is not null or c.ca_cumpl is not null then round((coalesce(case when c.ritmo >= comp then c.ef_cumpl else 0 end * c.w_ef,0) + coalesce(c.ca_cumpl * c.w_ca,0)) / nullif(coalesce(case when c.ef_cumpl is not null then c.w_ef end,0) + coalesce(case when c.ca_cumpl is not null then c.w_ca end,0),0), 1) end,
        'lider', (select jsonb_build_object('nombre', l.nombre, 'etiqueta', l.etiqueta) from lid l where l.turno = c.turno))) from con_d c), '{}'::jsonb),
    'sin_asignar', coalesce((select jsonb_agg(jsonb_build_object('agent_id', d.agent_id, 'fecha', d.fecha, 'gest', d.gest, 'estado', d.estado) order by d.fecha, d.agent_id) from ad d where d.gest > 0 and (d.estado is null or d.estado in ('ausencia','incapacidad'))), '[]'::jsonb),
    'sin_alias', coalesce((select jsonb_agg(jsonb_build_object('nombre', s.nombre, 'gest', s.gest) order by s.gest desc, s.nombre) from sin_alias s), '[]'::jsonb),
    'asignaciones_hoy', (select count(*) from var_asignacion where vigente and fecha = hoy)
  ) into res;
  return res;
end $fn$;

