-- ============================================================================
-- Módulo de Variables · 016 · Novedades (D-024/D-026): tablas de copia desde SGN, el Broker (estado Dropi) y la IA
--  · Copia SIN datos personales del cliente (no se copian teléfono, nombre, direcciones, comentarios ni payloads).
--  · nov_profiles/nov_novedades/nov_gestiones/nov_eventos/nov_motivos ← Supabase de SGN (cada 10 min, Edge sync-sgn).
--  · nov_orden_estado/nov_orden_estado_hist ← Broker Fenix POST/GET /v1/orders/status (diario, Edge nov-estado-dropi).
--  · nov_ia_gestiones ← Broker GET /v1/ia/gestiones (diario). Solo para el reporte Admin; la IA no se mide.
--  · País siempre en código ISO (CO, CL, MX, EC, GT): var_pais_iso() normaliza lo que llega como nombre.
-- ============================================================================
create or replace function public.var_pais_iso(p text) returns text language sql immutable as $$
  select case upper(trim(coalesce(p,'')))
    when 'COLOMBIA' then 'CO' when 'CHILE' then 'CL' when 'MEXICO' then 'MX' when 'MÉXICO' then 'MX'
    when 'ECUADOR' then 'EC' when 'GUATEMALA' then 'GT' when '' then null
    else upper(trim(p)) end;
$$;

create table if not exists public.nov_profiles (
  id uuid primary key, full_name text, email text, role text, active boolean, meta_diaria int, metas_dia jsonb, fecha_ingreso date,
  agent_id text references public.var_agente(agent_id),          -- puente con el roster de Variables (por correo/nombre; lo fija Admin)
  sincronizado_en timestamptz not null default now()
);
create table if not exists public.nov_novedades (
  order_id text primary key, store_name text, country text, tipo_novedad text, status_interno text, estado_local text, intentos int,
  assigned_to uuid, broker_created_at timestamptz, first_synced_at timestamptz, last_synced_at timestamptz, disappeared_at timestamptz, dropi_review boolean,
  sincronizado_en timestamptz not null default now()
);
create index if not exists nov_novedades_last_sync_idx on public.nov_novedades (last_synced_at);
create table if not exists public.nov_gestiones (
  id uuid primary key, order_id text not null, store_name text, agente_id uuid, accion text, motivo_devolucion text, solucion_dropi text,
  resolved_in_dropi boolean, created_at timestamptz not null, sincronizado_en timestamptz not null default now()
);
create index if not exists nov_gestiones_agente_fecha_idx on public.nov_gestiones (agente_id, created_at);
create index if not exists nov_gestiones_order_idx on public.nov_gestiones (order_id, created_at);
create table if not exists public.nov_eventos (
  id bigint primary key, order_id text not null, evento text, tipo_novedad text, status_interno text, broker_created_at timestamptz, store_name text, country text,
  detectado_en timestamptz, gestion_prev_id uuid, gestion_prev_agente_id uuid, gestion_prev_at timestamptz, gestion_prev_accion text, gestion_prev_resuelta boolean,
  sincronizado_en timestamptz not null default now()
);
create index if not exists nov_eventos_order_idx on public.nov_eventos (order_id, detectado_en);
create table if not exists public.nov_motivos (id int primary key, texto text not null, orden int, activo boolean, sincronizado_en timestamptz not null default now());

create table if not exists public.nov_ia_gestiones (
  order_id text not null, revisado_at timestamptz not null, country text, store_name text, trigger_evento text, decision text, status_interno text,
  resultado_dropi text, tipo_novedad text, ronda_id text, worker_id int, sincronizado_en timestamptz not null default now(),
  primary key (order_id, revisado_at)
);
create index if not exists nov_ia_gestiones_fecha_idx on public.nov_ia_gestiones (revisado_at);

create table if not exists public.nov_orden_estado (
  order_id text not null, country text not null, store_name text, found boolean, status text, created_at_dropi timestamptz,
  checked_at timestamptz, primera_consulta timestamptz not null default now(), final boolean not null default false,
  primary key (order_id, country)
);
create index if not exists nov_orden_estado_final_idx on public.nov_orden_estado (final, checked_at);
create table if not exists public.nov_orden_estado_hist (
  order_id text not null, country text not null, estado text not null, fecha timestamptz not null, visto_en timestamptz not null default now(),
  primary key (order_id, country, estado, fecha)
);
create index if not exists nov_orden_estado_hist_order_idx on public.nov_orden_estado_hist (order_id, fecha);
create table if not exists public.nov_estado_jobs (
  job_id text primary key, country text, n int, creado_en timestamptz not null default now(), status text not null default 'pending', done int default 0,
  ultimo_poll timestamptz, error text, terminado_en timestamptz
);
create table if not exists public.nov_sync_log (id bigserial primary key, fn text not null, inicio timestamptz not null default now(), fin timestamptz, ok boolean, detalle jsonb);

-- Estados finales de Dropi (D-024, input 23): éxito / no exitoso / fuera de la medición
create or replace function public.var_estado_final(p_status text) returns text language sql immutable as $$
  select case upper(trim(coalesce(p_status,'')))
    when 'ENTREGADO' then 'exito' when 'INDEMNIZADA' then 'exito' when 'INDEMNIZADA POR DROPI' then 'exito'
    when 'DEVOLUCION' then 'fracaso'
    when 'DESTRUCCION - SALVAMENTO - DONACION' then 'excluido' when 'SINIESTRO' then 'excluido'
    else null end;   -- null = orden viva
$$;

do $$ declare t text; begin
  foreach t in array array['nov_profiles','nov_novedades','nov_gestiones','nov_eventos','nov_motivos','nov_ia_gestiones','nov_orden_estado','nov_orden_estado_hist','nov_estado_jobs','nov_sync_log'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;
end $$;
revoke all on function public.var_pais_iso(text), public.var_estado_final(text) from public, anon, authenticated;

-- Candidatas para consultar estado en Dropi: gestión aceptada en los últimos p_dias y sin estado final (o nunca consultadas)
create or replace function public.nov_candidatas_estado(p_dias int default 10, p_max int default 3500)
returns table (order_id text, country text, store_name text) language sql stable set search_path = public, pg_temp as $$
  select g.order_id, coalesce(n.country, var_pais_iso(split_part(g.store_name, ' ', -1))) as country, g.store_name
  from (select distinct on (order_id) order_id, store_name, created_at from nov_gestiones where resolved_in_dropi and created_at >= now() - make_interval(days => p_dias) order by order_id, created_at desc) g
  left join nov_novedades n on n.order_id = g.order_id
  left join nov_orden_estado e on e.order_id = g.order_id and e.country = coalesce(n.country, var_pais_iso(split_part(g.store_name, ' ', -1)))
  where coalesce(n.country, var_pais_iso(split_part(g.store_name, ' ', -1))) is not null and (e.order_id is null or not e.final)
  order by g.created_at desc limit p_max;
$$;
revoke all on function public.nov_candidatas_estado(int, int) from public, anon, authenticated;
