// ============================================================================
// Edge Function `variables` — Módulo de Variables (Sprint 1: sin dinero)
// DISENO_TECNICO_VARIABLES.md §2, §3.2, §3.5, §5.4
//  · Se despliega con verify_jwt = false en el gateway y valida ELLA MISMA el
//    token contra Auth (auth.getUser); el rol sale SOLO de var_usuarios.
//  · Negar por defecto: cada acción lista sus roles.
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
    ritmo: c.ritmo, compuerta: c.compuerta,
  });
  const dia = (d: any) => ({ fecha: d.fecha, estado: d.estado, turno: d.turno, gest: d.gest, conf: d.conf, canc: d.canc, reprog: d.reprog, horas: d.horas });
  const cons: any = {};
  for (const k of Object.keys(r.consolidado || {})) {
    const c = r.consolidado[k];
    cons[k] = { gest: c.gest, conf: c.conf, canc: c.canc, efectividad_real: c.efectividad_real, efectividad_cumpl: c.efectividad_cumpl,
      cancelacion_real: c.cancelacion_real, cancelacion_cumpl: c.cancelacion_cumpl, ritmo: c.ritmo, compuerta: c.compuerta };
  }
  return {
    mes: r.mes, hoy: r.hoy, hasta: r.hasta, estado: r.estado, compuerta_ritmo: r.compuerta_ritmo, asignaciones_hoy: r.asignaciones_hoy,
    agentes: (r.agentes || []).map((a: any) => ({
      agent_id: a.agent_id, nombre: a.nombre, cargo_hoy: a.cargo_hoy, turno_hoy: a.turno_hoy, asignado_hasta: a.asignado_hasta,
      en_vivo: a.en_vivo ? { ritmo: a.en_vivo.ritmo, gest: a.en_vivo.gest } : null,
      cargos: (a.cargos || []).map(cargo), dias: (a.dias || []).map(dia),
    })),
    consolidado: cons,
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
        return json({ ok: true, nombre: yo.nombre, rol: yo.rol, email: yo.email, puede_configurar: yo.puede_configurar, hoy: (await rpc("var_hoy_col", {})) });

      case "matriz": {
        const mes = String(body.mes || "");
        if (!MES_RE.test(mes)) return json({ error: "mes inválido (YYYY-MM)" }, 400);
        const r = await rpc("var_resumen_mes", { p_mes: `${mes}-01` });
        if (permitido("admin")) return json({ ok: true, ...r });
        const p = proyectarMatriz(r);
        const s = JSON.stringify(p);
        if (PROHIBIDO.test(s)) { console.error("proyeccion: palabra prohibida detectada; se responde 500 sin cuerpo"); return new Response(null, { status: 500, headers: CORS }); }
        return new Response(JSON.stringify({ ok: true, ...p }), { status: 200, headers: { ...CORS, "content-type": "application/json" } });
      }

      case "errores": {   // pop-up: errores de auditoría nuevos desde un id
        const desde = Number(body.desde || 0);
        const rows = await getRows(`var_auditoria?id=gt.${Number.isFinite(desde) ? desde : 0}&anulado_por=is.null&select=id,momento,tienda,producto,descripcion,agente:var_agente(nombre)&order=id.asc&limit=50`);
        return json({ ok: true, errores: rows.map((e: any) => ({ id: e.id, momento: e.momento, tienda: e.tienda, producto: e.producto, descripcion: e.descripcion, agente: e.agente?.nombre || "" })) });
      }

      case "roster":
        return json({ ok: true, agentes: await getRows(`var_agente?activo=is.true&select=agent_id,nombre&order=nombre.asc`) });

      case "tiendas":
        return json({ ok: true, tiendas: (await getRows(`v_tiendas?select=tienda&order=tienda.asc`)).map((t: any) => t.tienda) });

      case "asignaciones": {
        const fecha = String(body.fecha || "");
        if (!FECHA_RE.test(fecha)) return json({ error: "fecha inválida" }, 400);
        const rows = await getRows(`var_asignacion?vigente=is.true&fecha=eq.${fecha}&select=agent_id,turno,estado,lider_uid,lider:var_usuarios!var_asignacion_lider_uid_fkey(nombre)&order=agent_id.asc`);
        return json({ ok: true, fecha, asignaciones: rows.map((a: any) => ({ agent_id: a.agent_id, turno: a.turno, estado: a.estado, lider_uid: a.lider_uid, lider: a.lider?.nombre || "" })) });
      }

      case "asignar": {
        if (!permitido("equipo", "admin")) return negar();
        const fecha = String(body.fecha || ""); const turno = String(body.turno || "");
        const items = Array.isArray(body.items) ? body.items.slice(0, 200) : [];
        if (!FECHA_RE.test(fecha)) return json({ error: "fecha inválida" }, 400);
        if (turno !== "M" && turno !== "T") return json({ error: "turno inválido (M/T)" }, 400);
        if (!items.length) return json({ error: "sin agentes" }, 400);
        // Tras el cierre de datos del mes solo escribe admin (diseño §5.6).
        const estado = await rpc("var_estado_mes", { p_mes: fecha.slice(0, 7) + "-01" });
        if (estado !== "abierto" && !permitido("admin")) return json({ error: `el mes está ${estado}: solo un administrador puede corregirlo` }, 403);
        // El líder firma SIEMPRE con su propio usuario; solo admin puede fijar otro (decisión 28, diseño §3.5).
        const lider = permitido("admin") && typeof body.lider_uid === "string" && body.lider_uid ? body.lider_uid : uid;
        const out: any[] = [];
        for (const it of items) {
          const agent_id = String(it.agent_id || ""); const est = String(it.estado || "");
          if (!agent_id || !ESTADOS.has(est)) { out.push({ agent_id, error: "estado inválido" }); continue; }
          try { const id = await rpc("var_asignar", { p_fecha: fecha, p_agent_id: agent_id, p_turno: turno, p_estado: est, p_lider: lider, p_actor: uid }); out.push({ agent_id, id }); }
          catch (e: any) { out.push({ agent_id, error: e.message, conflicto: e.pg === "23505" }); }
        }
        const conflicto = out.some((o) => o.conflicto);
        return json({ ok: !out.some((o) => o.error), resultados: out }, conflicto ? 409 : 200);
      }

      case "registrar_error": {
        if (!permitido("auditoria", "admin")) return negar();
        const agent_id = String(body.agent_id || ""); const descripcion = String(body.descripcion || "").trim();
        if (!agent_id || descripcion.length < 3) return json({ error: "faltan agente o descripción" }, 400);
        const row = await insert("var_auditoria", { agent_id, tienda: body.tienda ? String(body.tienda).slice(0, 200) : null, producto: body.producto ? String(body.producto).slice(0, 200) : null, descripcion: descripcion.slice(0, 2000), registrado_por: uid });
        return json({ ok: true, id: row?.[0]?.id });
      }

      // ---------------- solo admin ----------------
      case "usuarios": {
        if (!permitido("admin")) return negar();
        const [auth, rows] = await Promise.all([rpc("var_auth_usuarios", {}), getRows(`var_usuarios?select=auth_uid,email,nombre,rol,activo,fecha_ingreso,puede_configurar&order=nombre.asc`)]);
        return json({ ok: true, auth, usuarios: rows });
      }
      case "usuario_set": {
        if (!permitido("admin")) return negar();
        const auth_uid = String(body.auth_uid || ""); const rol = String(body.rol || "");
        if (!/^[0-9a-f-]{36}$/i.test(auth_uid) || !["admin", "auditoria", "equipo"].includes(rol)) return json({ error: "datos inválidos" }, 400);
        const row = { auth_uid, email: String(body.email || "").toLowerCase(), nombre: String(body.nombre || "").trim() || String(body.email || ""), rol, activo: body.activo !== false,
          fecha_ingreso: body.fecha_ingreso && FECHA_RE.test(body.fecha_ingreso) ? body.fecha_ingreso : null, puede_configurar: body.puede_configurar === true, creado_por: uid };
        await insert("var_usuarios", row, true);
        // Cierre de sesión real al desactivar (diseño §3.3): bloqueo en Auth; al reactivar se levanta.
        await fetch(`${SURL}/auth/v1/admin/users/${auth_uid}`, { method: "PUT", headers: DBH, body: JSON.stringify({ ban_duration: row.activo ? "none" : "876600h" }) });
        return json({ ok: true });
      }
      case "agentes": {
        if (!permitido("admin")) return negar();
        const [roster, mapa, alias] = await Promise.all([
          getRows(`var_agente?select=agent_id,nombre,activo,desde,hasta&order=nombre.asc`),
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
        await insert("var_agente", { agent_id, nombre, activo: body.activo !== false, desde: body.desde && FECHA_RE.test(body.desde) ? body.desde : null, hasta: body.hasta && FECHA_RE.test(body.hasta) ? body.hasta : null, creado_por: uid }, true);
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
        if (!permitido("admin") || !yo.puede_configurar) return json({ error: "solo quien tiene permiso de configuración (L6)" }, 403);
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
