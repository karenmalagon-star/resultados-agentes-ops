// ============================================================================
// sync-sgn — copia incremental de la base de SGN (Novedades) al proyecto de Variables. Cron cada 10 min.
//  · Lee SGN por PostgREST con la clave de servicio de SGN (secreto SGN_SERVICE_ROLE_KEY; Karen es la dueña).
//  · NO copia datos personales del cliente: ni teléfono, ni nombre, ni direcciones, ni comentarios.
//  · Incremental: novedades por last_synced_at, gestiones por created_at, eventos por id; perfiles y motivos completos.
//  · País normalizado a ISO en la base (var_pais_iso) al insertar.
// ============================================================================
import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const SURL = Deno.env.get("SUPABASE_URL")!;
const SR = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const SGN_URL = Deno.env.get("SGN_URL") || "https://znnrbpqorjrusvdasptq.supabase.co";
const SGN_KEY = Deno.env.get("SGN_SERVICE_ROLE_KEY") || "";
const DBH = { apikey: SR, Authorization: `Bearer ${SR}`, "Content-Type": "application/json" } as Record<string, string>;
const SGNH = { apikey: SGN_KEY, Authorization: `Bearer ${SGN_KEY}` } as Record<string, string>;
const json = (o: unknown, s = 200) => new Response(JSON.stringify(o), { status: s, headers: { "content-type": "application/json" } });
const PAIS: Record<string, string> = { COLOMBIA: "CO", CHILE: "CL", MEXICO: "MX", "MÉXICO": "MX", ECUADOR: "EC", GUATEMALA: "GT" };
const iso = (p: unknown) => { const s = String(p ?? "").trim().toUpperCase(); return s ? (PAIS[s] || s) : null; };

async function cfg(key: string): Promise<string> {
  for (let i = 0; i < 3; i++) {
    try { const r = await fetch(`${SURL}/rest/v1/app_config?key=eq.${encodeURIComponent(key)}&select=value`, { headers: DBH }); const j = await r.json(); if (Array.isArray(j)) return (j[0] && j[0].value) || ""; } catch (_) { /* reintenta */ }
    await new Promise((res) => setTimeout(res, 500));
  }
  return "";
}
async function local<T = any>(path: string): Promise<T> { const r = await fetch(`${SURL}/rest/v1/${path}`, { headers: DBH }); if (!r.ok) throw new Error(`local ${path.split("?")[0]} ${r.status}: ${await r.text()}`); return await r.json(); }
async function upsert(table: string, rows: unknown[], onConflict: string): Promise<void> {
  for (let i = 0; i < rows.length; i += 500) {
    const r = await fetch(`${SURL}/rest/v1/${table}?on_conflict=${onConflict}`, { method: "POST", headers: { ...DBH, Prefer: "resolution=merge-duplicates,return=minimal" }, body: JSON.stringify(rows.slice(i, i + 500)) });
    if (!r.ok) throw new Error(`upsert ${table} ${r.status}: ${await r.text()}`);
  }
}
async function sgn<T = any>(path: string): Promise<T> {   // paginado 1000 en 1000
  const out: any[] = []; let off = 0;
  while (true) {
    const r = await fetch(`${SGN_URL}/rest/v1/${path}${path.includes("?") ? "&" : "?"}limit=1000&offset=${off}`, { headers: SGNH });
    if (!r.ok) throw new Error(`sgn ${path.split("?")[0]} ${r.status}: ${await r.text()}`);
    const page = await r.json(); out.push(...page); if (page.length < 1000) break; off += 1000; if (off > 200000) break;
  }
  return out as T;
}
const ts = (x: unknown) => (x == null ? null : String(x));

Deno.serve(async (req: Request) => {
  const stored = await cfg("write_key");
  if (!stored) return json({ error: "config no disponible (transitorio)" }, 503);
  if ((req.headers.get("x-write-key") || "") !== stored) return json({ error: "unauthorized" }, 401);
  if (!SGN_KEY) return json({ error: "falta el secreto SGN_SERVICE_ROLE_KEY" }, 503);
  const full = new URL(req.url).searchParams.get("full") === "1";
  const logRow = await fetch(`${SURL}/rest/v1/nov_sync_log`, { method: "POST", headers: { ...DBH, Prefer: "return=representation" }, body: JSON.stringify({ fn: "sync-sgn" }) }).then((r) => r.json()).catch(() => null);
  const logId = logRow?.[0]?.id;
  const det: Record<string, number> = {};
  try {
    // 1) perfiles (sin correo en claro no: el correo hace falta para el puente → se copia; es de empleados, no de clientes)
    const prof = await sgn(`profiles?select=id,full_name,email,role,active,meta_diaria,metas_dia,fecha_ingreso`);
    await upsert("nov_profiles", prof.map((p: any) => ({ id: p.id, full_name: p.full_name, email: p.email ? String(p.email).toLowerCase() : null, role: p.role, active: p.active, meta_diaria: p.meta_diaria, metas_dia: p.metas_dia, fecha_ingreso: p.fecha_ingreso, sincronizado_en: new Date().toISOString() })), "id");
    det.profiles = prof.length;
    // 2) motivos (catálogo de exclusiones)
    const mot = await sgn(`motivos_devolucion?select=id,texto,orden,activo`);
    await upsert("nov_motivos", mot.map((m: any) => ({ id: m.id, texto: m.texto, orden: m.orden, activo: m.activo, sincronizado_en: new Date().toISOString() })), "id");
    det.motivos = mot.length;
    // 3) novedades: solo las tocadas por el sync de SGN desde nuestra última copia (margen 30 min)
    const lastN = full ? null : (await local(`nov_novedades?select=last_synced_at&order=last_synced_at.desc&limit=1`))[0]?.last_synced_at;
    const desdeN = lastN ? new Date(new Date(lastN).getTime() - 30 * 60000).toISOString() : "2026-01-01T00:00:00Z";
    const nov = await sgn(`novedades?select=order_id,store_name,country,tipo_novedad,status_interno,estado_local,intentos,assigned_to,broker_created_at,first_synced_at,last_synced_at,disappeared_at,dropi_review&last_synced_at=gte.${encodeURIComponent(desdeN)}&order=last_synced_at.asc`);
    await upsert("nov_novedades", nov.map((n: any) => ({ order_id: String(n.order_id), store_name: n.store_name, country: iso(n.country), tipo_novedad: n.tipo_novedad, status_interno: n.status_interno, estado_local: n.estado_local, intentos: n.intentos, assigned_to: n.assigned_to, broker_created_at: ts(n.broker_created_at), first_synced_at: ts(n.first_synced_at), last_synced_at: ts(n.last_synced_at), disappeared_at: ts(n.disappeared_at), dropi_review: n.dropi_review, sincronizado_en: new Date().toISOString() })), "order_id");
    det.novedades = nov.length;
    // 4) gestiones: desde la última copiada (margen 1 día; no cambian después de creadas)
    const lastG = full ? null : (await local(`nov_gestiones?select=created_at&order=created_at.desc&limit=1`))[0]?.created_at;
    const desdeG = lastG ? new Date(new Date(lastG).getTime() - 24 * 3600000).toISOString() : "2026-01-01T00:00:00Z";
    const ges = await sgn(`gestiones?select=id,order_id,store_name,agente_id,accion,motivo_devolucion,solucion_dropi,resolved_in_dropi,created_at&created_at=gte.${encodeURIComponent(desdeG)}&order=created_at.asc`);
    await upsert("nov_gestiones", ges.map((g: any) => ({ id: g.id, order_id: String(g.order_id), store_name: g.store_name, agente_id: g.agente_id, accion: g.accion, motivo_devolucion: g.motivo_devolucion, solucion_dropi: g.solucion_dropi ? String(g.solucion_dropi).slice(0, 300) : null, resolved_in_dropi: g.resolved_in_dropi, created_at: g.created_at, sincronizado_en: new Date().toISOString() })), "id");
    det.gestiones = ges.length;
    // 5) eventos (cuaderno de reincidencias): por id
    const lastE = full ? 0 : Number((await local(`nov_eventos?select=id&order=id.desc&limit=1`))[0]?.id || 0);
    const ev = await sgn(`novedad_eventos?select=id,order_id,evento,tipo_novedad,status_interno,broker_created_at,store_name,country,detectado_en,gestion_prev_id,gestion_prev_agente_id,gestion_prev_at,gestion_prev_accion,gestion_prev_resuelta&id=gt.${lastE}&order=id.asc`);
    await upsert("nov_eventos", ev.map((e: any) => ({ ...e, order_id: String(e.order_id), country: iso(e.country), sincronizado_en: new Date().toISOString() })), "id");
    det.eventos = ev.length;
    if (logId) await fetch(`${SURL}/rest/v1/nov_sync_log?id=eq.${logId}`, { method: "PATCH", headers: DBH, body: JSON.stringify({ fin: new Date().toISOString(), ok: true, detalle: det }) });
    return json({ ok: true, ...det });
  } catch (e) {
    const msg = String((e as Error)?.message || e);
    if (logId) await fetch(`${SURL}/rest/v1/nov_sync_log?id=eq.${logId}`, { method: "PATCH", headers: DBH, body: JSON.stringify({ fin: new Date().toISOString(), ok: false, detalle: { ...det, error: msg } }) });
    return json({ ok: false, error: msg, ...det }, 500);
  }
});
