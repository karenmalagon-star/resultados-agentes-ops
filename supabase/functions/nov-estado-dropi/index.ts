// ============================================================================
// nov-estado-dropi — estado de las órdenes en Dropi vía Broker Fenix (D-026) + gestiones de la IA. Cron cada 5 min de 05:00 a 08:55 Colombia.
//  · El Broker procesa el job SOLO cuando se le hace GET (Cloud Run sin CPU en reposo): cada llamada nuestra sondea en secuencia
//    (una consulta de hasta ~90 s por invocación) y guarda el avance en nov_estado_jobs; la siguiente llamada del cron continúa. Nada se solapa.
//  · Candidatas (nov_candidatas_estado): gestión aceptada en los últimos 180 días sin estado final; diario los primeros 14 días, semanal después;
//    tandas de 1.000 (tope de PostgREST) cada vez que no hay jobs pendientes, sin repetir órdenes ya consultadas hoy.
//  · Historial de estados de Dropi (con fechas reales) → nov_orden_estado_hist; último estado → nov_orden_estado.
//  · Una vez al día trae las gestiones de la IA (ayer y hoy) → nov_ia_gestiones.
// ============================================================================
import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const SURL = Deno.env.get("SUPABASE_URL")!;
const SR = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const BROKER = Deno.env.get("BROKER_URL") || "https://broker-gateway-agftf9yl.uc.gateway.dev";
const BKEY = Deno.env.get("BROKER_API_KEY") || "";
const DBH = { apikey: SR, Authorization: `Bearer ${SR}`, "Content-Type": "application/json" } as Record<string, string>;
const BH = { "X-API-Key": BKEY, "Content-Type": "application/json" } as Record<string, string>;
const json = (o: unknown, s = 200) => new Response(JSON.stringify(o), { status: s, headers: { "content-type": "application/json" } });
const FINAL = new Set(["ENTREGADO", "DEVOLUCION", "DESTRUCCION - SALVAMENTO - DONACION", "INDEMNIZADA", "INDEMNIZADA POR DROPI", "SINIESTRO"]);
const PRESUPUESTO_MS = 100_000;   // por invocación (tope de la plataforma ~150 s)
const INICIO_GET_MS = 20_000;     // un GET al Broker tarda hasta ~90 s: solo se inicia uno si vamos por debajo de 20 s → una consulta por invocación
const LOTE = 200;

async function cfg(key: string): Promise<string> {
  for (let i = 0; i < 3; i++) {
    try { const r = await fetch(`${SURL}/rest/v1/app_config?key=eq.${encodeURIComponent(key)}&select=value`, { headers: DBH }); const j = await r.json(); if (Array.isArray(j)) return (j[0] && j[0].value) || ""; } catch (_) { /* reintenta */ }
    await new Promise((res) => setTimeout(res, 500));
  }
  return "";
}
async function local<T = any>(path: string): Promise<T> { const r = await fetch(`${SURL}/rest/v1/${path}`, { headers: DBH }); if (!r.ok) throw new Error(`local ${path.split("?")[0]} ${r.status}: ${await r.text()}`); return await r.json(); }
async function rpc(fn: string, body: unknown): Promise<any> { const r = await fetch(`${SURL}/rest/v1/rpc/${fn}`, { method: "POST", headers: DBH, body: JSON.stringify(body) }); if (!r.ok) throw new Error(`rpc ${fn} ${r.status}: ${await r.text()}`); const t = await r.text(); return t ? JSON.parse(t) : null; }
async function upsert(table: string, rows: unknown[], onConflict: string, ignore = false): Promise<void> {
  for (let i = 0; i < rows.length; i += 500) {
    const r = await fetch(`${SURL}/rest/v1/${table}?on_conflict=${onConflict}`, { method: "POST", headers: { ...DBH, Prefer: `resolution=${ignore ? "ignore" : "merge"}-duplicates,return=minimal` }, body: JSON.stringify(rows.slice(i, i + 500)) });
    if (!r.ok) throw new Error(`upsert ${table} ${r.status}: ${await r.text()}`);
  }
}
async function patch(table: string, filter: string, body: unknown): Promise<void> { const r = await fetch(`${SURL}/rest/v1/${table}?${filter}`, { method: "PATCH", headers: DBH, body: JSON.stringify(body) }); if (!r.ok) throw new Error(`patch ${table} ${r.status}: ${await r.text()}`); }

async function guardarResultados(res: any[]): Promise<number> {
  const now = new Date().toISOString(); const est: any[] = []; const hist: any[] = [];
  for (const r of res) {
    const st = r.status ? String(r.status).toUpperCase().trim() : null;
    est.push({ order_id: String(r.order_id), country: String(r.country || "").toUpperCase(), store_name: r.store ?? null, found: !!r.found, status: st, created_at_dropi: r.created_at ?? null, checked_at: r.checked_at ?? now, final: !!(st && FINAL.has(st)) });
    for (const h of (r.historial_estados || [])) {
      const e = String(h.estado ?? h.status ?? "").toUpperCase().trim(); const f = h.fecha ?? h.date ?? h.at;
      if (e && f) hist.push({ order_id: String(r.order_id), country: String(r.country || "").toUpperCase(), estado: e, fecha: f, visto_en: now });
    }
  }
  if (est.length) await upsert("nov_orden_estado", est, "order_id,country");
  if (hist.length) await upsert("nov_orden_estado_hist", hist, "order_id,country,estado,fecha", true);
  return est.length;
}

Deno.serve(async (req: Request) => {
  const stored = await cfg("write_key");
  if (!stored) return json({ error: "config no disponible (transitorio)" }, 503);
  if ((req.headers.get("x-write-key") || "") !== stored) return json({ error: "unauthorized" }, 401);
  if (!BKEY) return json({ error: "falta el secreto BROKER_API_KEY" }, 503);
  const t0 = Date.now(); const det: Record<string, unknown> = {};
  const logRow = await fetch(`${SURL}/rest/v1/nov_sync_log`, { method: "POST", headers: { ...DBH, Prefer: "return=representation" }, body: JSON.stringify({ fn: "nov-estado-dropi" }) }).then((r) => r.json()).catch(() => null);
  const logId = logRow?.[0]?.id;
  try {
    // A) jobs pendientes → sondear en secuencia dentro del presupuesto
    let pend = await local(`nov_estado_jobs?status=eq.pending&order=n.asc,creado_en.asc&select=job_id,country,n`);   // lotes pequeños primero
    let sondeos = 0, guardadas = 0;
    while (pend.length && Date.now() - t0 < INICIO_GET_MS) {
      const j = pend[0];
      const r = await fetch(`${BROKER}/v1/orders/status/${j.job_id}`, { headers: BH });
      const body = await r.json().catch(() => ({}));
      sondeos++;
      await patch("nov_estado_jobs", `job_id=eq.${j.job_id}`, { ultimo_poll: new Date().toISOString(), done: body.done ?? null });
      if (!r.ok) { await patch("nov_estado_jobs", `job_id=eq.${j.job_id}`, { status: "error", error: `${r.status} ${JSON.stringify(body).slice(0, 300)}`, terminado_en: new Date().toISOString() }); pend.shift(); continue; }
      if (body.status === "done" || body.status === "error") {
        if (body.status === "done") guardadas += await guardarResultados(body.results || []);
        await patch("nov_estado_jobs", `job_id=eq.${j.job_id}`, { status: body.status, error: body.error ?? null, terminado_en: new Date().toISOString() });
        pend.shift();
      }
      // si sigue pending, el GET ya procesó un tramo; se vuelve a llamar en el siguiente ciclo del while o del cron
    }
    det.sondeos = sondeos; det.guardadas = guardadas; det.pendientes = pend.length;
    if (pend.length) { if (logId) await patch("nov_sync_log", `id=eq.${logId}`, { fin: new Date().toISOString(), ok: true, detalle: det }); return json({ ok: true, fase: "sondeo", ...det }); }

    // B) sin jobs pendientes: siguiente tanda de candidatas (la función SQL ya excluye lo consultado hoy)
    const hoyCol = new Date(Date.now() - 5 * 3600000).toISOString().slice(0, 10);
    const cand: any[] = await rpc("nov_candidatas_estado", { p_dias: 14, p_max: 1000, p_dias_max: 180 });
    const porPais: Record<string, any[]> = {};
    for (const c of cand) (porPais[c.country] ||= []).push({ order_id: String(c.order_id), store: c.store_name, country: c.country });
    let encolados = 0; const jobs: any[] = [];
    for (const [country, arr] of Object.entries(porPais)) {
      for (let i = 0; i < arr.length; i += LOTE) {
        const lote = arr.slice(i, i + LOTE);
        const r = await fetch(`${BROKER}/v1/orders/status`, { method: "POST", headers: BH, body: JSON.stringify({ orders: lote }) });
        const body = await r.json().catch(() => ({}));
        if (!r.ok || !body.job_id) { jobs.push({ job_id: `err-${Date.now()}-${encolados}`, country, n: lote.length, status: "error", error: `${r.status} ${JSON.stringify(body).slice(0, 300)}`, terminado_en: new Date().toISOString() }); continue; }
        jobs.push({ job_id: body.job_id, country, n: lote.length, status: "pending" }); encolados += lote.length;
      }
    }
    if (jobs.length) await upsert("nov_estado_jobs", jobs, "job_id");
    det.candidatas = cand.length; det.encolados = encolados; det.jobs = jobs.length;

    // D) gestiones de la IA (ayer y hoy), una vez al día, solo columnas sin datos del cliente
    const desde = new Date(Date.now() - 5 * 3600000 - 2 * 86400000).toISOString().slice(0, 10);
    const iaHoy = await local(`nov_ia_gestiones?sincronizado_en=gte.${hoyCol}T05:00:00Z&select=order_id&limit=1`);
    let off = 0, ia = 0;
    while (!iaHoy.length || new URL(req.url).searchParams.get("force") === "1") {
      const r = await fetch(`${BROKER}/v1/ia/gestiones?desde=${desde}&hasta=${hoyCol}&limit=1000&offset=${off}`, { headers: BH });
      if (!r.ok) { det.ia_error = `${r.status}`; break; }
      const b = await r.json(); const g = b.gestiones || [];
      if (g.length) await upsert("nov_ia_gestiones", g.map((x: any) => ({ order_id: String(x.order_id), revisado_at: x.revisado_at, country: x.country ? String(x.country).toUpperCase() : null, store_name: x.store_name, trigger_evento: x.trigger_evento, decision: x.decision, status_interno: x.status_interno, resultado_dropi: x.resultado_dropi, tipo_novedad: x.tipo_novedad, ronda_id: x.ronda_id, worker_id: x.worker_id, sincronizado_en: new Date().toISOString() })), "order_id,revisado_at");
      ia += g.length; off += b.limit || 1000;
      if (!g.length || off >= (b.total || 0) || off > 50000 || Date.now() - t0 > PRESUPUESTO_MS) break;
    }
    det.ia = ia;
    if (logId) await patch("nov_sync_log", `id=eq.${logId}`, { fin: new Date().toISOString(), ok: true, detalle: det });
    return json({ ok: true, fase: "encolado", ...det });
  } catch (e) {
    const msg = String((e as Error)?.message || e);
    if (logId) await patch("nov_sync_log", `id=eq.${logId}`, { fin: new Date().toISOString(), ok: false, detalle: { ...det, error: msg } });
    return json({ ok: false, error: msg, ...det }, 500);
  }
});
