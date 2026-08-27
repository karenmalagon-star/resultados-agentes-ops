import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const SURL = Deno.env.get("SUPABASE_URL")!;
const SR = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const DBH = { apikey: SR, Authorization: `Bearer ${SR}`, "Content-Type": "application/json" } as Record<string,string>;
const json = (o: unknown, s = 200) => new Response(JSON.stringify(o), { status: s, headers: { "content-type": "application/json" } });
async function cfg(key: string): Promise<string> {
  // Con reintento: un fallo transitorio leyendo app_config no debe confundirse con llave invalida.
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
async function getOne(path: string) { const r = await fetch(`${SURL}/rest/v1/${path}`, { headers: DBH }); const j = await r.json(); return (j && j[0]) || null; }

Deno.serve(async (req: Request) => {
  const wk = req.headers.get("x-write-key") || "";
  const stored = await cfg("write_key");
  if (!stored) return json({ error: "config no disponible (transitorio)" }, 503);
  if (wk !== stored) return json({ error: "unauthorized" }, 401);
  try {
    const snapRow = await getOne("snapshot?select=data&order=created_at.desc&limit=1");
    const cohRow = await getOne("panel_data?key=eq.cohort&select=data");
    const ldRow = await getOne("panel_data?key=eq.leader&select=data");
    const snap: any = (snapRow && snapRow.data) || {};
    const cohort: any = (cohRow && cohRow.data) || {};
    const leader: any = (ldRow && ldRow.data) || {};
    const nowISO = new Date().toISOString();
    const col = new Date(Date.now() - 5 * 3600000);
    const todayStr = col.toISOString().slice(0, 10);

    const callsPerHour = parseFloat(await cfg("calls_per_hour")) || 38;
    const aiRaw = parseFloat(await cfg("ai_share")); const aiShare = isNaN(aiRaw) ? 0.5 : aiRaw;
    const agentesActuales = parseInt(await cfg("agentes_actuales")) || 7;

    // Jornada del agente CONFIGURABLE (app_config 'jornada', decision C5/D5).
    // Festivos colombianos (app_config 'festivos_co') = jornada de sabado (5.5 h), decision D5.
    const wd = col.getUTCDay(); // 0=Dom..6=Sab
    let JORNADA: Record<string, number> = { "1": 7.5, "2": 7.5, "3": 7.5, "4": 7.5, "5": 6.5, "6": 5.5, "0": 0, "festivo": 5.5 };
    try { const pj = JSON.parse(await cfg("jornada")); if (pj && typeof pj === "object") JORNADA = { ...JORNADA, ...pj }; } catch (_) { /* usa defaults */ }
    let FESTIVOS: string[] = [];
    try { const pf = JSON.parse(await cfg("festivos_co")); if (Array.isArray(pf)) FESTIVOS = pf; } catch (_) { /* sin festivos */ }
    const esFestivo = FESTIVOS.includes(todayStr);
    const diaNombre = (["Domingo", "Lunes", "Martes", "Miercoles", "Jueves", "Viernes", "Sabado"][wd]) + (esFestivo ? " (festivo)" : "");
    // El dia OFF (jornada 0, p.ej. domingo) gana sobre el festivo; guardas contra NaN.
    const baseDia = +JORNADA[String(wd)] || 0;
    const horasAgente = baseDia === 0 ? 0 : (esFestivo ? (+JORNADA["festivo"] || 0) : baseDia);

    // horario operacion observado (informativo)
    const cube: any[] = snap.callCube || [];
    const byDay: Record<string, Set<number>> = {};
    for (const row of cube) { const d = row[1], h = Math.floor(row[2] / 2), calls = row[6]; if (calls > 0) { (byDay[d] = byDay[d] || new Set()).add(h); } }
    const starts: number[] = [], ends: number[] = [];
    for (const s of Object.values(byDay)) { const arr = [...s]; if (arr.length) { starts.push(Math.min(...arr)); ends.push(Math.max(...arr)); } }
    const avg = (a: number[]) => a.length ? a.reduce((s, x) => s + x, 0) / a.length : 0;
    const horaInicio = starts.length ? Math.round(avg(starts)) : 8;
    const horaFin = ends.length ? Math.round(avg(ends)) + 1 : 20;

    const gen: any[] = cohort.general || [];
    const full = gen.filter((d) => d.dc < todayStr);
    const inflowAvg = full.length ? Math.round(full.reduce((s, d) => s + (d.entered || 0), 0) / full.length) : 0;
    const backlog = leader.pendientes || 0;

    const workloadTotal = backlog + inflowAvg;
    const workloadHumano = Math.round(workloadTotal * (1 - aiShare));
    const capacidadPorAgente = Math.round(callsPerHour * horasAgente);
    const needed = capacidadPorAgente > 0 ? Math.ceil(workloadHumano / capacidadPorAgente) : 0;

    const capacity = { gen: nowISO, dia: diaNombre, esFestivo, callsPerHour, aiShare, horasAgente, horaInicio, horaFin, backlog, ingresoEsperado: inflowAvg, workloadTotal, workloadHumano, capacidadPorAgente, agentesActuales, agentesNecesarios: needed };
    await fetch(`${SURL}/rest/v1/panel_data`, { method: "POST", headers: { ...DBH, Prefer: "resolution=merge-duplicates,return=minimal" }, body: JSON.stringify({ key: "capacity", data: capacity, updated_at: nowISO }) });
    return json({ ok: true, ...capacity });
  } catch (e) { return json({ error: String(e) }, 500); }
});
