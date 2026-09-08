// ============================================================================
// Edge Function `variables` — Módulo de Variables (Sprint 1 + maqueta aprobada + dinero para Admin + auditoría v2, input 18)
// DISENO_TECNICO_VARIABLES.md §2, §3.2, §3.5, §5.4
//  · Se despliega con verify_jwt = false en el gateway y valida ELLA MISMA el
//    token contra Auth (auth.getUser); el rol sale SOLO de var_usuarios.
//  · Negar por defecto: cada acción lista sus roles. El dinero (acción `dinero`) solo para admin.
//  · Para equipo/auditoria la respuesta de la matriz se CONSTRUYE con lista
//    blanca y pasa por una aserción que falla cerrada (500 sin cuerpo).
//  · CORS: orígenes permitidos en app_config 'variables_origins' (JSON array);
//    default = GitHub Pages del proyecto.
// ============================================================================
import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const SURL = Deno.env.get("SUPABASE_URL")!;
const SR = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const DBH: Record<string, string> = { apikey: SR, Authorization: `Bearer ${SR}`, "Content-Type": "application/json" };
const DEFAULT_ORIGINS = ["https://karenmalagon-star.github.io"];
// Palabras que jamás pueden viajar a las pantallas de Equipo/Auditoría (spec §4, decisión 25).
const PROHIBIDO = /\$|pago|peso|factor|subtotal|multiplicador|liquidaci|techo|escalera|variable/i;

type Rol = "admin" | "auditoria" | "equipo";
interface Usuario { auth_uid: string; email: string; nombre: string; rol: Rol; activo: boolean; puede_configurar: boolean; }

// ---------- utilidades de acceso a datos (service role) ----------
async function getRows(path: string): Promise<any[]> {
  const r = await fetch(`${SURL}/rest/v1/${path}`, { headers: DBH });
  if (!r.ok) throw new Error(`db ${r.status}: ${await r.text()}`);
  return await r.json();
}
async function rpc(fn: string, body: unknown): Promise<any> {
  const r = await fetch(`${SURL}/rest/v1/rpc/${fn}`, { method: "POST", headers: DBH, body: JSON.stringify(body) });
  const t = await r.text();
  if (!r.ok) { let j: any = {}; try { j = JSON.parse(t); } catch (_) { j = { message: t }; } throw Object.assign(new Error(j.message || t), { pg: j.code, hint: j.hint }); }
  return t ? JSON.parse(t) : null;
}
async function insert(table: string, row: unknown, merge = false): Promise<any> {
  const h = { ...DBH, Prefer: merge ? "resolution=merge-duplicates,return=representation" : "return=representation" };
  const r = await fetch(`${SURL}/rest/v1/${table}`, { method: "POST", headers: h, body: JSON.stringify(row) });
  const t = await r.text();
  if (!r.ok) { let j: any = {}; try { j = JSON.parse(t); } catch (_) { j = { message: t }; } throw Object.assign(new Error(j.message || t), { pg: j.code }); }
  return t ? JSON.parse(t) : null;
}
async function cfg(key: string): Promise<string | null> {
  for (let i = 0; i < 3; i++) {
    try { const rows = await getRows(`app_config?key=eq.${encodeURIComponent(key)}&select=value`); return rows[0]?.value ?? null; }
    catch (_) { await new Promise((res) => setTimeout(res, 200 * (i + 1))); }
  }
  return null;
}
// ---------- evidencias de auditoría (bucket privado; solo el service role toca el storage) ----------
const BUCKET = "auditoria-evidencias";
const MIME_OK = new Set(["image/png", "image/jpeg", "image/webp", "image/gif", "application/pdf"]);
const MAX_BYTES = 10 * 1024 * 1024;
function rutaSegura(nombre: string): string { return nombre.normalize("NFKD").replace(/[^\w.\-]+/g, "_").replace(/_+/g, "_").slice(0, 80) || "archivo"; }
async function storagePut(ruta: string, bytes: Uint8Array, mime: string): Promise<void> {
  const r = await fetch(`${SURL}/storage/v1/object/${BUCKET}/${ruta.split("/").map(encodeURIComponent).join("/")}`, { method: "POST", headers: { apikey: SR, Authorization: `Bearer ${SR}`, "Content-Type": mime, "x-upsert": "false" }, body: new Blob([bytes], { type: mime }) });
  if (!r.ok) throw new Error(`storage ${r.status}: ${await r.text()}`);
}
async function storageFirmarVarios(rutas: string[], segundos = 3600): Promise<Record<string, string | null>> {   // una sola llamada para el informe
  const out: Record<string, string | null> = {};
  for (let i = 0; i < rutas.length; i += 500) {
    const lote = rutas.slice(i, i + 500);
    const r = await fetch(`${SURL}/storage/v1/object/sign/${BUCKET}`, { method: "POST", headers: DBH, body: JSON.stringify({ expiresIn: segundos, paths: lote }) });
    if (!r.ok) { for (const x of lote) out[x] = null; continue; }
    for (const s of await r.json()) out[s.path] = s.signedURL ? `${SURL}/storage/v1${s.signedURL}` : null;
  }
  return out;
}
function tipoPorBytes(b: Uint8Array): string | null {   // el mime declarado por el navegador no basta: se mira el contenido
  if (b.length > 8 && b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4E && b[3] === 0x47) return "image/png";
  if (b.length > 3 && b[0] === 0xFF && b[1] === 0xD8 && b[2] === 0xFF) return "image/jpeg";
  if (b.length > 6 && b[0] === 0x47 && b[1] === 0x49 && b[2] === 0x46 && b[3] === 0x38) return "image/gif";
  if (b.length > 12 && b[0] === 0x52 && b[1] === 0x49 && b[2] === 0x46 && b[3] === 0x46 && b[8] === 0x57 && b[9] === 0x45 && b[10] === 0x42 && b[11] === 0x50) return "image/webp";
  if (b.length > 5 && b[0] === 0x25 && b[1] === 0x50 && b[2] === 0x44 && b[3] === 0x46) return "application/pdf";
  return null;
}
async function storageFirmar(ruta: string, segundos = 3600): Promise<string> {
  const r = await fetch(`${SURL}/storage/v1/object/sign/${BUCKET}/${ruta.split("/").map(encodeURIComponent).join("/")}`, { method: "POST", headers: DBH, body: JSON.stringify({ expiresIn: segundos }) });
  if (!r.ok) throw new Error(`storage sign ${r.status}: ${await r.text()}`);
  const j = await r.json();
  return `${SURL}/storage/v1${j.signedURL}`;
}
const AUD_SELECT = "id,momento,orden,tienda,pais,celular,fecha_auditoria,fecha_gestion,descripcion,registrado_por,agent_id,agente:var_agente(nombre),tipo:var_error_tipo(id,nombre,color),adjuntos:var_auditoria_adjunto(id,ruta,nombre,mime,bytes,creado_en)";
function filaAud(e: any, nombres: Record<string, string>, conRuta = false) {
  return { id: e.id, momento: e.momento, orden: e.orden, tienda: e.tienda, pais: e.pais, celular: e.celular, fecha_auditoria: e.fecha_auditoria, fecha_gestion: e.fecha_gestion, descripcion: e.descripcion,
    agent_id: e.agent_id, agente: e.agente?.nombre || "", tipo: e.tipo ? { id: e.tipo.id, nombre: e.tipo.nombre, color: e.tipo.color } : null, registrado_por: nombres[e.registrado_por] || "",
    adjuntos: (e.adjuntos || []).map((a: any) => ({ id: a.id, nombre: a.nombre, mime: a.mime, bytes: a.bytes, creado_en: a.creado_en, ...(conRuta ? { ruta: a.ruta } : {}) })) };
}
async function nombresUsuarios(): Promise<Record<string, string>> {
  const out: Record<string, string> = {};
  try { for (const u of await getRows(`var_usuarios?select=auth_uid,nombre`)) out[u.auth_uid] = u.nombre; } catch (_) { /* sin nombres */ }
  return out;
}

async function origenes(): Promise<string[]> {
  try { const v = await cfg("variables_origins"); const a = JSON.parse(v || ""); if (Array.isArray(a) && a.length) return a.filter((x) => typeof x === "string"); } catch (_) { /* default */ }
  return DEFAULT_ORIGINS;
}
function corsHeaders(origin: string, allowed: string[]): Record<string, string> {
  const ok = allowed.includes(origin);
  return {
    "access-control-allow-origin": ok ? origin : allowed[0],
    "access-control-allow-headers": "authorization, apikey, content-type, x-client-info",
    "access-control-allow-methods": "GET, POST, OPTIONS",
    "vary": "origin",
  };
}

// ---------- identidad ----------
async function getUser(token: string): Promise<{ id: string; email?: string } | null> {
  if (!token || token === SR) return null;
  const r = await fetch(`${SURL}/auth/v1/user`, { headers: { apikey: SR, Authorization: `Bearer ${token}` } });
  if (!r.ok) return null;
  const u = await r.json();
  return u && typeof u.id === "string" && u.id ? u : null;   // la anon key no tiene "sub" → Auth responde 401
}
async function getUsuario(uid: string): Promise<Usuario | null> {
  const rows = await getRows(`var_usuarios?auth_uid=eq.${uid}&select=auth_uid,email,nombre,rol,activo,puede_configurar`);
  const u = rows[0];
  return u && u.activo ? u : null;
}

// ---------- proyección por lista blanca (equipo / auditoria) ----------
function proyectarMatriz(r: any): any {
  const cargo = (c: any) => ({
    cargo: c.cargo, medible: c.medible, dias: c.dias, gest: c.gest, conf: c.conf, canc: c.canc, reprog: c.reprog, horas: c.horas,
    efectividad_real: c.efectividad_real, efectividad_cumpl: c.efectividad_cumpl,
    cancelacion_real: c.cancelacion_real, cancelacion_cumpl: c.cancelacion_cumpl,
    ritmo: c.ritmo, compuerta: c.compuerta, general: c.general,
  });
  const dia = (d: any) => ({ fecha: d.fecha, estado: d.estado, turno: d.turno, gest: d.gest, conf: d.conf, canc: d.canc, reprog: d.reprog, horas: d.horas });
  const diaX = (x: any) => x ? ({ fecha: x.fecha, cargo: x.cargo, turno: x.turno, gest: x.gest, conf: x.conf, canc: x.canc, reprog: x.reprog, horas: x.horas,
    efectividad_real: x.efectividad_real, efectividad_cumpl: x.efectividad_cumpl, cancelacion_real: x.cancelacion_real, cancelacion_cumpl: x.cancelacion_cumpl,
    ritmo: x.ritmo, compuerta: x.compuerta, general: x.general, medible: x.medible }) : null;
  const aud = (a: any) => a ? ({ auditadas: a.auditadas, errores: a.errores, pct: a.pct, cumpl: a.cumpl }) : null;
  const lider = (l: any) => l ? ({ nombre: l.nombre, etiqueta: l.etiqueta }) : null;
  const metas: any = {};
  for (const k of Object.keys(r.metas || {})) metas[k] = { efectividad: r.metas[k].efectividad, cancelacion: r.metas[k].cancelacion, medible: r.metas[k].medible };
  const lideres: any = {};
  for (const k of Object.keys(r.lideres || {})) lideres[k] = lider(r.lideres[k]);
  const consolidar = (src: any) => {
    const out: any = {};
    for (const k of Object.keys(src || {})) {
      const c = src[k];
      out[k] = { gest: c.gest, conf: c.conf, canc: c.canc, efectividad_real: c.efectividad_real, efectividad_cumpl: c.efectividad_cumpl,
        cancelacion_real: c.cancelacion_real, cancelacion_cumpl: c.cancelacion_cumpl, ritmo: c.ritmo, compuerta: c.compuerta, general: c.general, lider: lider(c.lider) };
    }
    return out;
  };
  const cons = consolidar(r.consolidado);
  const consDia = consolidar(r.consolidado_dia);   // fila del líder en la tabla de Hoy / Día (012)
  return {
    mes: r.mes, hoy: r.hoy, desde: r.desde, hasta: r.hasta, dia: r.dia, estado: r.estado, compuerta_ritmo: r.compuerta_ritmo, auditoria_meta_pct: r.auditoria_meta_pct, asignaciones_hoy: r.asignaciones_hoy,
    metas, lideres,
    agentes: (r.agentes || []).map((a: any) => ({
      agent_id: a.agent_id, nombre: a.nombre, cargo_permanente: a.cargo_permanente, cargo_hoy: a.cargo_hoy, turno_hoy: a.turno_hoy, asignado_hasta: a.asignado_hasta,
      dia: diaX(a.dia), auditoria: aud(a.auditoria), errores: a.errores,
      cargos: (a.cargos || []).map(cargo), dias: (a.dias || []).map(dia),
    })),
    consolidado: cons, consolidado_dia: consDia,
    sin_asignar: (r.sin_asignar || []).map((s: any) => ({ agent_id: s.agent_id, fecha: s.fecha, gest: s.gest, estado: s.estado })),
  };
}

const MES_RE = /^\d{4}-(0[1-9]|1[0-2])$/;
const FECHA_RE = /^\d{4}-\d{2}-\d{2}$/;
const ESTADOS = new Set(["verificacion", "v_historica", "novedades", "agente_whatsapp", "apoyo", "ausencia", "incapacidad"]);
const PERMANENTES = ["verificacion", "v_historica", "novedades", "agente_whatsapp"];
const COLORES = new Set(["rojo", "amarillo", "verde"]);

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("origin") || "";
  const allowed = await origenes();
  const CORS = corsHeaders(origin, allowed);
  const json = (o: unknown, s = 200) => new Response(JSON.stringify(o), { status: s, headers: { ...CORS, "content-type": "application/json" } });
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });

  // 1) credencial
  const auth = req.headers.get("authorization") || "";
  const token = auth.toLowerCase().startsWith("bearer ") ? auth.slice(7).trim() : "";
  const user = await getUser(token);
  if (!user) return json({ error: "no autenticado" }, 401);
  const yo = await getUsuario(user.id);
  if (!yo) return json({ error: "sin acceso: pide a un administrador que active tu usuario" }, 403);

  // 2) acción
  let body: any = {};
  if (req.method === "POST") body = await req.json().catch(() => ({}));
  else { const u = new URL(req.url); u.searchParams.forEach((v, k) => { body[k] = v; }); }
  const action = String(body.action || "");
  const permitido = (...roles: Rol[]) => roles.includes(yo.rol);
  const negar = () => json({ error: "acción no permitida para tu rol" }, 403);
  const uid = yo.auth_uid;

  try {
    switch (action) {
      case "yo":
        return json({ ok: true, auth_uid: uid, nombre: yo.nombre, rol: yo.rol, email: yo.email, puede_configurar: yo.puede_configurar, hoy: (await rpc("var_hoy_col", {})) });

      case "matriz": {
        const mes = String(body.mes || "");
        if (!MES_RE.test(mes)) return json({ error: "mes inválido (YYYY-MM)" }, 400);
        const dia = typeof body.dia === "string" && FECHA_RE.test(body.dia) ? body.dia : null;
        const desde = typeof body.desde === "string" && FECHA_RE.test(body.desde) ? body.desde : null;   // filtro de fechas de la tabla mensual
        const hasta = typeof body.hasta === "string" && FECHA_RE.test(body.hasta) ? body.hasta : null;
        const r = await rpc("var_resumen_mes", { p_mes: `${mes}-01`, p_dia: dia, p_desde: desde, p_hasta: hasta });
        if (permitido("admin")) return json({ ok: true, ...r });
        const p = proyectarMatriz(r);
        const s = JSON.stringify(p);
        if (PROHIBIDO.test(s)) { console.error("proyeccion: palabra prohibida detectada; se responde 500 sin cuerpo"); return new Response(null, { status: 500, headers: CORS }); }
        return new Response(JSON.stringify({ ok: true, ...p }), { status: 200, headers: { ...CORS, "content-type": "application/json" } });
      }

      case "errores": {   // pop-up: errores de auditoría nuevos desde un id
        const desde = Number.isSafeInteger(Number(body.desde)) && Number(body.desde) >= 0 ? Number(body.desde) : 0;
        const rows = await getRows(`var_auditoria?id=gt.${desde}&anulado_por=is.null&select=id,momento,orden,tienda,pais,descripcion,agente:var_agente(nombre),tipo:var_error_tipo(nombre,color)&order=id.asc&limit=50`);
        return json({ ok: true, errores: rows.map((e: any) => ({ id: e.id, momento: e.momento, orden: e.orden, tienda: e.tienda, pais: e.pais, descripcion: e.descripcion, agente: e.agente?.nombre || "", tipo: e.tipo?.nombre || "", color: e.tipo?.color || "" })) });
      }

      case "ordenes": {         // el "ojo": órdenes gestionadas por un agente en un rango (todos los roles)
        const agent_id = String(body.agent_id || ""); const desde = String(body.desde || ""); const hasta = String(body.hasta || "");
        if (!agent_id || !FECHA_RE.test(desde) || !FECHA_RE.test(hasta) || desde > hasta) return json({ error: "datos inválidos" }, 400);
        const tienda = typeof body.tienda === "string" && body.tienda ? String(body.tienda).slice(0, 200) : null;
        const r = await rpc("var_ordenes_agente", { p_agent_id: agent_id, p_desde: desde, p_hasta: hasta, p_tienda: tienda });
        return json({ ok: true, agent_id, desde, hasta, tienda, total: r.total, conf: r.conf, canc: r.canc, reprog: r.reprog,
          ordenes: (r.ordenes || []).map((o: any) => ({ orden: o.orden, celular: o.celular, tipo: o.tipo, fecha: o.fecha, hora: o.hora, motivo: o.motivo, tienda: o.tienda })) });
      }
      case "tiendas_agentes": {  // pestañas Efectividad/Cancelación/Gestiones: enteros por agente × tienda (todos los roles)
        const desde = String(body.desde || ""); const hasta = String(body.hasta || "");
        if (!FECHA_RE.test(desde) || !FECHA_RE.test(hasta) || desde > hasta) return json({ error: "datos inválidos" }, 400);
        const agente = typeof body.agent_id === "string" && body.agent_id ? String(body.agent_id) : null;   // pop-up de un agente
        const r = await rpc("var_tiendas_agentes", { p_desde: desde, p_hasta: hasta, p_agent_id: agente });
        return json({ ok: true, desde, hasta, agentes: (r.agentes || []).map((a: any) => ({ agent_id: a.agent_id, nombre: a.nombre, cargo_permanente: a.cargo_permanente,
          total: { gest: a.total.gest, conf: a.total.conf, canc: a.total.canc, reprog: a.total.reprog },
          tiendas: (a.tiendas || []).map((t: any) => ({ tienda: t.tienda, gest: t.gest, conf: t.conf, canc: t.canc, reprog: t.reprog })) })) });
      }
      case "roster": {          // personas activas; con fecha, solo las que estaban en el equipo ese día (ingreso/salida)
        const fecha = typeof body.fecha === "string" && FECHA_RE.test(body.fecha) ? body.fecha : null;
        return json({ ok: true, agentes: await rpc("var_roster", { p_fecha: fecha, p_incluir_salidos: body.incluir_salidos === true }) });
      }
      case "tiendas_pais":      // países y tiendas del historial de gestiones (un país nuevo aparece solo)
        return json({ ok: true, paises: await rpc("var_tiendas_pais", {}) });

      case "tiendas":
        return json({ ok: true, tiendas: (await getRows(`v_tiendas?select=tienda&order=tienda.asc`)).map((t: any) => t.tienda) });

      case "asignaciones": {
        const fecha = String(body.fecha || "");
        if (!FECHA_RE.test(fecha)) return json({ error: "fecha inválida" }, 400);
        const rows = await getRows(`var_asignacion?vigente=is.true&fecha=eq.${fecha}&select=agent_id,turno,estado,es_na,lider_uid,lider:var_usuarios!var_asignacion_lider_uid_fkey(nombre)&order=agent_id.asc`);
        return json({ ok: true, fecha, asignaciones: rows.map((a: any) => ({ agent_id: a.agent_id, turno: a.turno, estado: a.estado, es_na: a.es_na, lider_uid: a.lider_uid, lider: a.lider?.nombre || "" })) });
      }

      case "asignar": {
        if (!permitido("equipo", "admin")) return negar();
        const fecha = String(body.fecha || "");
        const items = Array.isArray(body.items) ? body.items.slice(0, 200) : [];
        if (!FECHA_RE.test(fecha)) return json({ error: "fecha inválida" }, 400);
        if (!items.length) return json({ error: "sin agentes" }, 400);
        // Fechas anteriores a hoy: solo admin (inputs/13).
        const hoyCol = await rpc("var_hoy_col", {});
        if (fecha < hoyCol && !permitido("admin")) return json({ error: "solo un administrador puede modificar días anteriores" }, 403);
        // Tras el cierre de datos del mes solo escribe admin (diseño §5.6).
        const estado = await rpc("var_estado_mes", { p_mes: fecha.slice(0, 7) + "-01" });
        if (estado !== "abierto" && !permitido("admin")) return json({ error: `el mes está ${estado}: solo un administrador puede corregirlo` }, 403);
        // El líder firma SIEMPRE con su propio usuario; solo admin puede fijar otro (decisión 28, diseño §3.5).
        const lider = permitido("admin") && typeof body.lider_uid === "string" && body.lider_uid ? body.lider_uid : uid;
        const out: any[] = [];
        for (const it of items) {
          const agent_id = String(it.agent_id || ""); const turno = String(it.turno || body.turno || "");
          const esNa = it.estado === "" || it.estado === "na" || it.estado == null;
          const est = esNa ? "verificacion" : String(it.estado);   // con es_na el servidor usa el cargo permanente
          if (!agent_id || (!esNa && !ESTADOS.has(est))) { out.push({ agent_id, error: "estado inválido" }); continue; }
          if (turno !== "M" && turno !== "T") { out.push({ agent_id, error: "turno inválido" }); continue; }
          try { const id = await rpc("var_asignar", { p_fecha: fecha, p_agent_id: agent_id, p_turno: turno, p_estado: est, p_lider: lider, p_actor: uid, p_es_na: esNa }); out.push({ agent_id, id }); }
          catch (e: any) { out.push({ agent_id, error: e.message, conflicto: e.pg === "23505" }); }
        }
        const conflicto = out.some((o) => o.conflicto);
        return json({ ok: !out.some((o) => o.error), resultados: out }, conflicto ? 409 : 200);
      }

      case "orden_contacto": {  // celular/tienda/país de una orden ya traída a Supabase (auditoría y admin)
        if (!permitido("auditoria", "admin")) return negar();
        return json({ ok: true, ...(await rpc("var_orden_contacto", { p_orden: String(body.orden || "").trim() })) });
      }
      case "tipos_error": {     // catálogo del semáforo (auditoría, admin y equipo para el pop-up)
        const rows = await getRows(`var_error_tipo?activo=is.true&select=id,nombre,color,orden&order=orden.asc,nombre.asc`);
        return json({ ok: true, tipos: rows });
      }
      case "tipo_error_set": {  // nuevo tipo de error con su color; si ya existe con ese nombre, devuelve el existente
        if (!permitido("auditoria", "admin")) return negar();
        const nombre = String(body.nombre || "").trim(); const color = String(body.color || "");
        if (nombre.length < 3 || !COLORES.has(color)) return json({ error: "nombre (mínimo 3 letras) y color rojo/amarillo/verde" }, 400);
        const norm = await rpc("var_norm", { s: nombre });
        const ya = await getRows(`var_error_tipo?nombre_norm=eq.${encodeURIComponent(norm)}&select=id,nombre,color`);
        if (ya.length) return json({ ok: true, tipo: ya[0], existia: true });
        const maxo = await getRows(`var_error_tipo?select=orden&order=orden.desc&limit=1`);
        const row = await insert("var_error_tipo", { nombre, nombre_norm: norm, color, orden: (maxo[0]?.orden || 0) + 1, creado_por: uid });
        return json({ ok: true, tipo: { id: row?.[0]?.id, nombre, color }, existia: false });
      }
      case "registrar_error": { // orden con error (auditoría v2): fechas, país, tienda, celular obligatorio, tipo del semáforo
        if (!permitido("auditoria", "admin")) return negar();
        const agent_id = String(body.agent_id || ""); const descripcion = String(body.descripcion || "").trim();
        const orden = String(body.orden || "").trim(); const fa = String(body.fecha_auditoria || ""); const fg = String(body.fecha_gestion || "");
        if (!agent_id || descripcion.length < 3) return json({ error: "faltan agente o descripción" }, 400);
        if (!/^\d{1,15}$/.test(orden)) return json({ error: "número de orden inválido" }, 400);
        if (!FECHA_RE.test(fa) || !FECHA_RE.test(fg)) return json({ error: "faltan el día de auditoría o el día de gestión" }, 400);
        const hoyCol = await rpc("var_hoy_col", {});
        if (fa > hoyCol) return json({ error: "el día de auditoría no puede ser futuro" }, 400);
        if (fg > fa) return json({ error: "el día de gestión no puede ser posterior al de auditoría" }, 400);
        const tipo_id = Number(body.tipo_id);
        if (!Number.isInteger(tipo_id) || tipo_id <= 0) return json({ error: "elige el tipo de error" }, 400);
        const tipo = await getRows(`var_error_tipo?id=eq.${tipo_id}&activo=is.true&select=id`);
        if (!tipo.length) return json({ error: "tipo de error inválido" }, 400);
        // Celular: manda el que ya está en el sistema; si la orden no está, el auditor debe escribirlo.
        const contacto = await rpc("var_orden_contacto", { p_orden: orden });
        let celular: string | null = contacto?.celular || null;
        if (!celular) {   // solo se acepta un celular tecleado si el auditor lo escribió a propósito para ESTA orden (bandera explícita)
          const c = String(body.celular || "").replace(/\D/g, "");
          if (body.celular_manual !== true || c.length < 7 || c.length > 15) return json({ error: "la orden no está en el sistema: escribe el celular del cliente (7 a 15 dígitos)", pedir_celular: true }, 400);
          celular = c;
        }
        const dup = await getRows(`var_auditoria?agent_id=eq.${encodeURIComponent(agent_id)}&orden=eq.${encodeURIComponent(orden)}&tipo_id=eq.${tipo_id}&anulado_por=is.null&select=id,fecha_auditoria`);
        if (dup.length) return json({ error: `esa orden ya tiene registrado este tipo de error para el mismo agente (registro ${dup[0].id}, auditado el ${dup[0].fecha_auditoria}); si fue un error, anúlalo en la tabla de hoy` }, 409);
        const row = await insert("var_auditoria", { agent_id, orden: orden.slice(0, 60), tienda: body.tienda ? String(body.tienda).slice(0, 200) : (contacto?.tienda || null), pais: body.pais ? String(body.pais).slice(0, 60) : (contacto?.pais || null),
          celular, fecha_auditoria: fa, fecha_gestion: fg, tipo_id, descripcion: descripcion.slice(0, 2000), registrado_por: uid });
        return json({ ok: true, id: row?.[0]?.id, celular });
      }
      case "adjunto_subir": {   // evidencia (base64) → bucket privado + fila inmutable
        if (!permitido("auditoria", "admin")) return negar();
        const auditoria_id = Number(body.auditoria_id); const nombre = String(body.nombre || "archivo").slice(0, 120); const mime = String(body.mime || "");
        if (!Number.isInteger(auditoria_id) || auditoria_id <= 0) return json({ error: "registro inválido" }, 400);
        if (!MIME_OK.has(mime)) return json({ error: "solo imágenes (png, jpg, webp, gif) o PDF" }, 400);
        const aud = await getRows(`var_auditoria?id=eq.${auditoria_id}&anulado_por=is.null&select=id,fecha_auditoria`);
        if (!aud.length) return json({ error: "registro no encontrado" }, 404);
        const b64 = String(body.b64 || ""); if (!b64 || b64.length > MAX_BYTES * 1.4) return json({ error: "archivo vacío o mayor de 10 MB" }, 400);
        let bytes: Uint8Array; try { const bin = atob(b64); bytes = new Uint8Array(bin.length); for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i); } catch (_) { return json({ error: "archivo ilegible" }, 400); }
        if (!bytes.length || bytes.length > MAX_BYTES) return json({ error: "archivo vacío o mayor de 10 MB" }, 400);
        const real = tipoPorBytes(bytes);
        if (real !== mime) return json({ error: "el contenido del archivo no corresponde a una imagen png/jpg/webp/gif ni a un PDF" }, 400);
        const ruta = `${String(aud[0].fecha_auditoria).slice(0, 7)}/${auditoria_id}/${Date.now()}_${rutaSegura(nombre)}`;
        await storagePut(ruta, bytes, mime);
        const row = await insert("var_auditoria_adjunto", { auditoria_id, ruta, nombre, mime, bytes: bytes.length, subido_por: uid });
        return json({ ok: true, id: row?.[0]?.id, nombre, bytes: bytes.length });
      }
      case "adjunto_url": {     // enlace temporal (1 h) para ver una evidencia
        if (!permitido("auditoria", "admin")) return negar();
        const id = Number(body.id); if (!Number.isInteger(id) || id <= 0) return json({ error: "adjunto inválido" }, 400);
        const a = await getRows(`var_auditoria_adjunto?id=eq.${id}&select=id,ruta,nombre,mime,bytes`);
        if (!a.length) return json({ error: "adjunto no encontrado" }, 404);
        return json({ ok: true, id, nombre: a[0].nombre, mime: a[0].mime, bytes: a[0].bytes, url: await storageFirmar(a[0].ruta, 3600) });
      }
      case "errores_dia": {     // lo registrado en un día de auditoría (por defecto hoy): lo que el auditor lleva hecho
        if (!permitido("auditoria", "admin")) return negar();
        const fecha = typeof body.fecha === "string" && FECHA_RE.test(body.fecha) ? body.fecha : await rpc("var_hoy_col", {});
        const rows = await getRows(`var_auditoria?fecha_auditoria=eq.${fecha}&anulado_por=is.null&select=${AUD_SELECT}&order=momento.desc&limit=500`);
        const nombres = await nombresUsuarios();
        return json({ ok: true, fecha, errores: rows.map((e: any) => filaAud(e, nombres)) });
      }
      case "informe": {         // informe consolidado para el área legal: rango por día de auditoría, agentes opcionales, evidencias con enlace temporal
        if (!permitido("auditoria", "admin")) return negar();
        const desde = String(body.desde || ""); const hasta = String(body.hasta || "");
        if (!FECHA_RE.test(desde) || !FECHA_RE.test(hasta) || desde > hasta) return json({ error: "rango de fechas inválido" }, 400);
        const agentes = Array.isArray(body.agentes) ? body.agentes.map((x: any) => String(x)).filter((x: string) => /^[\w:.\-]{1,80}$/.test(x)).slice(0, 200) : [];
        const filtroAg = agentes.length ? `&agent_id=in.(${agentes.map((x: string) => `"${x}"`).join(",")})` : "";
        const rows = await getRows(`var_auditoria?fecha_auditoria=gte.${desde}&fecha_auditoria=lte.${hasta}&anulado_por=is.null${filtroAg}&select=${AUD_SELECT}&order=fecha_auditoria.asc,momento.asc&limit=2000`);
        const nombres = await nombresUsuarios();
        const filas = rows.map((e: any) => filaAud(e, nombres, true));
        const rutas: string[] = []; for (const f of filas) for (const a of f.adjuntos as any[]) rutas.push(a.ruta);
        const urls = rutas.length ? await storageFirmarVarios(rutas, 3600) : {};
        for (const f of filas) for (const a of f.adjuntos as any[]) { a.url = urls[a.ruta] ?? null; delete a.ruta; }
        return json({ ok: true, desde, hasta, agentes, generado_por: yo.nombre, truncado: rows.length >= 2000, errores: filas });
      }
      case "anular_error": {    // anulación con motivo (auditoría y admin): deja de contar; el registro y sus evidencias se conservan
        if (!permitido("auditoria", "admin")) return negar();
        const id = Number(body.id); const motivo = String(body.motivo || "").trim();
        if (!Number.isInteger(id) || id <= 0 || motivo.length < 3) return json({ error: "faltan el registro o el motivo" }, 400);
        await rpc("var_auditoria_anular", { p_id: id, p_motivo: motivo, p_actor: uid });
        return json({ ok: true });
      }
      case "personas_historico": { // nombres que Refresh trae (o que aparecen en gestiones) y aún no están en el equipo
        if (!permitido("equipo", "admin")) return negar();
        return json({ ok: true, personas: await rpc("var_personas_historico", {}) });
      }
      case "persona_agregar": { // alta de una persona (líderes y admin); el actor queda registrado
        if (!permitido("equipo", "admin")) return negar();
        const nombre = String(body.nombre || "").trim(); const cargo = String(body.cargo_permanente || "verificacion"); const apoyo = body.apoyo === true;
        const desde = typeof body.desde === "string" && FECHA_RE.test(body.desde) ? body.desde : await rpc("var_hoy_col", {});
        if (nombre.length < 3) return json({ error: "escribe el nombre completo" }, 400);
        if (!apoyo && !PERMANENTES.includes(cargo)) return json({ error: "cargo permanente inválido" }, 400);
        const agent_id = await rpc("var_persona_agregar", { p_nombre: nombre, p_cargo: cargo, p_desde: desde, p_apoyo: apoyo, p_actor: uid, p_es_admin: permitido("admin") });
        return json({ ok: true, agent_id });
      }
      case "persona_salida": {  // salida del equipo: fecha de salida, historial intacto
        if (!permitido("equipo", "admin")) return negar();
        const agent_id = String(body.agent_id || ""); const hasta = String(body.hasta || "");
        if (!agent_id || !FECHA_RE.test(hasta)) return json({ error: "faltan la persona o la fecha de salida" }, 400);
        await rpc("var_persona_salida", { p_agent_id: agent_id, p_hasta: hasta, p_actor: uid });
        return json({ ok: true });
      }

      case "auditadas_set": {   // total de órdenes auditadas por agente-mes (auditoría y admin)
        if (!permitido("auditoria", "admin")) return negar();
        const mes = String(body.mes || ""); const agent_id = String(body.agent_id || ""); const total = Number(body.total);
        if (!MES_RE.test(mes) || !agent_id || !Number.isInteger(total) || total < 0) return json({ error: "datos inválidos" }, 400);
        const id = await rpc("var_auditadas_set", { p_mes: `${mes}-01`, p_agent_id: agent_id, p_total: total, p_actor: uid });
        return json({ ok: true, id });
      }
      case "errores_mes": {     // listado de órdenes con error del mes (auditoría y admin)
        if (!permitido("auditoria", "admin")) return negar();
        const mes = String(body.mes || ""); if (!MES_RE.test(mes)) return json({ error: "mes inválido" }, 400);
        const d1 = new Date(new Date(`${mes}-01T00:00:00Z`).setUTCMonth(new Date(`${mes}-01T00:00:00Z`).getUTCMonth() + 1)).toISOString().slice(0, 10);
        const rows = await getRows(`var_auditoria?anulado_por=is.null&fecha_auditoria=gte.${mes}-01&fecha_auditoria=lt.${d1}&select=${AUD_SELECT}&order=fecha_auditoria.desc,momento.desc&limit=500`);
        const nombres = await nombresUsuarios();
        return json({ ok: true, errores: rows.map((e: any) => filaAud(e, nombres)) });
      }
      case "lideres_semana": {  // turno de cada líder por semana (lectura para todos)
        const desde = typeof body.desde === "string" && FECHA_RE.test(body.desde) ? body.desde : null;
        const rows = await getRows(`var_lider_semana?select=semana,lider_uid,turno,lider:var_usuarios!var_lider_semana_lider_uid_fkey(nombre,etiqueta)${desde ? `&semana=gte.${desde}` : ""}&order=semana.desc,turno.asc&limit=40`);
        const lideres = await getRows(`var_usuarios?activo=is.true&rol=in.(equipo,admin)&select=auth_uid,nombre,etiqueta,rol&order=nombre.asc`);
        return json({ ok: true, semanas: rows.map((r: any) => ({ semana: r.semana, lider_uid: r.lider_uid, turno: r.turno, nombre: r.lider?.nombre || "", etiqueta: r.lider?.etiqueta || "" })), lideres: lideres.filter((l: any) => l.rol === "equipo" || l.etiqueta) });
      }
      case "lider_semana_set": {
        if (!permitido("admin")) return negar();
        const semana = String(body.semana || ""); const lider_uid = String(body.lider_uid || ""); const turno = String(body.turno || "");
        if (!FECHA_RE.test(semana) || !/^[0-9a-f-]{36}$/i.test(lider_uid) || (turno !== "M" && turno !== "T")) return json({ error: "datos inválidos" }, 400);
        await insert("var_lider_semana", { semana, lider_uid, turno, creado_por: uid }, true);
        return json({ ok: true });
      }

      // ---------------- solo admin ----------------
      case "dinero": {          // monto estimado del mes por agente y líder — SOLO admin
        if (!permitido("admin")) return negar();
        const mes = String(body.mes || ""); if (!MES_RE.test(mes)) return json({ error: "mes inválido" }, 400);
        return json({ ok: true, ...(await rpc("var_calcular_mes", { p_mes: `${mes}-01` })) });
      }
      case "usuarios": {
        if (!permitido("admin")) return negar();
        const [auth, rows] = await Promise.all([rpc("var_auth_usuarios", {}), getRows(`var_usuarios?select=auth_uid,email,nombre,rol,activo,fecha_ingreso,puede_configurar,etiqueta&order=nombre.asc`)]);
        return json({ ok: true, auth, usuarios: rows });
      }
      case "usuario_set": {
        if (!permitido("admin")) return negar();
        const auth_uid = String(body.auth_uid || ""); const rol = String(body.rol || "");
        if (!/^[0-9a-f-]{36}$/i.test(auth_uid) || !["admin", "auditoria", "equipo"].includes(rol)) return json({ error: "datos inválidos" }, 400);
        const row = { auth_uid, email: String(body.email || "").toLowerCase(), nombre: String(body.nombre || "").trim() || String(body.email || ""), rol, activo: body.activo !== false,
          fecha_ingreso: body.fecha_ingreso && FECHA_RE.test(body.fecha_ingreso) ? body.fecha_ingreso : null, puede_configurar: body.puede_configurar === true, etiqueta: body.etiqueta ? String(body.etiqueta).slice(0, 40) : null, creado_por: uid };
        await insert("var_usuarios", row, true);
        // Cierre de sesión real al desactivar (diseño §3.3): bloqueo en Auth; al reactivar se levanta.
        await fetch(`${SURL}/auth/v1/admin/users/${auth_uid}`, { method: "PUT", headers: DBH, body: JSON.stringify({ ban_duration: row.activo ? "none" : "876600h" }) });
        return json({ ok: true });
      }
      case "agentes": {
        if (!permitido("admin")) return negar();
        const [roster, mapa, alias] = await Promise.all([
          getRows(`var_agente?select=agent_id,nombre,activo,desde,hasta,cargo_permanente,es_apoyo&order=nombre.asc`),
          getRows(`agent_map?select=id,name&order=name.asc&limit=2000`),
          getRows(`var_agente_alias?select=id,agent_id,nombre_norm,desde,hasta&order=agent_id.asc,desde.asc`),
        ]);
        const en = new Set(roster.map((r: any) => r.agent_id));
        const candidatos = mapa.filter((m: any) => !en.has(m.id) && m.name);
        return json({ ok: true, roster, candidatos, alias });
      }
      case "agente_set": {
        if (!permitido("admin")) return negar();
        const agent_id = String(body.agent_id || ""); const nombre = String(body.nombre || "").trim();
        if (!agent_id || !nombre) return json({ error: "faltan id o nombre" }, 400);
        const cp = PERMANENTES.includes(String(body.cargo_permanente)) ? String(body.cargo_permanente) : "verificacion";
        await insert("var_agente", { agent_id, nombre, activo: body.activo !== false, cargo_permanente: cp, desde: body.desde && FECHA_RE.test(body.desde) ? body.desde : null, hasta: body.hasta && FECHA_RE.test(body.hasta) ? body.hasta : null, creado_por: uid }, true);
        const norm = await rpc("var_norm", { s: nombre });
        const ya = await getRows(`var_agente_alias?agent_id=eq.${encodeURIComponent(agent_id)}&nombre_norm=eq.${encodeURIComponent(norm)}&select=id`);
        if (!ya.length) await insert("var_agente_alias", { agent_id, nombre_norm: norm, creado_por: uid });
        return json({ ok: true });
      }
      case "alias_set": {
        if (!permitido("admin")) return negar();
        const agent_id = String(body.agent_id || ""); const nombre = String(body.nombre || "").trim();
        if (!agent_id || !nombre) return json({ error: "faltan id o nombre" }, 400);
        const norm = await rpc("var_norm", { s: nombre });
        await insert("var_agente_alias", { agent_id, nombre_norm: norm, desde: body.desde && FECHA_RE.test(body.desde) ? body.desde : "2026-07-24", creado_por: uid });
        return json({ ok: true, nombre_norm: norm });
      }
      case "config_get": {
        if (!permitido("admin")) return negar();
        const mes = String(body.mes || ""); if (!MES_RE.test(mes)) return json({ error: "mes inválido" }, 400);
        return json({ ok: true, config: await rpc("var_config_vigente", { p_mes: `${mes}-01` }) });
      }
      case "config_set": {
        if (!permitido("admin") || !yo.puede_configurar) return json({ error: "solo quien tiene permiso de configuración" }, 403);
        const mes = String(body.mes || ""); if (!MES_RE.test(mes)) return json({ error: "mes inválido" }, 400);
        if (!body.config || typeof body.config !== "object") return json({ error: "config inválida" }, 400);
        const c = { ...body.config }; for (const k of Object.keys(c)) if (k.startsWith("_")) delete c[k];
        const version = await rpc("var_config_guardar", { p_mes: `${mes}-01`, p_config: c, p_motivo: body.motivo ? String(body.motivo) : null, p_actor: uid });
        return json({ ok: true, version });
      }
      default:
        return json({ error: "acción desconocida" }, 400);
    }
  } catch (e: any) {
    const pg = e?.pg || "";
    const status = pg === "23505" ? 409 : /^P00/.test(pg) || pg === "23514" || pg === "23503" ? 400 : 500;
    console.error("variables:", action, e?.message);
    return json({ error: e?.message || "error interno" }, status);
  }
});
