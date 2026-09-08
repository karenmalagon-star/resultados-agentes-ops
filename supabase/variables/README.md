# Módulo de Variables (compensación) — Sprint 1

Reglamento: `~/Documents/fenix-dashboard-ops/ESPECIFICACION_VARIABLES_v1.md` (v1.7). Diseño: `DISENO_TECNICO_VARIABLES.md` (v1.1).

| Archivo | Qué es | Aplicado en producción |
|---|---|---|
| `001_hardening.sql` | endurecimiento previo a publicar la anon key (v_tiendas, revokes, RLS) | 2026-09-05 |
| `002_tables.sql` | tablas `var_*` con RLS sin políticas + triggers de mes liquidado | 2026-09-05 |
| `003_functions.sql` | ayudantes, config, `var_asignar`, `var_ritmo_vivo`, `var_resumen_mes` (porcentajes; sin dinero) | 2026-09-05 |
| `004_search_path.sql` | search_path fijo en las 8 funciones SQL (aviso del asesor) | 2026-09-05 |
| `005_maqueta_aprobada.sql` | cargo permanente, N/A, líderes por semana, órdenes auditadas, resumen v2 (Real·Meta·Cumpl., general) | 2026-09-05 |
| `006_dinero.sql` | MOTOR DE DINERO (escalera, consolidado por líder, `var_calcular_mes` estimado para Admin); var_asignar conserva líder; domingos no cuentan como días | 2026-09-07 (revisado adversarialmente: 6 correcciones) |
| `007_ordenes_agente.sql` | tabla permanente `orders_contact` (celular por orden, la llena sync-refresh v9) + `var_ordenes_agente` (el "ojo" del Resumen; celular sin espacios) | 2026-09-07 |
| `008_tiendas_agente.sql` | `var_tiendas_agentes` (enteros por agente × tienda) y `var_ordenes_agente` con filtro de tienda | 2026-09-07 |
| `009_resumen_rango.sql` | `var_resumen_mes(p_mes, p_dia, p_desde, p_hasta)`: filtro de fechas de la tabla mensual; `var_tiendas_agentes` de un solo agente (pop-up) | 2026-09-07 |
| `010_ordenes_cronologico.sql` | el detalle de órdenes sale en orden cronológico (fecha, hora ascendentes) | 2026-09-07 |
| `011_dia_independiente.sql` | corrección de auditoría: la tabla del día no depende del rango filtrado de la tabla mensual; asignaciones_hoy siempre de hoy | 2026-09-07 |
| `012_consolidado_dia.sql` | fila del líder (consolidado de su turno) también en la tabla de Hoy / Día: `var_horas_vivas` y clave `consolidado_dia` en `var_resumen_mes` | 2026-09-08 |
| `tests/sprint2_escalera.sql` y `tests/sprint2_consolidado_dia.sql` | pruebas de la escalera y el prorrateo (en verde) | — |
| `tests/sprint1_puras.sql` | 23 pruebas de funciones puras (todas en verde el 2026-09-05) | — |
| `../functions/variables/index.ts` | Edge Function: valida el JWT contra Auth, rol desde `var_usuarios`, acciones×rol, proyección por lista blanca | v1, `verify_jwt=false` (validación propia) |
| `../../equipo/index.html` | página única con vistas por rol (`/equipo/`) | se publica al mergear a `main` (GitHub Pages) |

**Hecho del Sprint 2:** `var_calcular_mes` (monto ESTIMADO por agente y líder, solo Admin, pestaña "Pago del mes"). **Falta:** entradas manuales (días tarde, multiplicador), `var_liquidar` con foto, libro de ajustes, respaldo `pg_dump` a repo privado, pruebas con fixtures.

**Pasos manuales en Supabase → Authentication (Karen/Daniel):** desactivar sign-up · SMTP propio · Site URL y Redirect URL =
`https://karenmalagon-star.github.io/resultados-agentes-ops/equipo/` · invitar personas · en la página, Admin les asigna rol.
El primer admin se crea con una fila directa en `var_usuarios` (SQL), una sola vez.

**Identidad visual (8-sep-2026, aprobada por Daniel):** un solo tema claro; verde #0B6B3A y dorado #F5C21B/#E9A11D del logo; fuente Museo 700 (`equipo/fonts/Museo700.otf`); ningún texto en mayúsculas sostenidas (inicial mayúscula y el resto minúscula); logo = solo el círculo del isotipo, sin letras (provisional en SVG hasta recibir el archivo).
