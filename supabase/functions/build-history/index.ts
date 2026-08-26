import "jsr:@supabase/functions-js/edge-runtime.d.ts";
const SURL=Deno.env.get("SUPABASE_URL")!;const SR=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;const DBH={apikey:SR,Authorization:`Bearer ${SR}`,"Content-Type":"application/json"} as Record<string,string>;const json=(o:unknown,s=200)=>new Response(JSON.stringify(o),{status:s,headers:{"content-type":"application/json"}});
async function cfg(k:string){for(let i=0;i<3;i++){try{const r=await fetch(`${SURL}/rest/v1/app_config?key=eq.${encodeURIComponent(k)}&select=value`,{headers:DBH});const j=await r.json();if(Array.isArray(j))return (j[0]&&j[0].value)||"";}catch(_){/* reintenta */}await new Promise((res)=>setTimeout(res,500));}return "";}
Deno.serve(async(req)=>{const wk=req.headers.get("x-write-key")||"";const stored=await cfg("write_key");if(!stored)return json({error:"config no disponible (transitorio)"},503);if(wk!==stored)return json({error:"unauthorized"},401);try{
 const sr=await fetch(`${SURL}/rest/v1/snapshot?select=data&order=created_at.desc&limit=1`,{headers:DBH});const sj:any=await sr.json();const snap:any=(sj&&sj[0]&&sj[0].data)||{};
 const rows:any[]=[];let off=0;for(let i=0;i<80;i++){const r=await fetch(`${SURL}/rest/v1/events_history?select=order_id,type,agent,store,country,ev_date,halfhour,reason&order=ev_date.asc&limit=1000&offset=${off}`,{headers:DBH});const j:any=await r.json();if(!Array.isArray(j)||j.length===0)break;for(const x of j)rows.push(x);if(j.length<1000)break;off+=1000;}
 const agents:string[]=[],ai:any={},dates:string[]=[],di:any={},countries:string[]=[],ci:any={},stores:string[]=[],si:any={},reasons:string[]=[],ri:any={};
 const AI=(n:string)=>{n=n||"(sin agente)";if(!(n in ai)){ai[n]=agents.length;agents.push(n);}return ai[n];};
 const DI=(d:string)=>{if(!(d in di)){di[d]=dates.length;dates.push(d);}return di[d];};
 const CI=(c:string)=>{c=c||"(sin pais)";if(!(c in ci)){ci[c]=countries.length;countries.push(c);}return ci[c];};
 const SI=(s:string)=>{s=s||"(sin tienda)";if(!(s in si)){si[s]=stores.length;stores.push(s);}return si[s];};
 const RI=(r:string)=>{if(!(r in ri)){ri[r]=reasons.length;reasons.push(r);}return ri[r];};
 const events:any[]=[];
 for(const x of rows){const ridx=(x.reason!=null&&x.reason!=="")?RI(x.reason):-1;events.push([AI(x.agent),SI(x.store),CI(x.country),DI(String(x.ev_date).slice(0,10)),x.halfhour,x.type,ridx,x.order_id]);}
 // reindexar callCube y delayByAgent (del snapshot) a los indices de histD
 const sAg=snap.agents||[],sDt=snap.dates||[],sCo=snap.countries||[];
 const callCube=(snap.callCube||[]).map((c:any)=>[AI(sAg[c[0]]||"(sin agente)"),DI(String(sDt[c[1]]||"").slice(0,10)),c[2],CI(sCo[c[3]]||"(sin pais)"),c[4],c[5],c[6]]);
 const delayByAgent:any={};for(const k in (snap.delayByAgent||{})){delayByAgent[AI(sAg[+k]||"(sin agente)")]=snap.delayByAgent[k];}
 const data={meta:{start:dates.length?dates[0]:"",end:dates.length?dates[dates.length-1]:"",orders:events.length,gen:new Date().toISOString(),hist:true},agents,dates,countries,stores,reasons,events,callCube,delayByAgent,delayAll:snap.delayAll||[0,0,0,0,0,0,0,0]};
 await fetch(`${SURL}/rest/v1/panel_data`,{method:"POST",headers:{...DBH,Prefer:"resolution=merge-duplicates,return=minimal"},body:JSON.stringify({key:"histD",data,updated_at:new Date().toISOString()})});
 const chr:any=await (await fetch(`${SURL}/rest/v1/cohort_history?select=dc,general,by_store&order=dc.asc`,{headers:DBH})).json();
 const chRows:any[]=Array.isArray(chr)?chr:[];
 const cgen=chRows.map((r:any)=>r.general).filter(Boolean).sort((a:any,b:any)=> a.dc<b.dc?1:-1);
 const smap:any={};
 for(const r of chRows){for(const se of (r.by_store||[])){const st=se.store;(smap[st]=smap[st]||{store:st,byDay:[]});for(const day of (se.byDay||[]))smap[st].byDay.push(day);}}
 const cByStore=Object.values(smap).map((x:any)=>{x.byDay.sort((a:any,b:any)=>a.dc<b.dc?1:-1);x.total=x.byDay.reduce((s:number,d:any)=>s+(d.entered||0),0);return x;}).sort((a:any,b:any)=>b.total-a.total);
 const cohortH={gen:new Date().toISOString(),start:cgen.length?cgen[cgen.length-1].dc:"",end:cgen.length?cgen[0].dc:"",maxOff:7,general:cgen,byStore:cByStore};
 await fetch(`${SURL}/rest/v1/panel_data`,{method:"POST",headers:{...DBH,Prefer:"resolution=merge-duplicates,return=minimal"},body:JSON.stringify({key:"cohortH",data:cohortH,updated_at:new Date().toISOString()})});
 return json({ok:true,eventos:events.length,dias:dates.length,callcube:callCube.length,agentes:agents.length,tiendas:stores.length,desde:data.meta.start,hasta:data.meta.end,cierre_dias:cgen.length});
}catch(e){return json({error:String(e)},500);}});
