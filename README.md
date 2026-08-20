# Resultados Agentes Ops

Tablero web que reconstruye solo las metricas de gestion de llamadas del equipo OPS
(por agente, dia, media hora, pais y tienda) leyendo la API interna de Refresh.
Corre 100% en la nube: Supabase (Postgres + Edge Functions + pg_cron) + GitHub Pages.

Empieza por docs/HANDOFF_TECNICO_Resultados_Agentes_Ops.md (arquitectura, accesos, que
calcula cada grafica, como editar). docs/PROYECTO_memoria.txt es la bitacora completa.

## Estructura

    index.html                     Login (GitHub Pages). Hace fetch a la funcion dashboard.
    dashboard/
      template.html                Plantilla del tablero (se genera con pull-template.sh; vive en la BD).
      pull-template.sh             Exporta/sube la plantilla desde/hacia la tabla assets.
    supabase/
      schema.sql                   Esquema (indicativo) de tablas + funcion check_login.
      cron.sql                     Tareas programadas (pg_cron). Reemplaza <WRITE_KEY>.
      functions/<nombre>/index.ts  Codigo de cada Edge Function (Deno/TypeScript).
    docs/                          Documentacion (handoff tecnico + bitacora).

## La plantilla vive en la base de datos

La visual (HTML+CSS+JS) esta en public.assets (key='template'), no como archivo. Para
versionarla:  export SUPABASE_DB_URL=...  &&  ./dashboard/pull-template.sh

## Secretos

No hay secretos en el repo. Viven en app_config (refresh_email, refresh_password,
write_key, auth_user, auth_pw_hash) y en variables de entorno de las Edge Functions
(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY). Proyecto Supabase: sbiyedqpqtiqvlgentci.
