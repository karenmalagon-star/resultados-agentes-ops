// monitor-salud: vigila la salud del dashboard y avisa por correo cuando algo falla.
// Corre por cron cada 30 min (min 15 y 45). Chequea via RPC monitor_checks():
//   1) frescura del snapshot (Resultados), 2) frescura de cada panel, 3) corridas fallidas recientes.
// Si hay problemas, dispara el webhook de N8N (app_config: alert_webhook_url + alert_token),
// que envia el correo. Anti-spam: no repite la misma alerta antes de 4 horas; avisa cuando se normaliza.
// ?force=1 salta el gate horario; ?test=1 envia una alerta de PRUEBA.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const SURL = Deno.env.get("SUPABASE_URL")!;
const SR = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const DBH = { apikey: SR, Authorization: `Bearer ${SR}`, "Content-Type": "application/json" } as Record<string, string>;
const json = (o: unknown, s = 200) => new Response(JSON.stringify(o), { status: s, headers: { "content-type": "application/json" } });

async function cfg(key: string): Promise<string> {
  // Con reintento: un fallo transitorio leyendo config no debe tumbar el monitor.
  for (let i = 0; i < 2; i++) {
    try {
      const r = await fetch(`${SURL}/rest/v1/app_config?key=eq.${encodeURIComponent(key)}&select=value`, { headers: DBH });
      const j = await r.json();
      if (Array.isArray(j)) return (j[0] && j[0].value) || "";
    } catch (_) { /* reintenta */ }
    await new Promise((res) => setTimeout(res, 400));
  }
  return "";
}

async function setCfg(key: string, value: string) {
  await fetch(`${SURL}/rest/v1/app_config`, { method: "POST", headers: { ...DBH, Prefer: "resolution=merge-duplicates,return=minimal" }, body: JSON.stringify({ key, value }) });
}

Deno.serve(async (req: Request) => {
  const wk = req.headers.get("x-write-key") || "";
  const stored = await cfg("write_key");
  if (!stored || wk !== stored) return json({ error: "unauthorized" }, 401);

  const url = new URL(req.url);
  const force = url.searchParams.get("force") === "1";
  const test = url.searchParams.get("test") === "1";

  // Gate horario: los syncs corren 6:00-21:30 Colombia; el monitor evalua 7:45-22:00
  // (antes de las 7:45 los paneles diarios/horarios aun no han tenido su primera corrida).
  const col = new Date(Date.now() - 5 * 3600000);
  const colMin = col.getUTCHours() * 60 + col.getUTCMinutes();
  if (!force && !test && (colMin < 465 || colMin >= 1320)) {
    return json({ skip: "fuera de horario de monitoreo", colHora: col.getUTCHours() + ":" + String(col.getUTCMinutes()).padStart(2, "0") });
  }

  try {
    // 1) Obtener problemas
    let problemas: string[] = [];
    if (test) {
      problemas = ["PRUEBA del sistema de alertas — no hay ningún problema real. Si recibes este correo, las alertas del dashboard quedaron funcionando."];
    } else {
      const r = await fetch(`${SURL}/rest/v1/rpc/monitor_checks`, { method: "POST", headers: DBH, body: "{}" });
      if (r.status !== 200) return json({ error: "monitor_checks fallo", status: r.status, body: (await r.text()).slice(0, 200) }, 500);
      const j = await r.json();
      problemas = Array.isArray(j) ? j : [];
    }

    // 2) Anti-spam: estado de la ultima alerta en app_config ('monitor_state' = hash|iso)
    const hash = problemas.length ? btoa(unescape(encodeURIComponent(problemas.join("|")))).slice(0, 40) : "";
    const prev = await cfg("monitor_state");
    const [prevHash, prevAtISO] = prev ? prev.split("@@") : ["", ""];
    const horas4 = 4 * 3600000;
    const prevAt = prevAtISO ? +new Date(prevAtISO) : 0;

    const horaCol = to2(col.getUTCHours()) + ":" + to2(col.getUTCMinutes());
    function to2(x: number) { return String(x).padStart(2, "0"); }

    let enviado = false, motivo = "";
    if (problemas.length === 0) {
      if (prevHash) {
        // Se normalizo despues de una alerta: avisar una vez y limpiar estado
        enviado = await enviar(
          "✅ Dashboard Ops: todo volvió a la normalidad",
          `<p>Los problemas reportados antes ya <b>no</b> se detectan (revisión de las ${horaCol}, hora Colombia).</p><p>No hay que hacer nada.</p>`
        );
        if (enviado) await setCfg("monitor_state", "");
        motivo = "normalizado";
      } else {
        motivo = "sin problemas";
      }
    } else {
      const repetida = prevHash === hash && prevAt && (Date.now() - prevAt) < horas4;
      if (repetida && !test) {
        motivo = "misma alerta ya enviada hace menos de 4 h";
      } else {
        const lista = problemas.map((p) => `<li>${esc(p)}</li>`).join("");
        enviado = await enviar(
          (test ? "🧪 PRUEBA — " : "⚠️ ") + `Dashboard Ops: ${problemas.length} problema${problemas.length > 1 ? "s" : ""} detectado${problemas.length > 1 ? "s" : ""}`,
          `<p>El monitor del tablero <b>Resultados Agentes Ops</b> detectó (revisión de las ${horaCol}, hora Colombia):</p>` +
          `<ul>${lista}</ul>` +
          `<p><b>Qué hacer:</b> abrir el tablero y verificar la hora de \"Última actualización\". Si el problema persiste, revisar los Logs de las Edge Functions en Supabase (proyecto sbiyedqpqtiqvlgentci) o avisar a Daniel.</p>` +
          `<p style=\"color:#888;font-size:12px\">Este aviso se repite máximo cada 4 horas mientras el problema siga. Cuando se normalice, llegará un correo de confirmación.</p>`
        );
        if (enviado && !test) await setCfg("monitor_state", hash + "@@" + new Date().toISOString());
        motivo = test ? "prueba enviada" : "alerta enviada";
      }
    }

    return json({ ok: true, problemas, enviado, motivo });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }

  function esc(s: string) { return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"); }

  async function enviar(asunto: string, mensaje: string): Promise<boolean> {
    const whUrl = await cfg("alert_webhook_url");
    const token = await cfg("alert_token");
    if (!whUrl || !token) return false;
    try {
      const r = await fetch(whUrl, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ token, asunto, mensaje }) });
      return r.status >= 200 && r.status < 300;
    } catch (_) { return false; }
  }
});
