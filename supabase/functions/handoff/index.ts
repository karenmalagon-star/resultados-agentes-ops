import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const SURL = Deno.env.get("SUPABASE_URL")!;
const SR = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const DBH = { apikey: SR, Authorization: `Bearer ${SR}`, "Content-Type": "application/json" } as Record<string, string>;
const CORS = { "access-control-allow-origin": "*", "access-control-allow-headers": "authorization, content-type", "access-control-allow-methods": "GET, POST, OPTIONS" };
const json = (o: unknown, s = 200) => new Response(JSON.stringify(o), { status: s, headers: { ...CORS, "content-type": "application/json" } });

async function rpc(fn: string, body: unknown) {
  const r = await fetch(`${SURL}/rest/v1/rpc/${fn}`, { method: "POST", headers: DBH, body: JSON.stringify(body) });
  return await r.json();
}
async function pg(path: string, init?: RequestInit) {
  return await fetch(`${SURL}/rest/v1/${path}`, { ...(init || {}), headers: { ...DBH, ...(init && (init as any).headers ? (init as any).headers : {}) } });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
  const unauth = () => new Response(JSON.stringify({ error: "no autorizado" }), { status: 401, headers: { ...CORS, "content-type": "application/json", "WWW-Authenticate": 'Basic realm="Handoff"' } });
  const auth = req.headers.get("authorization") || "";
  if (!auth.toLowerCase().startsWith("basic ")) return unauth();
  let user = "", pass = "";
  try { const dec = atob(auth.slice(6)); const i = dec.indexOf(":"); user = dec.slice(0, i); pass = dec.slice(i + 1); } catch (_) { return unauth(); }
  let ok = false;
  try { ok = (await rpc("check_login", { u: user, p: pass })) === true; } catch (_) { ok = false; }
  if (!ok) return unauth();

  try {
    if (req.method === "GET") {
      const [ir, ar, tr] = await Promise.all([
        pg("handoff?select=*&order=created_at.desc"),
        pg("handoff_ack?select=*&order=at.desc&limit=30"),
        pg("v_tiendas?select=tienda&order=tienda.asc"),
      ]);
      const items = await ir.json();
      const acks = await ar.json();
      const trows = await tr.json();
      const tiendas = Array.isArray(trows) ? trows.map((x: any) => x.tienda).filter(Boolean) : [];
      return json({ ok: true, now: new Date().toISOString(), items, acks, tiendas });
    }

    if (req.method === "POST") {
      const body: any = await req.json().catch(() => ({}));
      const action = body.action;
      const nowISO = new Date().toISOString();

      if (action === "create") {
        const autor = (body.autor || "").toString().trim();
        const texto = (body.texto || "").toString().trim();
        if (!autor || !texto) return json({ error: "autor y texto son obligatorios" }, 400);
        const rec: any = {
          autor, texto,
          categoria: body.categoria ? String(body.categoria) : null,
          tienda: body.tienda ? String(body.tienda).trim() : null,
          orden: body.orden ? String(body.orden).trim() : null,
          prioridad: ["Alta", "Media", "Baja"].includes(body.prioridad) ? body.prioridad : "Media",
          informativa: body.informativa === true,
          es_radar: body.es_radar === true,
        };
        const r = await pg("handoff", { method: "POST", headers: { Prefer: "return=representation" }, body: JSON.stringify(rec) });
        const out = await r.json();
        return json({ ok: true, item: Array.isArray(out) ? out[0] : out });
      }

      const id = parseInt(body.id);
      if (action === "resolve") {
        if (!id) return json({ error: "id invalido" }, 400);
        const nota = (body.nota || "").toString().trim();
        const por = (body.resuelto_por || "").toString().trim();
        if (!nota || !por) return json({ error: "nota de cierre y nombre son obligatorios" }, 400);
        await pg(`handoff?id=eq.${id}`, { method: "PATCH", headers: { Prefer: "return=minimal" }, body: JSON.stringify({ estado: "resuelto", resuelto_nota: nota, resuelto_por: por, resuelto_at: nowISO, updated_at: nowISO }) });
        return json({ ok: true });
      }
      if (action === "reopen") {
        if (!id) return json({ error: "id invalido" }, 400);
        // "Nada se borra" (decision C6): antes de reabrir, la resolucion previa
        // se conserva como un avance en el historial de seguimiento.
        // Si la lectura falla NO se escribe nada: escribir con seg0 vacio borraria el historial.
        const r0 = await pg(`handoff?id=eq.${id}&select=seguimiento,resuelto_por,resuelto_nota,resuelto_at`);
        if (!r0.ok) return json({ error: "no pude leer la tarjeta, reintenta" }, 503);
        const rows0 = await r0.json();
        if (!Array.isArray(rows0)) return json({ error: "no pude leer la tarjeta, reintenta" }, 503);
        if (rows0.length === 0) return json({ error: "la tarjeta no existe" }, 404);
        const prev = rows0[0];
        const seg0 = Array.isArray(prev.seguimiento) ? prev.seguimiento : [];
        if (prev.resuelto_por || prev.resuelto_nota) {
          let fecha = "";
          try { if (prev.resuelto_at) { const dcol = new Date(new Date(prev.resuelto_at).getTime() - 5 * 3600000); fecha = " (" + dcol.toISOString().slice(0, 16).replace("T", " ") + " hora Colombia)"; } } catch (_) { fecha = ""; }
          seg0.push({ at: nowISO, autor: prev.resuelto_por || "(sin nombre)", nota: "[REAPERTURA] Resolución previa" + fecha + ": " + (prev.resuelto_nota || "") });
        }
        await pg(`handoff?id=eq.${id}`, { method: "PATCH", headers: { Prefer: "return=minimal" }, body: JSON.stringify({ estado: "abierto", resuelto_nota: null, resuelto_por: null, resuelto_at: null, seguimiento: seg0, updated_at: nowISO }) });
        return json({ ok: true });
      }
      if (action === "escalate") {
        if (!id) return json({ error: "id invalido" }, 400);
        const area = (body.area || "").toString().trim();
        await pg(`handoff?id=eq.${id}`, { method: "PATCH", headers: { Prefer: "return=minimal" }, body: JSON.stringify({ escalado: area.length > 0, escalado_area: area.length > 0 ? area : null, updated_at: nowISO }) });
        return json({ ok: true });
      }
      if (action === "flag") {
        if (!id) return json({ error: "id invalido" }, 400);
        const field = body.field;
        if (field !== "informativa" && field !== "es_radar") return json({ error: "campo invalido" }, 400);
        const patch: any = { updated_at: nowISO }; patch[field] = body.val === true;
        await pg(`handoff?id=eq.${id}`, { method: "PATCH", headers: { Prefer: "return=minimal" }, body: JSON.stringify(patch) });
        return json({ ok: true });
      }
      if (action === "progress") {
        if (!id) return json({ error: "id invalido" }, 400);
        const autor = (body.autor || "").toString().trim();
        const nota = (body.nota || "").toString().trim();
        if (!autor || !nota) return json({ error: "autor y nota son obligatorios" }, 400);
        const r = await pg(`handoff?id=eq.${id}&select=seguimiento`);
        const rows = await r.json();
        const seg = Array.isArray(rows) && rows[0] && Array.isArray(rows[0].seguimiento) ? rows[0].seguimiento : [];
        seg.push({ at: nowISO, autor, nota });
        await pg(`handoff?id=eq.${id}`, { method: "PATCH", headers: { Prefer: "return=minimal" }, body: JSON.stringify({ seguimiento: seg, updated_at: nowISO }) });
        return json({ ok: true });
      }
      if (action === "ack") {
        const por = (body.recibido_por || "").toString().trim();
        if (!por) return json({ error: "nombre obligatorio" }, 400);
        await pg("handoff_ack", { method: "POST", headers: { Prefer: "return=minimal" }, body: JSON.stringify({ recibido_por: por, nota: body.nota ? String(body.nota) : null }) });
        return json({ ok: true });
      }
      return json({ error: "accion desconocida" }, 400);
    }

    return json({ error: "metodo no soportado" }, 405);
  } catch (e) { return json({ error: String(e) }, 500); }
});
