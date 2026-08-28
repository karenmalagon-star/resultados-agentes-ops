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

    // Ventana: los 2 dias COMPLETOS anteriores a hoy (hora Colombia), porque el reporte
    // de Refresh devuelve buckets fijos (Hoy parcial, Ayer, Anteayer, "Ultimos 4 dias"
    // acumulado — verificado con ?debug=1 el 2026-08-27). Se comparan Ayer + Anteayer:
    // dias cerrados en ambos lados, sin dia parcial ni acumulados que dupliquen.
    const col = new Date(Date.now() - 5 * 3600000);
    const p = (x: number) => String(x).padStart(2, "0");
    const ymd = (d: Date) => d.getUTCFullYear() + "-" + p(d.getUTCMonth() + 1) + "-" + p(d.getUTCDate());
    const ayer = new Date(Date.UTC(col.getUTCFullYear(), col.getUTCMonth(), col.getUTCDate() - 1));
    const inicio = new Date(Date.UTC(col.getUTCFullYear(), col.getUTCMonth(), col.getUTCDate() - 2));
    const desde = ymd(inicio), hasta = ymd(ayer);

    // Reporte interno de Refresh (misma convencion de fechas que /orders/: hora Colombia etiquetada Z).
    const q = `startDate=${desde}T00:00:00.000Z&endDate=${hasta}T23:59:59.999Z`;
    const rr = await fetch(`${REFRESH}/reports/managed-orders-date/?${q}`, { headers: H });
    const rtxt = await rr.text();
    if (debug) return json({ debug: true, status: rr.status, desde, hasta, cuerpo: rtxt.slice(0, 4000) });
    let rep: any = null;
    try { rep = JSON.parse(rtxt); } catch (_) { rep = null; }
    if (rr.status !== 200 || rep == null) return await fallo("el reporte de Refresh no respondió (HTTP " + rr.status + ")", rtxt.slice(0, 200), 502);

    // Parser: buckets por nombre. El reporte (verificado 2026-08-27) es un array de
    // { period: "Hoy"|"Ayer"|"Anteayer"|"Últimos 4 días", totalConfirmed, totalCancelled, ... }.
    // Se usan SOLO "Ayer" y "Anteayer": "Hoy" va parcial y "Últimos 4 días" es acumulado.
    const items: any[] = Array.isArray(rep) ? rep : (Array.isArray(rep.data) ? rep.data : []);
    const normP = (x: string) => (x || "").toLowerCase().normalize("NFD").replace(/[\u0300-\u036f]/g, "").trim();
    const bAyer = items.find((x: any) => normP(x.period) === "ayer");
    const bAnte = items.find((x: any) => normP(x.period) === "anteayer");
    if (!bAyer || !bAnte || typeof bAyer.totalConfirmed !== "number" || typeof bAnte.totalConfirmed !== "number") {
      return await fallo("el reporte de Refresh cambio de forma (no encuentro los buckets Ayer/Anteayer); correr con ?debug=1 y ajustar el parser", { periodos: items.map((x: any) => x && x.period) }, 500);
    }
    const repConf = (+bAyer.totalConfirmed || 0) + (+bAnte.totalConfirmed || 0);
    const repCanc = (+bAyer.totalCancelled || 0) + (+bAnte.totalCancelled || 0);

    // Nuestros totales (historia permanente)
    const nosConf = await countEvents(desde, hasta, 0);
    const nosCanc = await countEvents(desde, hasta, 1);

    // COMPARACION POR LINEA BASE (calibrado 2026-08-27): las dos fuentes cuentan
    // DISTINTO por diseño (el dashboard excluye buzones, reclasifica "Nueva orden" y
    // no ve las cancelaciones fuera de la app), asi que una tolerancia absoluta es
    // inaplicable (medido: conf +5.4%, canc -45%). Lo que SI detecta perdida de datos
    // es la DESVIACION de esa relacion: si la razon dashboard/Refresh cambia mas de
    // verify_desviacion % (default 10) frente a la linea base, algo se rompio.
    // Re-calibrar: delete from app_config where key='verify_baseline';
    const rConf = repConf > 0 ? nosConf / repConf : 0;
    const rCanc = repCanc > 0 ? nosCanc / repCanc : 0;
    const dRaw = parseFloat(await cfg("verify_desviacion"));
    const DEV = Number.isFinite(dRaw) && dRaw > 0 ? dRaw : 10;
    let base: any = null;
    try { base = JSON.parse(await cfg("verify_baseline")); } catch (_) { base = null; }

    let ok = true, modo = "";
    let devConf = 0, devCanc = 0;
    if (!base || !Number.isFinite(+base.rConf) || !Number.isFinite(+base.rCanc)) {
      // Primera corrida (o re-calibracion): se fija la linea base, sin alerta.
      await setCfg("verify_baseline", JSON.stringify({ rConf: +rConf.toFixed(4), rCanc: +rCanc.toFixed(4), at: new Date().toISOString(), ventana: desde + ".." + hasta }));
      modo = "linea base establecida";
    } else {
      devConf = base.rConf > 0 ? +(Math.abs(rConf - base.rConf) / base.rConf * 100).toFixed(1) : 0;
      devCanc = base.rCanc > 0 ? +(Math.abs(rCanc - base.rCanc) / base.rCanc * 100).toFixed(1) : 0;
      ok = devConf <= DEV && devCanc <= DEV;
      modo = "comparado contra linea base";
    }

    const resumen = { ok, modo, desde, hasta, desviacion_max_pct: DEV, confirmadas: { dashboard: nosConf, refresh: repConf, razon: +rConf.toFixed(4), desviacion_pct: devConf }, canceladas: { dashboard: nosCanc, refresh: repCanc, razon: +rCanc.toFixed(4), desviacion_pct: devCanc }, linea_base: base };
    await setCfg("last_verify", JSON.stringify({ ...resumen, at: new Date().toISOString() }));

    if (!ok) {
      await avisar("⚠️ Dashboard Ops: la validación semanal contra Refresh se desvió",
        `<p>La relación entre los números del dashboard y el reporte de Refresh cambió más de ${DEV}% frente a su línea base (período <b>${desde} a ${hasta}</b>):</p><ul><li>Confirmadas: dashboard ${nosConf} vs Refresh ${repConf} — desviación ${devConf}%</li><li>Canceladas: dashboard ${nosCanc} vs Refresh ${repCanc} — desviación ${devCanc}%</li></ul><p><b>Qué significa:</b> las dos fuentes siempre difieren un poco (cuentan distinto a propósito), pero esa diferencia es estable. Que se haya movido tanto suele indicar que alguna corrida perdió datos o que Refresh cambió algo.</p><p><b>Qué hacer:</b> revisar los Logs de las Edge Functions en Supabase (proyecto "Resultados Agentes Ops") o avisar a Daniel.</p>`);
    }
    return json(resumen);
  } catch (e) { return await fallo("excepción: " + String(e)); }
});
