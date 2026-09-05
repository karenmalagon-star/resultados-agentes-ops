# Módulo de Variables (compensación) — Sprint 1

Reglamento: `~/Documents/fenix-dashboard-ops/ESPECIFICACION_VARIABLES_v1.md` (v1.7). Diseño: `DISENO_TECNICO_VARIABLES.md` (v1.1).

| Archivo | Qué es | Aplicado en producción |
|---|---|---|
| `001_hardening.sql` | endurecimiento previo a publicar la anon key (v_tiendas, revokes, RLS) | 2026-09-05 |
| `002_tables.sql` | tablas `var_*` con RLS sin políticas + triggers de mes liquidado | 2026-09-05 |
| `003_functions.sql` | ayudantes, config, `var_asignar`, `var_ritmo_vivo`, `var_resumen_mes` (porcentajes; sin dinero) | 2026-09-05 |
| `004_search_path.sql` | search_path fijo en las 8 funciones SQL (aviso del asesor) | 2026-09-05 |
| `tests/sprint1_puras.sql` | 23 pruebas de funciones puras (todas en verde el 2026-09-05) | — |
| `../functions/variables/index.ts` | Edge Function: valida el JWT contra Auth, rol desde `var_usuarios`, acciones×rol, proyección por lista blanca | v1, `verify_jwt=false` (validación propia) |
| `../../equipo/index.html` | página única con vistas por rol (`/equipo/`) | se publica al mergear a `main` (GitHub Pages) |

**Sprint 2 (con panel adversarial antes de desplegar):** `var_calcular_mes` (dinero), `var_liquidar`, libro de ajustes, vista Admin de dinero, respaldo `pg_dump` a repo privado, pruebas 1–26 completas.

**Pasos manuales en Supabase → Authentication (Karen/Daniel):** desactivar sign-up · SMTP propio · Site URL y Redirect URL =
`https://karenmalagon-star.github.io/resultados-agentes-ops/equipo/` · invitar personas · en la página, Admin les asigna rol.
El primer admin se crea con una fila directa en `var_usuarios` (SQL), una sola vez.
