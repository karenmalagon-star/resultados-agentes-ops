-- ============================================================================
-- Esquema (indicativo) del proyecto "Resultados Agentes Ops".
-- La base de datos EN VIVO es la fuente de verdad. Este archivo documenta las
-- tablas/objetos clave para poder recrear o entender el proyecto.
-- Extensiones usadas: pg_cron, pg_net, pgcrypto (en schema extensions).
-- ============================================================================

-- Configuracion y secretos (refresh_email, refresh_password, write_key,
-- auth_user, auth_pw_hash, calls_per_hour, ai_share, agentes_actuales, ...)
create table if not exists public.app_config (
  key   text primary key,
  value text
);

-- Plantilla HTML del tablero (fila key='template')
create table if not exists public.assets (
  key        text primary key,
  content    text,
  updated_at timestamptz default now()
);

-- Snapshot mas reciente de Resultados (modelo de eventos ~5 dias)
create table if not exists public.snapshot (
  id         bigint generated always as identity primary key,
  data       jsonb,
  created_at timestamptz default now()
);

-- Datos ya calculados por panel: key in (leader, cohort, cohortH, histD, capacity)
create table if not exists public.panel_data (
  key        text primary key,
  data       jsonb,
  updated_at timestamptz default now()
);

-- Caches de pull (se reemplazan/actualizan en cada corrida)
create table if not exists public.panels_cache (
  id           bigint primary key,
  rec          jsonb,
  created_date date,
  updated_at   timestamptz default now()
);
create table if not exists public.orders_cache (
  id           bigint primary key,
  status       text,
  rec          jsonb,
  created_date date,
  updated_at   timestamptz default now()
);

-- Mapa id -> nombre de agentes
create table if not exists public.agent_map (
  id   text primary key,
  name text
);

-- Historia permanente de eventos (la alimenta events-history-append)
create table if not exists public.events_history (
  order_id bigint,
  type     smallint,
  agent    text,
  store    text,
  country  text,
  ev_date  date,
  halfhour smallint,
  reason   text,
  primary key (order_id, type, ev_date, halfhour)
);

-- Historia permanente del cierre (la alimenta cohort-history-append)
create table if not exists public.cohort_history (
  dc         date primary key,
  general    jsonb,
  by_store   jsonb,
  updated_at timestamptz default now()
);

-- Handoff (entrega de turno)
create table if not exists public.handoff (
  id            bigint generated always as identity primary key,
  created_at    timestamptz not null default now(),
  autor         text not null,
  texto         text not null,
  estado        text not null default 'abierto',
  categoria     text,
  tienda        text,
  orden         text,
  prioridad     text not null default 'Media',
  informativa   boolean not null default false,
  escalado      boolean not null default false,
  escalado_area text,
  resuelto_nota text,
  resuelto_por  text,
  resuelto_at   timestamptz,
  es_radar      boolean not null default false,
  seguimiento   jsonb not null default '[]'::jsonb,
  updated_at    timestamptz not null default now()
);
alter table public.handoff enable row level security;

create table if not exists public.handoff_ack (
  id           bigint generated always as identity primary key,
  at           timestamptz not null default now(),
  recibido_por text not null,
  nota         text
);
alter table public.handoff_ack enable row level security;

-- Vista de tiendas distintas (para el desplegable del Handoff)
create or replace view public.v_tiendas as
select distinct rec->>'st' as tienda from public.panels_cache
where rec->>'st' is not null and rec->>'st' <> '(sin tienda)';

-- Login del dashboard/handoff: valida usuario + bcrypt (pgcrypto)
create or replace function public.check_login(u text, p text)
returns boolean language sql security definer as $fn$
  select exists(
    select 1 from public.app_config cu, public.app_config cp
    where cu.key='auth_user' and cp.key='auth_pw_hash'
      and cu.value = u
      and cp.value = extensions.crypt(p, cp.value)
  );
$fn$;

-- Historial automatico de la plantilla (red de seguridad / rollback) - agregado 2026-08-20
create table if not exists public.assets_history (
  id       bigserial   primary key,
  key      text        not null,
  content  text        not null,
  saved_at timestamptz not null default now(),
  note     text
);
create or replace function public.assets_snapshot()
returns trigger language plpgsql as $fn$
begin
  insert into public.assets_history(key, content, note)
  values (old.key, old.content, 'auto: version previa al update');
  return new;
end $fn$;
drop trigger if exists trg_assets_history on public.assets;
create trigger trg_assets_history
  before update on public.assets
  for each row
  when (old.content is distinct from new.content)
  execute function public.assets_snapshot();
