import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const SURL = Deno.env.get("SUPABASE_URL")!;
const SR = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const DBH = { apikey: SR, Authorization: `Bearer ${SR}`, "Content-Type": "application/json" } as Record<string,string>;
const REFRESH = "https://api-refresh.fenix-ventures.co/bff";
const json = (o: unknown, s = 200) => new Response(JSON.stringify(o), { status: s, headers: { "content-type": "application/json" } });

async function cfg(key: string): Promise<string> {
  const r = await fetch(`${SURL}/rest/v1/app_config?key=eq.${encodeURIComponent(key)}&select=value`, { headers: DBH });
  const j = await r.json();
  return (j && j[0] && j[0].value) || "";
}

Deno.serve(async (req: Request) => {
  const wk = req.headers.get("x-write-key") || "";
  const stored = await cfg("write_key");
  if (!stored || wk !== stored) return json({ error: "unauthorized" }, 401);

  const url = new URL(req.url);
  const force = url.searchParams.get("force") === "1";
  const col = new Date(Date.now() - 5 * 3600000);
  const colMin = col.getUTCHours() * 60 + col.getUTCMinutes();
  if (!force && (colMin < 360 || colMin >= 1320)) return json({ skip: "fuera de horario", colHora: col.getUTCHours() + ":" + col.getUTCMinutes() });

  try {
    const email = await cfg("refresh_email");
    const password = await cfg("refresh_password");
    if (!email || !password) return json({ error: "faltan refresh_email/refresh_password en app_config" }, 400);

    const lr = await fetch(`${REFRESH}/auth/sign-in`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ email, password }) });
    if (lr.status !== 200 && lr.status !== 201) return json({ error: "login fallo", status: lr.status, body: (await lr.text()).slice(0, 200) }, 401);
    const lj: any = await lr.json();
    const token = lj.token || lj.accessToken || lj.access_token || (lj.data && (lj.data.token || lj.data.accessToken || lj.data.access_token));
    if (!token) return json({ error: "no token en respuesta login", keys: Object.keys(lj || {}) }, 500);
    const H = { Authorization: "Bearer " + token, "Content-Type": "application/json" };

    const rj: any = await (await fetch(`${REFRESH}/rejection-reasons/`, { headers: H })).json();
    const RE: Record<string, string> = {};
    (rj.rejectionReasons || rj).forEach((x: any) => { RE[x.id] = x.name; });

    const p = (x: number) => String(x).padStart(2, "0");
    const dISO = (d: Date) => d.getUTCFullYear() + "-" + p(d.getUTCMonth() + 1) + "-" + p(d.getUTCDate()) + "T00:00:00.000Z";
    const S = dISO(new Date(Date.UTC(col.getUTCFullYear(), col.getUTCMonth(), col.getUTCDate() - 4)));
    const E = dISO(new Date(Date.UTC(col.getUTCFullYear(), col.getUTCMonth(), col.getUTCDate() + 1)));
    const S_date = S.slice(0, 10);
    const nowISO = new Date().toISOString();

    const last_sync = await cfg("last_sync");
    let confSince = S;
    if (last_sync) { const t = new Date(new Date(last_sync).getTime() - 15 * 60000 - 5 * 3600000); confSince = (+t > +new Date(S)) ? t.toISOString() : S; }

    const amRun: Record<string, string> = {};
    const CACHE_ROWS: any[] = [];
    // Errores HTTP de la API: se acumulan y se reportan (antes se tragaban en silencio).
    const PULL_ERR: string[] = [];
    async function pull(st: string[], extra: any) {
      let of = 0;
      // Paginacion robusta: recorrer hasta pagina vacia (NO cortar en pagina parcial).
      for (let pg = 0; pg < 40; pg++) {
        const b: any = { dropiStoreIds: [], dropiOrderStatusIds: [], refreshOrderStatusIds: st, agentIds: [], dropiOrderIds: [], limit: 1000, offset: of, startDate: S, endDate: E, ...extra };
        const r = await fetch(`${REFRESH}/orders/`, { method: "POST", headers: H, body: JSON.stringify(b) });
        if (r.status !== 200) { PULL_ERR.push(st.join(",") + " pg" + pg + " http" + r.status); return; }
        const j: any = await r.json();
        const rows = j.orders || [];
        if (rows.length === 0) break;
        for (const o of rows) {
          if (o.agent && o.agent.id) amRun[o.agent.id] = ((o.agent.name || "") + " " + (o.agent.surname || "")).trim();
          if (o.dropiOrderId == null) continue;
          const rec = { id: o.dropiOrderId, aname: o.agent ? ((o.agent.name || "") + " " + (o.agent.surname || "")).trim() : "(sin agente)", dc: o.dropiCreationDate, cf: o.confirmedAt, cx: o.cancelledAt, rid: o.rejection ? o.rejection.reasonId : null, co: (o.client && o.client.country) || o.country || "(sin pais)", st: o.dropiStore ? o.dropiStore.name : "(sin tienda)", ch: (o.callHistory || []).map((c: any) => [c.date, c.callDuration, c.userId]), rc: (o.reprogrammedCalls || []).filter((c: any) => c.clientUnreachable).map((c: any) => [c.date, c.agentId]) };
          const cd = o.dropiCreationDate ? String(o.dropiCreationDate).slice(0, 10) : S_date;
          CACHE_ROWS.push({ id: rec.id, status: st[0], rec, created_date: cd });
        }
        of += rows.length;
      }
    }
    await pull(["CONFIRMED"], { startDateConfirmation: confSince, endDateConfirmation: E });
    await pull(["CANCELLED"], { startDateCancellation: confSince, endDateCancellation: E });
    await pull(["REPROGRAMMED"], {});
    await pull(["ASSIGNED"], {});

    const cmap: any = {};
    for (const r of CACHE_ROWS) { if (r.id == null) continue; cmap[r.id] = r; }
    const urows = Object.values(cmap);
    for (let i = 0; i < urows.length; i += 800) {
      await fetch(`${SURL}/rest/v1/orders_cache`, { method: "POST", headers: { ...DBH, Prefer: "resolution=merge-duplicates,return=minimal" }, body: JSON.stringify(urows.slice(i, i + 800)) });
    }
    const amRows = Object.entries(amRun).map(([id, name]) => ({ id, name }));
    if (amRows.length) await fetch(`${SURL}/rest/v1/agent_map`, { method: "POST", headers: { ...DBH, Prefer: "resolution=merge-duplicates,return=minimal" }, body: JSON.stringify(amRows) });
    await fetch(`${SURL}/rest/v1/orders_cache?created_date=lt.${S_date}`, { method: "DELETE", headers: { ...DBH, Prefer: "return=minimal" } });
    await fetch(`${SURL}/rest/v1/app_config`, { method: "POST", headers: { ...DBH, Prefer: "resolution=merge-duplicates,return=minimal" }, body: JSON.stringify({ key: "last_sync", value: nowISO }) });

    const O: any[] = [];
    let off = 0;
    for (;;) {
      const r = await fetch(`${SURL}/rest/v1/orders_cache?select=rec&created_date=gte.${S_date}&limit=1000&offset=${off}`, { headers: DBH });
      const j: any = await r.json();
      if (!Array.isArray(j) || j.length === 0) break;
      for (const row of j) O.push(row.rec);
      if (j.length < 1000) break;
      off += 1000;
    }
    const AM: Record<string, string> = {};
    { const r = await fetch(`${SURL}/rest/v1/agent_map?select=id,name&limit=1000`, { headers: DBH }); const j: any = await r.json(); if (Array.isArray(j)) for (const a of j) AM[a.id] = a.name; }

    // ===== agregacion =====
    // 'Nueva orden' NO es cancelacion normal: la orden se reemplaza por una nueva que queda confirmada
    // (a veces sin confirmedAt, por eso el reemplazo no se contaba). Se cuenta la gestion 'Nueva orden'
    // como CONFIRMADA efectiva del agente que la trabajo (sube efectividad; no cuenta como cancelacion).
    // 'Pedido de prueba' sigue excluido por completo.
    const EXCL = new Set(["Nueva orden", "Pedido de prueba"]);
    const norm = (s: string) => (s || "").trim().replace(/\s+/g, " ").toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "");
    const EXAG = new Set(["postfecha fenix", "reprogramadas operacion", "sin gestion", "seguimiento historico"]);
    const isEx = (n: string) => EXAG.has(norm(n));
    const Sm = +new Date(S), Em = +new Date(E);
    const win = (t: any) => { const x = t ? +new Date(t) : NaN; return x >= Sm && x < Em; };
    const dstr = (t: any) => new Date(t).toISOString().slice(0, 10);
    const hh = (t: any) => { const d = new Date(t); return d.getUTCHours() * 2 + (d.getUTCMinutes() >= 30 ? 1 : 0); };
    const seen: Record<string, number> = {}; const OO: any[] = [];
    for (const o of O) { if (o.id != null && seen[o.id]) continue; if (o.id != null) seen[o.id] = 1; OO.push(o); }
    const agName = (id: any) => AM[id] || (id ? ("(agente " + String(id).slice(0, 6) + ")") : "(sin agente)");
    function resolveAgent(o: any, et2: any) { if (o.aname && o.aname !== "(sin agente)") return o.aname; let best: any = null, bd = -1; const et = +new Date(et2); (o.ch || []).forEach((c: any) => { const nm = AM[c[2]]; if (!nm) return; const dt = +new Date(c[0]); if (dt <= et + 60000 && dt > bd) { bd = dt; best = nm; } }); if (best) return best; for (const c of (o.ch || [])) if (AM[c[2]]) return AM[c[2]]; return "(sin agente)"; }
    const agents: string[] = [], ai: any = {}, dates: string[] = [], di: any = {}, countries: string[] = [], ci: any = {}, stores: string[] = [], si: any = {}, reasons: string[] = [], ri: any = {};
    const AI = (n: string) => { if (!(n in ai)) { ai[n] = agents.length; agents.push(n); } return ai[n]; };
    const DI = (d: string) => { if (!(d in di)) { di[d] = dates.length; dates.push(d); } return di[d]; };
    const CI = (c: string) => { if (!(c in ci)) { ci[c] = countries.length; countries.push(c); } return ci[c]; };
    const SI = (s: string) => { if (!(s in si)) { si[s] = stores.length; stores.push(s); } return si[s]; };
    const RI = (r: string) => { if (!(r in ri)) { ri[r] = reasons.length; reasons.push(r); } return ri[r]; };
    const events: any[] = []; const cQ: any = {};
    const cc = (a: number, d: number, h: number, c: number) => { const k = a + "|" + d + "|" + h + "|" + c; return cQ[k] || (cQ[k] = { a, d, h, c, ans: 0, dur: 0, calls: 0 }); };
    const dB: any = {}, dA = { s: 0, n: 0, b: [0, 0, 0, 0, 0, 0] };
    const dk = (a: number) => dB[a] || (dB[a] = { s: 0, n: 0, b: [0, 0, 0, 0, 0, 0] });
    function dl(a: number, ev: any, dc: any) { if (!dc) return; const dd = (+new Date(ev) - +new Date(dc)) / 86400000; if (dd < 0) return; const bi = Math.min(5, Math.floor(dd)); const D = dk(a); D.s += dd; D.n++; D.b[bi]++; dA.s += dd; dA.n++; dA.b[bi]++; }
    for (const o of OO) { const c = CI(o.co), st = SI(o.st);
      if (o.cf && win(o.cf)) { const an = resolveAgent(o, o.cf); if (!isEx(an)) { const a = AI(an); events.push([a, st, c, DI(dstr(o.cf)), hh(o.cf), 0, -1, o.id]); dl(a, o.cf, o.dc); } }
      if (o.cx && win(o.cx)) { const nm = o.rid && RE[o.rid]; if (nm === "Nueva orden") { const an = resolveAgent(o, o.cx); if (!isEx(an)) { const a = AI(an); events.push([a, st, c, DI(dstr(o.cx)), hh(o.cx), 0, -1, o.id]); dl(a, o.cx, o.dc); } } else if (!EXCL.has(nm)) { const an = resolveAgent(o, o.cx); if (!isEx(an)) { const a = AI(an); events.push([a, st, c, DI(dstr(o.cx)), hh(o.cx), 1, RI(nm || "(sin motivo)"), o.id]); dl(a, o.cx, o.dc); } } }
      for (const rc of o.rc) { if (win(rc[0])) { const an = agName(rc[1]); if (!isEx(an)) { events.push([AI(an), st, c, DI(dstr(rc[0])), hh(rc[0]), 2, -1, o.id]); } } }
      for (const ch of o.ch) { if (win(ch[0])) { const an = AM[ch[2]] || resolveAgent(o, ch[0]); if (!isEx(an)) { const a = AI(an); const C = cc(a, DI(dstr(ch[0])), hh(ch[0]), c); C.calls++; if (ch[1] > 0) { C.ans++; C.dur += ch[1]; } } } }
    }
    const callC = Object.values(cQ).map((x: any) => [x.a, x.d, x.h, x.c, x.ans, x.dur, x.calls]);
    const dba: any = {}; Object.entries(dB).forEach(([n, v]: any) => dba[n] = [+(v.s / v.n).toFixed(2), v.n, ...v.b]);
    const data = { meta: { start: S, end: E, orders: OO.length, gen: new Date().toISOString() }, agents, dates, countries, stores, reasons, events, callCube: callC, delayByAgent: dba, delayAll: [+(dA.s / dA.n).toFixed(2), dA.n, ...dA.b] };

    await fetch(`${SURL}/rest/v1/snapshot`, { method: "POST", headers: { ...DBH, Prefer: "return=minimal" }, body: JSON.stringify({ data }) });
    return json({ ok: PULL_ERR.length === 0, pull_err: PULL_ERR, cache: OO.length, nuevos: urows.length, eventos: events.length, agentes: agents.length, dias: dates });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
