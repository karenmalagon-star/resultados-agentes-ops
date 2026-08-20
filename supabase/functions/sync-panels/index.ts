import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const SURL = Deno.env.get("SUPABASE_URL")!;
const SR = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const DBH = { apikey: SR, Authorization: `Bearer ${SR}`, "Content-Type": "application/json" } as Record<string,string>;
const REFRESH = "https://api-refresh.fenix-ventures.co/bff";
const json = (o: unknown, s = 200) => new Response(JSON.stringify(o), { status: s, headers: { "content-type": "application/json" } });
async function cfg(key: string): Promise<string> { const r = await fetch(`${SURL}/rest/v1/app_config?key=eq.${encodeURIComponent(key)}&select=value`, { headers: DBH }); const j = await r.json(); return (j && j[0] && j[0].value) || ""; }
const DAY = 86400000;
function gapNoSun(a: number, b: number): number { let n = 0; for (let d = a + 1; d <= b; d++) { if (new Date(d * DAY).getUTCDay() !== 0) n++; } return n; }
const norm = (s: string) => (s || "").trim().replace(/\s+/g, " ").toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "");

Deno.serve(async (req: Request) => {
  const wk = req.headers.get("x-write-key") || "";
  if (!wk || wk !== (await cfg("write_key"))) return json({ error: "unauthorized" }, 401);
  const url = new URL(req.url);
  const force = url.searchParams.get("force") === "1";
  const col = new Date(Date.now() - 5 * 3600000);
  const colMin = col.getUTCHours() * 60 + col.getUTCMinutes();
  if (!force && (colMin < 360 || colMin >= 1320)) return json({ skip: "fuera de horario" });

  try {
    const email = await cfg("refresh_email"), password = await cfg("refresh_password");
    if (!email || !password) return json({ error: "faltan credenciales" }, 400);
    const lr = await fetch(`${REFRESH}/auth/sign-in`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ email, password }) });
    if (lr.status !== 200 && lr.status !== 201) return json({ error: "login fallo", status: lr.status }, 401);
    const lj: any = await lr.json();
    const token = lj.token || lj.accessToken || lj.access_token || (lj.data && (lj.data.token || lj.data.accessToken || lj.data.access_token));
    if (!token) return json({ error: "no token" }, 500);
    const H = { Authorization: "Bearer " + token, "Content-Type": "application/json" };

    const p = (x: number) => String(x).padStart(2, "0");
    const dISO = (d: Date) => d.getUTCFullYear() + "-" + p(d.getUTCMonth() + 1) + "-" + p(d.getUTCDate()) + "T00:00:00.000Z";
    const S = dISO(new Date(Date.UTC(col.getUTCFullYear(), col.getUTCMonth(), col.getUTCDate() - 4)));
    const E = dISO(new Date(Date.UTC(col.getUTCFullYear(), col.getUTCMonth(), col.getUTCDate() + 1)));
    const S_date = S.slice(0, 10);
    const nowISO = new Date().toISOString();
    const tIdx = Math.floor((Date.now() - 5 * 3600000) / DAY);
    const dayIdx = (t: any) => Math.floor(+new Date(t) / DAY);
    const ymd = (idx: number) => new Date(idx * DAY).toISOString().slice(0, 10);

    const amRun: Record<string, string> = {};
    const O: any[] = [];
    let of = 0;
    for (let pg = 0; pg < 40; pg++) {
      const b: any = { dropiStoreIds: [], dropiOrderStatusIds: [], refreshOrderStatusIds: ["REPROGRAMMED", "ASSIGNED", "UNASSIGNED"], agentIds: [], dropiOrderIds: [], limit: 1000, offset: of, startDate: S, endDate: E };
      const r = await fetch(`${REFRESH}/orders/`, { method: "POST", headers: H, body: JSON.stringify(b) });
      if (r.status !== 200) break;
      const j: any = await r.json();
      const rows = j.orders || [];
      if (rows.length === 0) break;
      for (const o of rows) {
        if (o.agent && o.agent.id) amRun[o.agent.id] = ((o.agent.name || "") + " " + (o.agent.surname || "")).trim();
        if (o.dropiOrderId == null) continue;
        O.push({ id: o.dropiOrderId, an: o.agent ? ((o.agent.name || "") + " " + (o.agent.surname || "")).trim() : "(sin agente)", dc: o.dropiCreationDate, st: o.dropiStore ? o.dropiStore.name : "(sin tienda)", sa: o.dropiStore ? (o.dropiStore.isActive === true) : false, rs: o.refreshOrderStatus, ds: o.dropiOrderStatus || "", ch: (o.callHistory || []).map((c: any) => [c.date, c.callDuration, c.userId]) });
      }
      of += rows.length;
    }

    const rowsUp = O.map((o) => ({ id: o.id, rec: o, created_date: o.dc ? String(o.dc).slice(0, 10) : S_date }));
    await fetch(`${SURL}/rest/v1/panels_cache?created_date=gte.1900-01-01`, { method: "DELETE", headers: { ...DBH, Prefer: "return=minimal" } });
    for (let i = 0; i < rowsUp.length; i += 800) {
      await fetch(`${SURL}/rest/v1/panels_cache`, { method: "POST", headers: { ...DBH, Prefer: "resolution=merge-duplicates,return=minimal" }, body: JSON.stringify(rowsUp.slice(i, i + 800)) });
    }
    const amRows = Object.entries(amRun).map(([id, name]) => ({ id, name }));
    if (amRows.length) await fetch(`${SURL}/rest/v1/agent_map`, { method: "POST", headers: { ...DBH, Prefer: "resolution=merge-duplicates,return=minimal" }, body: JSON.stringify(amRows) });

    const EXAG = new Set(["postfecha fenix", "reprogramadas operacion", "sin gestion", "seguimiento historico"]);
    const isEx = (n: string) => { const x = norm(n); return EXAG.has(x) || x.indexOf("postfecha") >= 0 || x.indexOf("sin gestion") >= 0; };
    const isPC = (o: any) => norm(o.ds) === "pendiente confirmacion";
    const real = (o: any) => o.an && o.an !== "(sin agente)" && !isEx(o.an);

    const OF = O.filter((o) => isPC(o) && !isEx(o.an));

    const load: Record<string, Record<string, number>> = {};
    const asignadasRows: any[] = [];
    let nAsig = 0, nReprog = 0;
    for (const o of OF) {
      if (o.rs === "REPROGRAMMED" && real(o)) nReprog++;
      if (o.rs !== "ASSIGNED" || !real(o)) continue;
      (load[o.an] = load[o.an] || {})[o.st] = (load[o.an][o.st] || 0) + 1; nAsig++;
      asignadasRows.push({ agent: o.an, store: o.st, dc: o.dc ? String(o.dc).slice(0, 10) : null });
    }
    const loadArr = Object.entries(load).map(([agent, stores]) => { const st = Object.entries(stores).map(([store, count]) => ({ store, count })).sort((x, y) => y.count - x.count); const total = st.reduce((s, x) => s + x.count, 0); return { agent, total, stores: st }; }).sort((x, y) => y.total - x.total);

    const un: Record<string, { store: string; total: number; days: Record<string, number> }> = {};
    let nSin = 0;
    for (const o of OF) {
      if (o.rs !== "UNASSIGNED") continue;
      if ((o.ch || []).length > 0) continue;
      const g = un[o.st] || (un[o.st] = { store: o.st, total: 0, days: {} });
      const dd = o.dc ? String(o.dc).slice(0, 10) : "(s/f)";
      g.total++; g.days[dd] = (g.days[dd] || 0) + 1; nSin++;
    }
    const unArr = Object.values(un).map((g) => ({ store: g.store, total: g.total, days: Object.entries(g.days).map(([dc, count]) => ({ dc, count })).sort((a, b) => a.dc < b.dc ? -1 : 1) })).sort((a, b) => b.total - a.total);

    // ====== ALARMAS (ventana 5 dias) ======
    const byStore: Record<string, { store: string; delay: number; total: number; orders: any[] }> = {};
    let cDelay = 0, cGap = 0, cPend = 0;
    const tiendasDelay = new Set<string>();
    for (const o of OF) {
      if (o.rs !== "ASSIGNED" && o.rs !== "REPROGRAMMED") continue;
      if (!real(o) || !o.sa) continue;
      const cds = Array.from(new Set((o.ch || []).map((c: any) => dayIdx(c[0])))).sort((a: any, b: any) => a - b) as number[];
      const dcd = o.dc ? dayIdx(o.dc) : null; if (dcd == null) continue;
      let tipo = "", dias = 0, maxgap = 0;
      for (let i = 1; i < cds.length; i++) { const g = gapNoSun(cds[i - 1], cds[i]); if (g > maxgap) maxgap = g; }
      if (cds.length > 0 && gapNoSun(dcd, cds[0]) > 1) { tipo = "delay"; dias = gapNoSun(dcd, cds[0]) - 1; }
      else if (cds.length === 0 && gapNoSun(dcd, tIdx) > 1) { tipo = "delay"; dias = gapNoSun(dcd, tIdx) - 1; }
      if (!tipo && maxgap > 1) { tipo = "gap"; dias = maxgap - 1; }
      if (!tipo && cds.length > 0 && gapNoSun(cds[cds.length - 1], tIdx) > 1) { tipo = "pend_vencida"; dias = gapNoSun(cds[cds.length - 1], tIdx) - 1; }
      if (!tipo) continue;
      if (tipo === "delay") { cDelay++; tiendasDelay.add(o.st); } else if (tipo === "gap") cGap++; else cPend++;
      const g = byStore[o.st] || (byStore[o.st] = { store: o.st, delay: 0, total: 0, orders: [] });
      g.total++; if (tipo === "delay") g.delay++;
      if (g.orders.length < 300) g.orders.push({ id: o.id, agent: o.an, dc: o.dc ? String(o.dc).slice(0, 10) : null, primer: cds.length ? ymd(cds[0]) : null, tipo, dias, intentos: cds.length });
    }
    const byStoreArr = Object.values(byStore).map((g) => { g.orders.sort((a, b) => b.dias - a.dias); return g; }).sort((a, b) => (b.delay - a.delay) || (b.total - a.total));

    // ====== REPROCESO: pull amplio (25 dias), agrupado por dia de creacion, umbral 2+ dias de llamada distintos ======
    const rep: Record<string, { dia: string; count: number; orders: any[] }> = {};
    let repTotal = 0; let repScan = 0;
    try {
      const S2 = dISO(new Date(Date.UTC(col.getUTCFullYear(), col.getUTCMonth(), col.getUTCDate() - 25)));
      let of2 = 0;
      for (let pg = 0; pg < 30; pg++) {
        const b2: any = { dropiStoreIds: [], dropiOrderStatusIds: [], refreshOrderStatusIds: ["REPROGRAMMED", "ASSIGNED"], agentIds: [], dropiOrderIds: [], limit: 1000, offset: of2, startDate: S2, endDate: E };
        const r2 = await fetch(`${REFRESH}/orders/`, { method: "POST", headers: H, body: JSON.stringify(b2) });
        if (r2.status !== 200) break;
        const j2: any = await r2.json();
        const rows2 = j2.orders || [];
        if (rows2.length === 0) break;
        for (const o of rows2) {
          repScan++;
          if (o.dropiOrderId == null) continue;
          if (norm(o.dropiOrderStatus || "") !== "pendiente confirmacion") continue;
          const rs = o.refreshOrderStatus;
          if (rs !== "ASSIGNED" && rs !== "REPROGRAMMED") continue;
          const an = o.agent ? ((o.agent.name || "") + " " + (o.agent.surname || "")).trim() : "(sin agente)";
          if (!an || an === "(sin agente)" || isEx(an)) continue;
          const cds = Array.from(new Set((o.callHistory || []).map((c: any) => dayIdx(c.date)))).sort((a: any, b: any) => a - b) as number[];
          if (cds.length < 2) continue;
          const dia = o.dropiCreationDate ? String(o.dropiCreationDate).slice(0, 10) : "(s/f)";
          const st = o.dropiStore ? o.dropiStore.name : "(sin tienda)";
          repTotal++;
          const g = rep[dia] || (rep[dia] = { dia, count: 0, orders: [] });
          g.count++;
          if (g.orders.length < 500) g.orders.push({ id: o.dropiOrderId, agent: an, store: st, dias_llamado: cds.length, primer: ymd(cds[0]), ultimo: ymd(cds[cds.length - 1]) });
        }
        of2 += rows2.length;
      }
    } catch (_e) { /* reproceso best-effort */ }
    const repArr = Object.values(rep).map((g) => { g.orders.sort((a, b) => b.dias_llamado - a.dias_llamado); return g; }).sort((a, b) => a.dia < b.dia ? 1 : -1);

    const leader = { gen: nowISO, pendientes: OF.length, asignadas: nAsig, reprogramadas: nReprog, sin_asignar: nSin, load: loadArr, asignadasRows, unassigned: unArr, alarms: { resumen: { delay: cDelay, gap: cGap, pend_vencida: cPend, total: cDelay + cGap + cPend, tiendas_delay: tiendasDelay.size, ordenes_delay: cDelay }, byStore: byStoreArr }, reproceso: { total: repTotal, umbral: 2, byDay: repArr } };
    await fetch(`${SURL}/rest/v1/panel_data`, { method: "POST", headers: { ...DBH, Prefer: "resolution=merge-duplicates,return=minimal" }, body: JSON.stringify({ key: "leader", data: leader, updated_at: nowISO }) });

    return json({ ok: true, orders_pulled: O.length, pendientes_PC: OF.length, asignadas_ASSIGNED_PC: nAsig, asignadasRows: asignadasRows.length, reprogramadas_PC: nReprog, sin_asignar: nSin, reproceso_scan: repScan, reproceso_total: repTotal, reproceso_dias: repArr.length, alarmas: leader.alarms.resumen });
  } catch (e) { return json({ error: String(e) }, 500); }
});
