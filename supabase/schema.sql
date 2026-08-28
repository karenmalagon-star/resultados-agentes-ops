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

-- ============================================================
-- Sistema de alertas (2026-08-26)
-- ============================================================
-- Registro de que funcion dispara cada llamada de cron (las alertas dicen QUE fallo)
create table if not exists public.cron_calls (
  req_id bigint primary key,
  fn     text not null,
  at     timestamptz not null default now()
);
revoke all on public.cron_calls from anon;
revoke all on public.cron_calls from authenticated;

-- monitor_checks(): chequeo de salud. Lo consume la Edge Function monitor-salud.
create or replace function public.monitor_checks()
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  problemas jsonb := '[]'::jsonb;
  v_snap timestamptz;
  v_age numeric;
  r record;
  fallas jsonb;
begin
  select max(created_at) into v_snap from public.snapshot;
  v_age := extract(epoch from now() - v_snap) / 60;
  if v_snap is null or v_age > 75 then
    problemas := problemas || jsonb_build_array(
      'La vista RESULTADOS no se actualiza hace ' || coalesce(round(v_age)::text, '?') ||
      ' minutos (última: ' || coalesce(to_char(v_snap at time zone 'America/Bogota', 'YYYY-MM-DD HH24:MI'), 'nunca') ||
      ' hora Colombia). Falla probable: la función sync-refresh o su tarea programada.');
  end if;
  for r in
    select key, updated_at, extract(epoch from now() - updated_at) / 60 as age_min,
           case key when 'leader' then 150 when 'histD' then 75 when 'cohortH' then 75
                    when 'cohort' then 1560 when 'capacity' then 1560 end as umbral,
           case key when 'leader'  then 'panel LÍDER (función sync-panels)'
                    when 'histD'   then 'historia de RESULTADOS (función build-history)'
                    when 'cohortH' then 'historia de CIERRE (función build-history)'
                    when 'cohort'  then 'vista CIERRE (función sync-cohort)'
                    when 'capacity' then 'CAPACIDAD OPERATIVA (función sync-capacity)' end as nombre
    from public.panel_data
    where key in ('leader', 'histD', 'cohortH', 'cohort', 'capacity')
  loop
    if r.age_min > r.umbral then
      problemas := problemas || jsonb_build_array(
        'El ' || r.nombre || ' no se actualiza hace ' || round(r.age_min) ||
        ' minutos (última: ' || to_char(r.updated_at at time zone 'America/Bogota', 'YYYY-MM-DD HH24:MI') || ' hora Colombia).');
    end if;
  end loop;
  select jsonb_agg(
    'La función «' || coalesce(cc.fn, 'desconocida') || '» falló a las ' ||
    to_char(h.created at time zone 'America/Bogota', 'HH24:MI') ||
    ' (hora Colombia): HTTP ' || coalesce(h.status_code::text, '?') || ' — ' ||
    coalesce(left(h.content::text, 150), coalesce(h.error_msg, 'sin detalle')))
  into fallas
  from net._http_response h
  left join public.cron_calls cc on cc.req_id = h.id
  where h.created > now() - interval '35 minutes'
    and (h.status_code is distinct from 200
         or h.error_msg is not null
         or h.content::text like '%"ok":false%');
  if fallas is not null then problemas := problemas || fallas; end if;
  return problemas;
end $fn$;

revoke execute on function public.monitor_checks() from public;
revoke execute on function public.monitor_checks() from anon;
revoke execute on function public.monitor_checks() from authenticated;
grant execute on function public.monitor_checks() to service_role;

-- Config del sistema de alertas (valores reales solo en la BD, nunca en el repo):
--   alert_webhook_url : URL del webhook de N8N que envia el correo
--   alert_token       : secreto compartido que valida el webhook
--   monitor_state     : estado interno anti-spam del monitor (lo maneja la funcion)

-- ============================================================
-- Presencia de agentes (hallazgo D4, 2026-08-28)
-- Refresh solo expone isOnline instantaneo: un cron cada 5 min acumula muestras.
-- horas estimadas de un dia = muestras * 5 / 60 (precision ±5 min).
-- SOLO recolecta: ninguna metrica lo usa aun (decision pendiente con datos).
-- ============================================================
create table if not exists public.agent_presence (
  dia        date not null,
  agent_id   text not null,
  agent_name text,
  primera    timestamptz not null,
  ultima     timestamptz not null,
  muestras   integer not null default 0,
  primary key (dia, agent_id)
);
revoke all on public.agent_presence from anon;
revoke all on public.agent_presence from authenticated;

create or replace function public.presence_tick(p_agents jsonb)
returns integer
language plpgsql
security definer
set search_path = public
as $fn$
declare
  n int := 0;
  r jsonb;
  v_dia date := (now() at time zone 'America/Bogota')::date;
begin
  for r in select * from jsonb_array_elements(coalesce(p_agents, '[]'::jsonb)) loop
    insert into public.agent_presence (dia, agent_id, agent_name, primera, ultima, muestras)
    values (v_dia, r->>'id', r->>'name', now(), now(), 1)
    on conflict (dia, agent_id) do update
      set ultima = now(), muestras = public.agent_presence.muestras + 1, agent_name = excluded.agent_name;
    n := n + 1;
  end loop;
  return n;
end $fn$;
revoke execute on function public.presence_tick(jsonb) from public;
revoke execute on function public.presence_tick(jsonb) from anon;
revoke execute on function public.presence_tick(jsonb) from authenticated;
grant execute on function public.presence_tick(jsonb) to service_role;
