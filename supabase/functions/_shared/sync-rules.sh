#!/bin/bash
# Copia la fuente unica de reglas junto a cada funcion que la importa.
# Correr despues de editar _shared/rules.ts y antes de desplegar.
set -e
cd "$(dirname "$0")/.."
for f in sync-refresh sync-panels sync-cohort sync-presence; do
  cp _shared/rules.ts "$f/rules.ts"
  echo "copiado a $f/"
done
