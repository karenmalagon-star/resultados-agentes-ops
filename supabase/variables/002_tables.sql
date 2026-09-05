-- ============================================================================
-- Módulo de Variables · 002 · Tablas (DISENO_TECNICO_VARIABLES.md §4)
-- Prefijo var_. RLS activado y SIN políticas: solo la Edge Function `variables`
-- (service_role) lee y escribe. Nada se borra: correcciones = fila nueva +
-- anterior con vigente=false. Idempotente.
-- ============================================================================

-- Roles: única fuente de verdad del rol de cada persona (nunca el token).
create table if not exists public.var_usuarios (
  auth_uid          uuid primary key,                       -- = auth.users.id
  email             text not null unique,
  nombre            text not null,
  rol               text not null check (rol in ('admin','auditoria','equipo')),
  activo            boolean not null default true,
  fecha_ingreso     date,                                   -- líder: "días que debía liderar" cuentan desde aquí
  puede_configurar  boolean not null default false,         -- L6: solo Karen
  creado_por        uuid,
  creado_en         timestamptz not null default now()
);

-- Roster del equipo (agent_map mezcla históricos y pseudo-agentes; esto es la lista oficial).
create table if not exists public.var_agente (
  agent_id    text primary key,                             -- id de Refresh (agent_map.id)
  nombre      text not null,
  activo      boolean not null default true,
  desde       date,
  hasta       date,
  creado_por  uuid,
  creado_en   timestamptz not null default now()
);

-- Alias: nombres con los que el agente aparece en events_history (que guarda NOMBRE, no id).
create table if not exists public.var_agente_alias (
  id          bigserial primary key,
  agent_id    text not null references public.var_agente(agent_id),
  nombre_norm text not null,                                -- var_norm(nombre)
  desde       date not null default '2026-07-24',
  hasta       date,
  creado_por  uuid,
  creado_en   timestamptz not null default now(),
  unique (nombre_norm, desde)
);

-- Reglamento del mes (spec §2, diseño §4.1). Libre antes del día 1; después solo admin con motivo → versión nueva.
create table if not exists public.var_config_mes (
  mes         date not null check (extract(day from mes) = 1),
  version     integer not null default 1,
  config      jsonb not null,
  motivo      text,
  creado_por  uuid,
  creado_en   timestamptz not null default now(),
  primary key (mes, version)
);

-- Asignación del día: cargo y turno por agente, firmada por el líder (spec §4.2, K5: una vigente por agente-día).
create table if not exists public.var_asignacion (
  id           bigserial primary key,
  fecha        date not null,
  agent_id     text not null references public.var_agente(agent_id),
  turno        char(1) not null check (turno in ('M','T')),
  estado       text not null check (estado in ('verificacion','v_historica','novedades','apoyo','ausencia','incapacidad')),
  lider_uid    uuid not null references public.var_usuarios(auth_uid),
  vigente      boolean not null default true,
  reemplaza_id bigint references public.var_asignacion(id),
  creado_por   uuid not null,
  creado_en    timestamptz not null default now()
);
create unique index if not exists var_asignacion_vigente_uq on public.var_asignacion (fecha, agent_id) where vigente;
create index if not exists var_asignacion_fecha_idx on public.var_asignacion (fecha) where vigente;

-- Ausencias, incapacidades y descansos del líder (spec §3.7). Solo admin.
create table if not exists public.var_lider_dia (
  lider_uid      uuid not null references public.var_usuarios(auth_uid),
  fecha          date not null,
  tipo           text not null check (tipo in ('ausencia','incapacidad','descanso')),
  registrado_por uuid not null,
  creado_en      timestamptz not null default now(),
  primary key (lider_uid, fecha)
);

-- Errores de auditoría (spec §4.3). Disparan el pop-up. Nunca se borran: se anulan con motivo.
create table if not exists public.var_auditoria (
  id              bigserial primary key,
  momento         timestamptz not null default now(),
  agent_id        text not null references public.var_agente(agent_id),
  tienda          text,
  producto        text,
  descripcion     text not null check (length(trim(descripcion)) >= 3),
  registrado_por  uuid not null,
  anulado_por     uuid,
  anulado_en      timestamptz,
  anulado_motivo  text,
  creado_en       timestamptz not null default now()
);
create index if not exists var_auditoria_momento_idx on public.var_auditoria (momento desc);

-- Entradas manuales de admin (spec §4.4): días tarde (por agente-mes, cargo null),
-- multiplicador de auditoría (0–150), valor real de una variable no medible.
create table if not exists public.var_manual (
  id           bigserial primary key,
  mes          date not null check (extract(day from mes) = 1),
  sujeto_tipo  text not null check (sujeto_tipo in ('agente','lider')),
  sujeto_id    text not null,                               -- agent_id o auth_uid del líder
  cargo        text,                                        -- null = aplica al agente-mes (puntualidad)
  clave        text not null,                               -- 'dias_tarde' | 'multiplicador' | 'real:<variable>'
  valor        numeric not null check (valor >= 0),
  vigente      boolean not null default true,
  reemplaza_id bigint references public.var_manual(id),
  creado_por   uuid not null,
  creado_en    timestamptz not null default now(),
  constraint var_manual_multiplicador_rango check (clave <> 'multiplicador' or (valor between 0 and 150)),
  constraint var_manual_dias_tarde_entero  check (clave <> 'dias_tarde' or valor = trunc(valor))
);
create unique index if not exists var_manual_vigente_uq
  on public.var_manual (mes, sujeto_tipo, sujeto_id, coalesce(cargo,''), clave) where vigente;

-- Estado y foto del mes (spec §3.6). Solo var_liquidar() la pasa a 'liquidado' (Sprint 2).
create table if not exists public.var_liquidacion (
  mes             date primary key check (extract(day from mes) = 1),
  estado          text not null default 'abierto' check (estado in ('abierto','en_revision','liquidado')),
  config_version  integer,
  foto            jsonb,
  liquidado_por   uuid,
  liquidado_en    timestamptz,
  creado_en       timestamptz not null default now()
);

-- Libro de ajustes post-cierre (spec §3.6). Solo con mes liquidado; nunca toca la foto.
create table if not exists public.var_ajuste (
  id              bigserial primary key,
  mes             date not null check (extract(day from mes) = 1),
  sujeto_tipo     text not null check (sujeto_tipo in ('agente','lider')),
  sujeto_id       text not null,
  valor_anterior  numeric,
  valor_nuevo     numeric,
  monto           numeric not null,
  motivo          text not null check (length(trim(motivo)) >= 5),
  creado_por      uuid not null,
  creado_en       timestamptz not null default now()
);

-- RLS en todas, sin políticas (negar por defecto).
alter table public.var_usuarios     enable row level security;
alter table public.var_agente       enable row level security;
alter table public.var_agente_alias enable row level security;
alter table public.var_config_mes   enable row level security;
alter table public.var_asignacion   enable row level security;
alter table public.var_lider_dia    enable row level security;
alter table public.var_auditoria    enable row level security;
alter table public.var_manual       enable row level security;
alter table public.var_liquidacion  enable row level security;
alter table public.var_ajuste       enable row level security;

-- Índice para agregar el mes directo de events_history (sin cache, diseño §4).
create index if not exists events_history_evdate_agent_idx on public.events_history (ev_date, agent);

-- Defensa en profundidad: un mes liquidado no acepta cambios en lo que alimenta su cálculo,
-- ni siquiera si un error del servidor lo intenta.
create or replace function public.var_bloquear_mes_liquidado() returns trigger
language plpgsql set search_path = public, pg_temp as $fn$
declare m date; m_old date;
begin
  if tg_table_name in ('var_asignacion','var_lider_dia') then
    m := date_trunc('month', new.fecha)::date;
    if tg_op = 'UPDATE' then m_old := date_trunc('month', old.fecha)::date; end if;
  else
    m := new.mes;
    if tg_op = 'UPDATE' then m_old := old.mes; end if;
  end if;
  if exists (select 1 from public.var_liquidacion l where l.estado = 'liquidado' and l.mes in (m, m_old)) then
    raise exception 'El mes % está liquidado: no se puede modificar (use el libro de ajustes)', to_char(m,'YYYY-MM')
      using errcode = 'P0001';
  end if;
  return new;
end $fn$;

drop trigger if exists trg_var_asignacion_liq on public.var_asignacion;
create trigger trg_var_asignacion_liq before insert or update on public.var_asignacion
  for each row execute function public.var_bloquear_mes_liquidado();
drop trigger if exists trg_var_lider_dia_liq on public.var_lider_dia;
create trigger trg_var_lider_dia_liq before insert or update on public.var_lider_dia
  for each row execute function public.var_bloquear_mes_liquidado();
drop trigger if exists trg_var_manual_liq on public.var_manual;
create trigger trg_var_manual_liq before insert or update on public.var_manual
  for each row execute function public.var_bloquear_mes_liquidado();
drop trigger if exists trg_var_config_liq on public.var_config_mes;
create trigger trg_var_config_liq before insert or update on public.var_config_mes
  for each row execute function public.var_bloquear_mes_liquidado();
