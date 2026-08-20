#!/usr/bin/env bash
# Exporta la plantilla HTML del tablero (tabla assets, key='template') desde la
# base de datos a dashboard/template.html, para poder versionarla en GitHub.
#
# Requiere psql y la cadena de conexion del proyecto Supabase:
#   Supabase -> Project Settings -> Database -> Connection string (URI).
#
# Uso:
#   export SUPABASE_DB_URL='postgresql://postgres:...@db.sbiyedqpqtiqvlgentci.supabase.co:5432/postgres'
#   ./dashboard/pull-template.sh
#
set -euo pipefail
: "${SUPABASE_DB_URL:?Define SUPABASE_DB_URL con la cadena de conexion de Supabase}"
OUT="$(dirname "$0")/template.html"
psql "$SUPABASE_DB_URL" -Atqc "select content from public.assets where key='template'" > "$OUT"
echo "Plantilla exportada a $OUT ($(wc -c < "$OUT") bytes)"

# Para SUBIR una edicion local de la plantilla de vuelta a la base:
#   psql "$SUPABASE_DB_URL" -c "\\set c \`cat dashboard/template.html\`" \
#     -c "update public.assets set content = :'c', updated_at = now() where key='template';"
