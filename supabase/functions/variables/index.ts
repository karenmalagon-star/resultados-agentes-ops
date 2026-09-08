// ============================================================================
// Edge Function `variables` — Módulo de Variables (Sprint 1 + maqueta aprobada + dinero para Admin)
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
const ESTADOS = new Set(["verificacion", "v_historica", "novedades", "apoyo", "ausencia", "incapacidad"]);

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
        const desde = Number(body.desde || 0);
        const rows = await getRows(`var_auditoria?id=gt.${Number.isFinite(desde) ? desde : 0}&anulado_por=is.null&select=id,momento,orden,tienda,producto,descripcion,agente:var_agente(nombre)&order=id.asc&limit=50`);
        return json({ ok: true, errores: rows.map((e: any) => ({ id: e.id, momento: e.momento, orden: e.orden, tienda: e.tienda, producto: e.producto, descripcion: e.descripcion, agente: e.agente?.nombre || "" })) });
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
      case "roster":
        return json({ ok: true, agentes: await getRows(`var_agente?activo=is.true&select=agent_id,nombre,cargo_permanente&order=nombre.asc`) });

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

      case "registrar_error": {
        if (!permitido("auditoria", "admin")) return negar();
        const agent_id = String(body.agent_id || ""); const descripcion = String(body.descripcion || "").trim();
        if (!agent_id || descripcion.length < 3) return json({ error: "faltan agente o descripción" }, 400);
        const row = await insert("var_auditoria", { agent_id, orden: body.orden ? String(body.orden).slice(0, 60) : null, tienda: body.tienda ? String(body.tienda).slice(0, 200) : null, producto: body.producto ? String(body.producto).slice(0, 200) : null, descripcion: descripcion.slice(0, 2000), registrado_por: uid });
        return json({ ok: true, id: row?.[0]?.id });
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
        const d0 = `${mes}-01T00:00:00-05:00`; const d1 = new Date(new Date(`${mes}-01T00:00:00Z`).setUTCMonth(new Date(`${mes}-01T00:00:00Z`).getUTCMonth() + 1)).toISOString().slice(0, 10) + "T00:00:00-05:00";
        const rows = await getRows(`var_auditoria?anulado_por=is.null&momento=gte.${encodeURIComponent(d0)}&momento=lt.${encodeURIComponent(d1)}&select=id,momento,orden,tienda,producto,descripcion,agent_id,agente:var_agente(nombre)&order=momento.desc&limit=500`);
        return json({ ok: true, errores: rows.map((e: any) => ({ id: e.id, momento: e.momento, orden: e.orden, tienda: e.tienda, producto: e.producto, descripcion: e.descripcion, agent_id: e.agent_id, agente: e.agente?.nombre || "" })) });
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
          getRows(`var_agente?select=agent_id,nombre,activo,desde,hasta,cargo_permanente&order=nombre.asc`),
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
        const cp = ["verificacion", "v_historica", "novedades"].includes(String(body.cargo_permanente)) ? String(body.cargo_permanente) : "verificacion";
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
