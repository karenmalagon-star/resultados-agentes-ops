-- ============================================================================
-- Módulo de Variables · 015 · Varios tipos de error por orden (pedido de Daniel, 8-sep-2026)
--  · var_auditoria_tipo: N tipos por registro. var_auditoria.tipo_id se conserva como "tipo principal" (el primero elegido) para el pop-up.
--  · Una orden con varios errores es UN registro (cuenta 1 en "órdenes con error"); por eso la unicidad pasa a (agente, orden) mientras no esté anulada.
-- ============================================================================
create table if not exists public.var_auditoria_tipo (
  auditoria_id bigint not null references public.var_auditoria(id),
  tipo_id      int    not null references public.var_error_tipo(id),
  primary key (auditoria_id, tipo_id)
);
alter table public.var_auditoria_tipo enable row level security;
insert into public.var_auditoria_tipo (auditoria_id, tipo_id) select id, tipo_id from public.var_auditoria where tipo_id is not null on conflict do nothing;
drop index if exists public.var_auditoria_unica_idx;
create unique index if not exists var_auditoria_unica_idx on public.var_auditoria (agent_id, orden) where anulado_por is null and tipo_id is not null;
