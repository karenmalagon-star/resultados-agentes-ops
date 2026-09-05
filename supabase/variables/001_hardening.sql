-- ============================================================================
-- Módulo de Variables · 001 · Endurecimiento previo a publicar la página con la
-- anon key (DISENO_TECNICO_VARIABLES.md §3.4). Verificado 2026-09-04: todas las
-- tablas con datos ya tienen RLS activado y sin políticas (anon/authenticated no
-- leen nada). Esto cierra los dos huecos menores y deja el esquema "negar por
-- defecto" también para tablas futuras.
-- Idempotente. No afecta a las Edge Functions (usan service_role).
-- ============================================================================

-- 1) v_tiendas estaba en modo security definer y legible por anónimos (asesor: ERROR).
alter view public.v_tiendas set (security_invoker = true);
revoke all on public.v_tiendas from anon, authenticated;

-- 2) Los permisos por defecto sobre tablas y secuencias estaban concedidos a
--    anon/authenticated (anulados por RLS, pero se revocan: cinturón y tirantes).
revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
alter default privileges in schema public revoke all on tables    from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;

-- 3) Tablas sin RLS (no tenían grants, pero se activa para que el asesor no las marque).
alter table public.agent_presence enable row level security;
alter table public.cron_calls     enable row level security;

-- Nota: resumen_tiendas_gestion() y assets_snapshot() siguen ejecutables por
-- anon (security invoker → RLS los deja sin datos). No se revocan aquí por si
-- algún flujo externo los usa; revisar con Karen.
