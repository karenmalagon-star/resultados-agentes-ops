import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const SURL = Deno.env.get("SUPABASE_URL")!;
const SR = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const H = { apikey: SR, Authorization: `Bearer ${SR}` } as Record<string, string>;
const CORS = { "access-control-allow-origin": "*", "access-control-allow-headers": "authorization, content-type", "access-control-allow-methods": "GET, POST, OPTIONS" };

// Inyecta JSON de forma segura dentro de un <script>: escapa '<' (para que ningun dato con
// '</script>' corte el script) y los separadores de linea U+2028/U+2029.
const LS = String.fromCharCode(0x2028), PS = String.fromCharCode(0x2029);
const inject = (o: unknown) => JSON.stringify(o).replace(/</g, "\\u003c").replace(new RegExp(LS, "g"), "\\u2028").replace(new RegExp(PS, "g"), "\\u2029");

async function rpc(fn: string, body: unknown) {
  const r = await fetch(`${SURL}/rest/v1/rpc/${fn}`, { method: "POST", headers: { ...H, "Content-Type": "application/json" }, body: JSON.stringify(body) });
  return await r.json();
}
async function getOne(path: string) {
  const r = await fetch(`${SURL}/rest/v1/${path}`, { headers: H });
  return await r.json();
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
  const unauthorized = () => new Response("Autenticacion requerida", { status: 401, headers: { ...CORS, "WWW-Authenticate": 'Basic realm="Dashboard Refresh"' } });
  const auth = req.headers.get("authorization") || "";
  if (!auth.toLowerCase().startsWith("basic ")) return unauthorized();
  let user = "", pass = "";
  try { const dec = atob(auth.slice(6)); const i = dec.indexOf(":"); user = dec.slice(0, i); pass = dec.slice(i + 1); } catch (_) { return unauthorized(); }
  let ok = false;
  try { ok = (await rpc("check_login", { u: user, p: pass })) === true; } catch (_) { ok = false; }
  if (!ok) return unauthorized();
  try {
    const tpl = await getOne("assets?key=eq.template&select=content");
    const template = (tpl && tpl[0] && tpl[0].content) || "<h1>Sin plantilla</h1>";
    // Resultados: preferir la HISTORIA COMPLETA (histD); si no, el snapshot de 5 dias.
    let data: any = {};
    try { const hd = await getOne("panel_data?key=eq.histD&select=data"); data = (hd && hd[0] && hd[0].data) || {}; } catch (_) { data = {}; }
    if (!data || !Array.isArray(data.events) || data.events.length === 0) {
      const snap = await getOne("snapshot?select=data&order=created_at.desc&limit=1");
      data = (snap && snap[0] && snap[0].data) || {};
    }
    let leader: unknown = {}, cohort: any = {}, cap: unknown = {};
    try { const ld = await getOne("panel_data?key=eq.leader&select=data"); leader = (ld && ld[0] && ld[0].data) || {}; } catch (_) { leader = {}; }
    // Cierre: preferir la HISTORIA (cohortH); si no, el cohort de 5 dias.
    try {
      const chh = await getOne("panel_data?key=eq.cohortH&select=data"); let cd: any = (chh && chh[0] && chh[0].data);
      if (!cd || !Array.isArray(cd.general) || cd.general.length === 0) { const ch = await getOne("panel_data?key=eq.cohort&select=data"); cd = (ch && ch[0] && ch[0].data) || {}; }
      cohort = cd || {};
    } catch (_) { cohort = {}; }
    try { const cp = await getOne("panel_data?key=eq.capacity&select=data"); cap = (cp && cp[0] && cp[0].data) || {}; } catch (_) { cap = {}; }
    // Configuracion de reglas para el cliente (jornada, festivos, meta de Gest/hora).
    // Editable en app_config sin redesplegar (decisiones C5/D1/D4/D5 del cuestionario).
    const JORNADA_DEF: Record<string, number> = { "0": 0, "1": 7.5, "2": 7.5, "3": 7.5, "4": 7.5, "5": 6.5, "6": 5.5, "festivo": 5.5 };
    const rcfg: any = { jornada: { ...JORNADA_DEF }, festivos: [], meta: 38 };
    try {
      const rows = await getOne("app_config?select=key,value&key=in.(jornada,festivos_co,gest_hora_meta)");
      if (Array.isArray(rows)) for (const row of rows) {
        if (row.key === "jornada") {
          // Merge con defaults (permite override parcial) y solo valores numericos validos.
          try { const pj = JSON.parse(row.value); if (pj && typeof pj === "object") { for (const k of Object.keys(pj)) { const v = parseFloat(pj[k]); if (Number.isFinite(v) && v >= 0) rcfg.jornada[k] = v; } } } catch (_) { /* opcional */ }
        }
        if (row.key === "festivos_co") { try { const pf = JSON.parse(row.value); if (Array.isArray(pf)) rcfg.festivos = pf.filter((x: unknown) => typeof x === "string"); } catch (_) { /* opcional */ } }
        if (row.key === "gest_hora_meta") { const n = parseFloat(row.value); if (Number.isFinite(n) && n > 0) rcfg.meta = n; }
      }
    } catch (_) { /* config opcional: el cliente tiene defaults */ }
    // Reemplazo en UNA sola pasada: el contenido ya inyectado nunca se re-escanea,
    // asi un dato de Dropi que contenga un token literal no puede secuestrar otro token
    // (leccion del incidente __AUTHB64__).
    const TOKENS: Record<string, string> = {
      "__DATA__": inject(data),
      "__LEADERDATA__": inject(leader),
      "__COHORTDATA__": inject(cohort),
      "__CAPDATA__": inject(cap),
      "__RULESCFG__": inject(rcfg),
      "__AB64__": JSON.stringify(auth.slice(6)),
    };
    const html = template.replace(/__(?:DATA|LEADERDATA|COHORTDATA|CAPDATA|RULESCFG|AB64)__/g, (t: string) => TOKENS[t] ?? t);
    return new Response(html, { status: 200, headers: { ...CORS, "content-type": "text/html; charset=utf-8", "cache-control": "no-store" } });
  } catch (e) {
    return new Response("Error: " + String(e), { status: 500, headers: CORS });
  }
});
