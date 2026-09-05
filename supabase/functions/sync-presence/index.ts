// sync-presence: muestrea cada ~5 min que agentes estan conectados en Refresh
// (GET /users/, campo isOnline) y acumula en agent_presence via presence_tick().
// Motivo (hallazgo D4, 2026-08-28): Refresh NO expone tiempo de conexion; este
// registro propio lo estima con precision ±5 min. SOLO recolecta: ninguna
// metrica lo usa aun. horas de un dia = muestras * 5 / 60.
// ?debug=1 devuelve la forma cruda de /users/ (para ajustar el mapeo si cambia).
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { isExcludedAgent } from "./rules.ts";

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

Deno.serve(async (req: Request) => {
  const wk = req.headers.get("x-write-key") || "";
  const stored = await cfg("write_key");
  if (!stored) return json({ error: "config no disponible (transitorio)" }, 503);
  if (wk !== stored) return json({ error: "unauthorized" }, 401);

  const url = new URL(req.url);
  const force = url.searchParams.get("force") === "1";
  const debug = url.searchParams.get("debug") === "1";

  // Gate horario: solo tiene sentido muestrear durante la operacion (6:00-22:00 Colombia).
  const col = new Date(Date.now() - 5 * 3600000);
  const colMin = col.getUTCHours() * 60 + col.getUTCMinutes();
  if (!force && !debug && (colMin < 360 || colMin >= 1320)) return json({ skip: "fuera de horario" });

  try {
    const email = await cfg("refresh_email"), password = await cfg("refresh_password");
    if (!email || !password) return json({ error: "faltan credenciales" }, 400);
    const lr = await fetch(`${REFRESH}/auth/sign-in`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ email, password }) });
    if (lr.status !== 200 && lr.status !== 201) return json({ error: "login fallo", status: lr.status }, 502);
    const lj: any = await lr.json();
    const token = lj.token || lj.accessToken || lj.access_token || (lj.data && (lj.data.token || lj.data.accessToken || lj.data.access_token));
    if (!token) return json({ error: "no token" }, 502);

    // /users/ exige paginacion numerica (verificado 2026-08-28: sin params responde 400)
    // y trae TODOS los usuarios (incluidos DROPSHIPPERS, duenos de tienda): se pagina
    // hasta pagina vacia y se filtra por rol de agente.
    const users: any[] = [];
    let of = 0;
    for (let pg = 0; pg < 20; pg++) {
      const ur = await fetch(`${REFRESH}/users/?limit=200&offset=${of}`, { headers: { Authorization: "Bearer " + token } });
      if (ur.status !== 200) { if (pg === 0) return json({ ok: false, error: "GET /users/ fallo (HTTP " + ur.status + ")" }, 502); break; }
      let uj: any = null;
      try { uj = JSON.parse(await ur.text()); } catch (_) { break; }
      const rows: any[] = Array.isArray(uj) ? uj : (Array.isArray(uj.users) ? uj.users : (Array.isArray(uj.data) ? uj.data : []));
      if (rows.length === 0) break;
      for (const u of rows) users.push(u);
      of += rows.length;
    }
    const roleOf = (u: any) => String((u && u.role && (u.role.type || u.role.name)) || "").toLowerCase();
    if (debug) {
      const roles: Record<string, number> = {};
      const onlinePorRol: Record<string, number> = {};
      for (const u of users) { const r0 = roleOf(u) || "(sin rol)"; roles[r0] = (roles[r0] || 0) + 1; if (u.isOnline === true) onlinePorRol[r0] = (onlinePorRol[r0] || 0) + 1; }
      return json({ debug: true, total_usuarios: users.length, roles, online_por_rol: onlinePorRol });
    }

    const online = users
      .filter((u: any) => u && u.isOnline === true)
      .filter((u: any) => roleOf(u).indexOf("agent") >= 0 || roleOf(u).indexOf("agente") >= 0)
      .map((u: any) => ({ id: String(u.id ?? u.userId ?? ""), name: ((u.name || "") + " " + (u.surname || "")).trim() || (u.fullName || u.email || "(sin nombre)") }))
      .filter((u: any) => u.id && !isExcludedAgent(u.name));

    const tr = await fetch(`${SURL}/rest/v1/rpc/presence_tick`, { method: "POST", headers: DBH, body: JSON.stringify({ p_agents: online }) });
    if (tr.status !== 200) return json({ ok: false, error: "presence_tick fallo (HTTP " + tr.status + ")", detalle: (await tr.text()).slice(0, 200) }, 500);
    const n = await tr.json();

    return json({ ok: true, usuarios_api: users.length, online_reales: online.length, registrados: n, agentes: online.map((u: any) => u.name) });
  } catch (e) { return json({ error: String(e) }, 500); }
});
