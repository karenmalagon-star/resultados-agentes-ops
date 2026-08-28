// ============================================================================
// REGLAS DE NEGOCIO COMPARTIDAS — dashboard "Resultados Agentes Ops"
// Fuente unica: supabase/functions/_shared/rules.ts
// Cada funcion la importa como "./rules.ts" (el script sync-rules.sh copia este
// archivo junto a cada funcion; al desplegar se incluyen index.ts + rules.ts).
// NO editar las copias: editar SOLO este archivo y re-copiar.
// Decisiones de negocio: ver DECISIONES.md y el cuestionario de Karen (2026-08-27).
// ============================================================================

// Normalizacion de texto para comparar nombres/estados: sin espacios repetidos,
// sin mayusculas, sin acentos. "Pendiente  Confirmación" == "pendiente confirmacion".
export const norm = (s: string): string =>
  (s || "").trim().replace(/\s+/g, " ").toLowerCase().normalize("NFD").replace(/[\u0300-\u036f]/g, "");

// Usuarios que NO son agentes reales (buzones internos de la operacion).
// Deteccion por SUBSTRING (decision Karen, cuestionario B1 2026-08-27): una
// variante como "Postfecha Colombia" tambien debe detectarse.
// Caso borde conocido: la deteccion opera sobre nombre+apellido normalizados, asi que
// un agente real cuyo nombre completo contenga un patron como substring (ej. "Yasin
// Gestiones" contiene "sin gestion") quedaria excluido en silencio. Si un agente real
// "desaparece" de los numeros, revisar esto primero.
export const EXCLUDED_AGENT_PATTERNS = ["postfecha", "reprogramadas operacion", "sin gestion", "seguimiento historico"];
export const isExcludedAgent = (name: string): boolean => {
  const x = norm(name);
  if (!x) return false;
  return EXCLUDED_AGENT_PATTERNS.some((p) => x.indexOf(p) >= 0);
};

// REGLA_POSTFECHA (DECISIONES.md D-002): orden con contacto pactado a futuro
// (mas alla del plazo estandar de 72 h). NO es atraso. Resultados/Lider la
// excluyen (no es trabajo exigible hoy, sin alarma); Cierre la cuenta APARTE
// (entra a "entered", sale de "gestionables"). No unificar.
export const isPostfecha = (name: string): boolean => norm(name).indexOf("postfecha") >= 0;

// Zona horaria: Refresh guarda hora Colombia etiquetada como UTC. La hora
// "actual de Colombia" se obtiene restando 5 h y leyendo con getUTC*.
export const COL_OFFSET_MS = 5 * 3600000;
export const colNow = (): Date => new Date(Date.now() - COL_OFFSET_MS);
