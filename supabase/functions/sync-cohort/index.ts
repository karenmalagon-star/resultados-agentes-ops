import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const SURL = Deno.env.get("SUPABASE_URL")!;
const SR = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const DBH = { apikey: SR, Authorization: `Bearer ${SR}`, "Content-Type": "application/json" } as Record<string,string>;
const REFRESH = "https://api-refresh.fenix-ventures.co/bff";
const json = (o: unknown, s = 200) => new Response(JSON.stringify(o), { status: s, headers: { "content-type": "application/json" } });
async function cfg(key: string): Promise<string> { const r = await fetch(`${SURL}/rest/v1/app_config?key=eq.${encodeURIComponent(key)}&select=value`, { headers: DBH }); const j = await r.json(); return (j && j[0] && j[0].value) || ""; }
const DAY = 86400000;
const norm = (s: string) => (s || "").trim().replace(/\s+/g, " ").toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "");

Deno.serve(async (req: Request) => {
  const wk = req.headers.get("x-write-key") || "";
  if (!wk || wk !== (await cfg("write_key"))) return json({ error: "unauthorized" }, 401);
  try {
    const email = await cfg("refresh_email"), password = await cfg("refresh_password");
    if (!email || !password) return json({ error: "faltan credenciales" }, 400);
    const lr = await fetch(`${REFRESH}/auth/sign-in`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ email, password }) });
    if (lr.status !== 200 && lr.status !== 201) return json({ error: "login fallo", status: lr.status }, 401);
    const lj: any = await lr.json();
    const token = lj.token || lj.accessToken || lj.access_token || (lj.data && (lj.data.token || lj.data.accessToken || lj.data.access_token));
    if (!token) return json({ error: "no token" }, 500);
    const H = { Authorization: "Bearer " + token, "Content-Type": "application/json" };

    const cold = new Date(Date.now() - 5 * 3600000);
    const p = (x: number) => String(x).padStart(2, "0");
    const dISO = (d: Date) => d.getUTCFullYear() + "-" + p(d.getUTCMonth() + 1) + "-" + p(d.getUTCDate()) + "T00:00:00.000Z";
    const S = dISO(new Date(Date.UTC(cold.getUTCFullYear(), cold.getUTCMonth(), cold.getUTCDate() - 4)));
    const E = dISO(new Date(Date.UTC(cold.getUTCFullYear(), cold.getUTCMonth(), cold.getUTCDate() + 1)));
    const nowISO = new Date().toISOString();
    const todayStr = cold.toISOString().slice(0, 10);
    const todayIdx = Math.floor((Date.now() - 5 * 3600000) / DAY);
    const dayIdx = (t: any) => Math.floor(+new Date(t) / DAY);
    const ymd = (idx: number) => new Date(idx * DAY).toISOString().slice(0, 10);

    const CONF = new Set(["CONFIRMED", "CONFIRMED_OUTSIDE_OF_APP"]);
    const CANC = new Set(["CANCELLED", "CANCELLED_OUTSIDE_OF_APP", "CANCELLED_AND_DELETED_IN_DROPI"]);
    const OUT = new Set(["CONFIRMED_OUTSIDE_OF_APP", "CANCELLED_OUTSIDE_OF_APP", "CANCELLED_AND_DELETED_IN_DROPI"]);
    const PENDRS = new Set(["ASSIGNED", "REPROGRAMMED", "UNASSIGNED"]);
    const EXHARD = new Set(["reprogramadas operacion", "sin gestion", "seguimiento historico"]);
    const MAXOFF = 7;
    const LIM = 1000;

    const O: any[] = [];
    // Errores HTTP de la API: se acumulan y se reportan (antes se tragaban en silencio).
    const PULL_ERR: string[] = [];
    let of = 0;
    // Paginacion robusta: recorrer hasta pagina vacia (NO cortar en pagina parcial).
    for (let pg = 0; pg < 40; pg++) {
      const b: any = { dropiStoreIds: [], dropiOrderStatusIds: [], refreshOrderStatusIds: [], agentIds: [], dropiOrderIds: [], limit: LIM, offset: of, startDate: S, endDate: E };
      const r = await fetch(`${REFRESH}/orders/`, { method: "POST", headers: H, body: JSON.stringify(b) });
      if (r.status !== 200) { PULL_ERR.push("pg" + pg + " http" + r.status); break; }
      const j: any = await r.json();
      const rows = j.orders || [];
      if (rows.length === 0) break;
      for (const o of rows) {
        if (o.dropiOrderId == null || !o.dropiCreationDate) continue;
        const dcd = dayIdx(o.dropiCreationDate);
        if (dcd > todayIdx) continue;
        const active = o.dropiStore ? (o.dropiStore.isActive === true) : false;
        if (!active) continue;
        const an = o.agent ? norm((o.agent.name || "") + " " + (o.agent.surname || "")) : "";
        if (an && EXHARD.has(an)) continue;
        const pf = an.indexOf("postfecha") >= 0;
        O.push({ dc: dcd, pf, rs: o.refreshOrderStatus, ds: norm(o.dropiOrderStatus || ""), cf: o.confirmedAt, cx: o.cancelledAt, calls: (o.callHistory || []).length, st: o.dropiStore ? o.dropiStore.name : "(sin tienda)" });
      }
      of += rows.length;
    }

    function mkBucket(dc: number) { return { dc: ymd(dc), dcIdx: dc, entered: 0, postfecha: 0, definidas: 0, definidasFuera: 0, pend: 0, pendLlam: 0, pendSin: 0, cierre: new Array(MAXOFF + 1).fill(0), sumOff: 0, nOff: 0 }; }
    function acc(bk: any, o: any) {
      bk.entered++;
      if (o.pf) { bk.postfecha++; return; }
      const pc = (o.ds === "pendiente confirmacion") && PENDRS.has(o.rs);
      if (pc) { bk.pend++; if (o.calls > 0) bk.pendLlam++; else bk.pendSin++; return; }
      bk.definidas++;
      const isConf = CONF.has(o.rs), isCanc = CANC.has(o.rs);
      if (OUT.has(o.rs)) bk.definidasFuera++;
      const rd = isConf ? o.cf : (isCanc ? o.cx : null);
      let off = rd ? (dayIdx(rd) - o.dc) : 0; if (off < 0) off = 0;
      bk.sumOff += off; bk.nOff++; bk.cierre[Math.min(MAXOFF, off)]++;
    }
    const gen: Record<string, any> = {};
    const byStore: Record<string, Record<string, any>> = {};
    for (const o of O) {
      const dk = String(o.dc);
      (gen[dk] = gen[dk] || mkBucket(o.dc)); acc(gen[dk], o);
      const sm = byStore[o.st] = byStore[o.st] || {};
      (sm[dk] = sm[dk] || mkBucket(o.dc)); acc(sm[dk], o);
    }
    function finalize(bk: any) {
      const base = bk.entered - bk.postfecha;
      bk.gestionables = base;
      bk.pct = base ? +(bk.definidas / base * 100).toFixed(1) : 0;
      bk.diasProm = bk.nOff ? +(bk.sumOff / bk.nOff).toFixed(1) : null;
      const age = todayIdx - bk.dcIdx;
      const cum: number[] = []; let s = 0;
      for (let i = 0; i <= MAXOFF; i++) { s += bk.cierre[i]; cum.push(i <= age ? (base ? +(s / base * 100).toFixed(1) : 0) : null as any); }
      bk.cierreAcum = cum; delete bk.sumOff; delete bk.nOff; delete bk.cierre; delete bk.dcIdx;
      return bk;
    }
    const genArr = Object.values(gen).map(finalize).filter((b: any) => b.dc <= todayStr).sort((a: any, b: any) => a.dc < b.dc ? 1 : -1);
    const storeArr = Object.entries(byStore).map(([store, days]) => ({ store, byDay: Object.values(days).map(finalize).filter((b: any) => b.dc <= todayStr).sort((a: any, b: any) => a.dc < b.dc ? 1 : -1), total: Object.values(days).reduce((s: number, x: any) => s + x.entered, 0) })).sort((a: any, b: any) => b.total - a.total);

    const cohort = { gen: nowISO, start: S.slice(0, 10), end: todayStr, maxOff: MAXOFF, general: genArr, byStore: storeArr };
    await fetch(`${SURL}/rest/v1/panel_data`, { method: "POST", headers: { ...DBH, Prefer: "resolution=merge-duplicates,return=minimal" }, body: JSON.stringify({ key: "cohort", data: cohort, updated_at: nowISO }) });
    return json({ ok: PULL_ERR.length === 0, pull_err: PULL_ERR, ordenes: O.length, dias: genArr.map((g: any) => ({ dc: g.dc, entered: g.entered, postfecha: g.postfecha, definidas: g.definidas, pct: g.pct, pend: g.pend, pendSin: g.pendSin, diasProm: g.diasProm })), tiendas: storeArr.length });
  } catch (e) { return json({ error: String(e) }, 500); }
});
