// verify-refresh: validacion SEMANAL (viernes) de nuestros totales contra el
// reporte interno de Refresh (GET /bff/reports/managed-orders-date/).
// Decision Karen (cuestionario D7/F, 2026-08-27): cadencia semanal, tolerancia <= 0.5%.
//
// NOTA DE SEMANTICA (revision 2026-08-27): events_history EXCLUYE pseudo-agentes y
// reclasifica "Nueva orden" como confirmada; el reporte de Refresh cuenta crudo. Por eso:
//   (a) ademas de la tolerancia porcentual hay un PISO en ordenes (verify_min_ordenes,
//       default 15): solo alerta si el % Y el numero absoluto se pasan a la vez;
//   (b) la validacion original de julio dio ~0.3% con esta misma semantica, asi que el
//       sesgo esperado es pequeno; si la alerta resultara ruidosa, calibrar con ?debug=1.
// TODO fallo: cualquier camino de error escribe last_verify y avisa por correo
// ("no pudo correr") — una validacion muerta en silencio no valida nada.
// ?debug=1 devuelve la respuesta cruda del reporte (para inspeccionar su forma).
import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const SURL = Deno.env.get("SUPABASE_URL")!;
const SR = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const DBH = { apikey: SR, Authorization: `Bearer ${SR}`, "Content-Type": "application/json" } as Record<string, string>;
const REFRESH = "https://api-refresh.fenix-ventures.co/bff";
const json = (o: unknown, s = 200) => new Response(JSON.stringify(o), { status: s, headers: { "content-type": "application/json" } });

async function cfg(key: string): Promise<string> {
  for (let i = 0; i < 3; i++) {
    try {
      const r = await fetch(`${SURL}/rest/v1/app_config?key=eq.${encodeURIComponent(key)}&select=value`, { headers: DBH });
      const j = await r.json();
      if (Array.isArray(j)) return (j[0] && j[0].value) || "";
    } catch (_) { /* reintenta */ }
    await new Promise((res) => setTimeout(res, 500));
  }
  return "";
}

async function setCfg(key: string, value: string) {
  await fetch(`${SURL}/rest/v1/app_config`, { method: "POST", headers: { ...DBH, Prefer: "resolution=merge-duplicates,return=minimal" }, body: JSON.stringify({ key, value }) }).catch(() => {});
}

async function avisar(asunto: string, mensaje: string) {
  const whUrl = await cfg("alert_webhook_url"), tk = await cfg("alert_token");
  if (!whUrl || !tk) return;
  await fetch(whUrl, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ token: tk, asunto, mensaje }) }).catch(() => {});
}

// Cuenta filas en events_history via PostgREST. Lanza si la lectura falla:
// un conteo falso de 0 produciria una alerta con cifras inventadas.
async function countEvents(desde: string, hasta: string, type: number): Promise<number> {
  const r = await fetch(`${SURL}/rest/v1/events_history?select=order_id&ev_date=gte.${desde}&ev_date=lte.${hasta}&type=eq.${type}&limit=1`,
    { headers: { ...DBH, Prefer: "count=exact", Range: "0-0" } });
  if (!r.ok) throw new Error("countEvents HTTP " + r.status);
  const cr = r.headers.get("content-range") || "";
  if (!cr.includes("/")) throw new Error("countEvents sin content-range");
  const total = parseInt(cr.split("/")[1]);
  if (isNaN(total)) throw new Error("countEvents content-range ilegible: " + cr);
  return total;
}

Deno.serve(async (req: Request) => {
  const wk = req.headers.get("x-write-key") || "";
  const stored = await cfg("write_key");
  if (!stored) return json({ error: "config no disponible (transitorio)" }, 503);
  if (wk !== stored) return json({ error: "unauthorized" }, 401);
  const url = new URL(req.url);
  const debug = url.searchParams.get("debug") === "1";

  // Fallo RUIDOSO: registra en last_verify y avisa por correo.
  async function fallo(motivo: string, extra: unknown = null, status = 500) {
    await setCfg("last_verify", JSON.stringify({ ok: false, error: motivo, at: new Date().toISOString() }));
    await avisar("⚠️ Dashboard Ops: la validación semanal NO PUDO CORRER",
      `<p>La comparación semanal contra Refresh falló antes de poder comparar:</p><p><b>${motivo}</b></p><p>Revisar los Logs de la función <b>verify-refresh</b> en Supabase (proyecto "Resultados Agentes Ops") o avisar a Daniel.</p>`);
    return json({ ok: false, error: motivo, extra }, status);
  }

  try {
    const email = await cfg("refresh_email"), password = await cfg("refresh_password");
    if (!email || !password) return await fallo("faltan credenciales de Refresh en app_config", null, 400);
    const lr = await fetch(`${REFRESH}/auth/sign-in`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ email, password }) });
    if (lr.status !== 200 && lr.status !== 201) return await fallo("login a Refresh falló (HTTP " + lr.status + ")", null, 502);
    const lj: any = await lr.json();
    const token = lj.token || lj.accessToken || lj.access_token || (lj.data && (lj.data.token || lj.data.accessToken || lj.data.access_token));
    if (!token) return await fallo("Refresh no devolvió token de sesión", Object.keys(lj || {}), 502);
    const H = { Authorization: "Bearer " + token, "Content-Type": "application/json" };

    // Ventana: los 4 dias completos anteriores a hoy (hora Colombia).
    const col = new Date(Date.now() - 5 * 3600000);
    const p = (x: number) => String(x).padStart(2, "0");
    const ymd = (d: Date) => d.getUTCFullYear() + "-" + p(d.getUTCMonth() + 1) + "-" + p(d.getUTCDate());
    const ayer = new Date(Date.UTC(col.getUTCFullYear(), col.getUTCMonth(), col.getUTCDate() - 1));
    const inicio = new Date(Date.UTC(col.getUTCFullYear(), col.getUTCMonth(), col.getUTCDate() - 4));
    const desde = ymd(inicio), hasta = ymd(ayer);

    // Reporte interno de Refresh (misma convencion de fechas que /orders/: hora Colombia etiquetada Z).
    const q = `startDate=${desde}T00:00:00.000Z&endDate=${hasta}T23:59:59.999Z`;
    const rr = await fetch(`${REFRESH}/reports/managed-orders-date/?${q}`, { headers: H });
    const rtxt = await rr.text();
    if (debug) return json({ debug: true, status: rr.status, desde, hasta, cuerpo: rtxt.slice(0, 4000) });
    let rep: any = null;
    try { rep = JSON.parse(rtxt); } catch (_) { rep = null; }
    if (rr.status !== 200 || rep == null) return await fallo("el reporte de Refresh no respondió (HTTP " + rr.status + ")", rtxt.slice(0, 200), 502);

    // Parser: SOLO claves exactas conocidas (falla ruidoso si el reporte trae otras;
    // en ese caso correr ?debug=1, ver la forma real y ampliar las listas de claves).
    const CONF_KEYS = new Set(["confirmed", "confirmadas", "totalconfirmed", "confirmedorders"]);
    const CANC_KEYS = new Set(["cancelled", "canceled", "canceladas", "totalcancelled", "cancelledorders"]);
    const BAD = /rate|percent|pct|porcent|promedio|avg/;
    const NEG = /^(un|not|no|sin)/;
    let repConf = 0, repCanc = 0, gotConf = false, gotCanc = false;
    const acc = (o: any) => {
      if (!o || typeof o !== "object") return;
      for (const k of Object.keys(o)) {
        const v = o[k];
        if (v && typeof v === "object") { acc(v); continue; }
        if (typeof v !== "number") continue;
        const kl = k.toLowerCase();
        if (BAD.test(kl) || NEG.test(kl)) continue;
        if (CONF_KEYS.has(kl)) { repConf += v; gotConf = true; }
        else if (CANC_KEYS.has(kl)) { repCanc += v; gotCanc = true; }
      }
    };
    if (Array.isArray(rep)) rep.forEach(acc); else acc(rep);
    if (!gotConf || !gotCanc) {
      return await fallo("no pude extraer los totales del reporte de Refresh; correr con ?debug=1 y ajustar el parser a la forma real", { claves: Object.keys(Array.isArray(rep) ? (rep[0] || {}) : rep) }, 500);
    }

    // Nuestros totales (historia permanente)
    const nosConf = await countEvents(desde, hasta, 0);
    const nosCanc = await countEvents(desde, hasta, 1);

    const pct = (a: number, b: number) => b > 0 ? +(Math.abs(a - b) / b * 100).toFixed(2) : (a > 0 ? 100 : 0);
    const dConf = pct(nosConf, repConf), dCanc = pct(nosCanc, repCanc);
    const tRaw = parseFloat(await cfg("verify_tolerancia"));
    const TOL = Number.isFinite(tRaw) && tRaw >= 0 ? tRaw : 0.5;
    const mRaw = parseInt(await cfg("verify_min_ordenes"));
    const MIN = Number.isFinite(mRaw) && mRaw >= 0 ? mRaw : 15;
    const mal = (dPct: number, a: number, b: number) => dPct > TOL && Math.abs(a - b) > MIN;
    const ok = !mal(dConf, nosConf, repConf) && !mal(dCanc, nosCanc, repCanc);

    const resumen = { ok, desde, hasta, tolerancia_pct: TOL, piso_ordenes: MIN, confirmadas: { dashboard: nosConf, refresh: repConf, diff_pct: dConf }, canceladas: { dashboard: nosCanc, refresh: repCanc, diff_pct: dCanc } };
    await setCfg("last_verify", JSON.stringify({ ...resumen, at: new Date().toISOString() }));

    if (!ok) {
      await avisar("⚠️ Dashboard Ops: la validación semanal contra Refresh no cuadra",
        `<p>Comparación del período <b>${desde} a ${hasta}</b> (tolerancia ${TOL}%, piso ${MIN} órdenes):</p><ul><li>Confirmadas: dashboard ${nosConf} vs Refresh ${repConf} (diferencia ${dConf}%)</li><li>Canceladas: dashboard ${nosCanc} vs Refresh ${repCanc} (diferencia ${dCanc}%)</li></ul><p><b>Qué hacer:</b> una diferencia grande suele significar que alguna corrida perdió datos. Revisar los Logs de las Edge Functions en Supabase (proyecto "Resultados Agentes Ops") o avisar a Daniel.</p><p style="color:#888;font-size:12px">Nota: el dashboard excluye buzones internos y reclasifica "Nueva orden", así que una diferencia pequeña y estable es normal.</p>`);
    }
    return json(resumen);
  } catch (e) { return await fallo("excepción: " + String(e)); }
});
