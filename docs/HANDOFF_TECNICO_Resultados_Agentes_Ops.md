# Handoff técnico — Dashboard "Resultados Agentes Ops"

**Fénix Ventures · Operación de llamadas (OPS)**
Documento para incorporar a un segundo colaborador. Pensado para que otra persona —desde su propio computador y su propia sesión de Claude— pueda entender, mantener y mejorar el proyecto.

> Nota de seguridad: este documento **no contiene** llaves secretas, contraseñas ni tokens. Solo indica **dónde viven** y **cómo obtenerlos**. Comparte los secretos por un canal aparte (gestor de contraseñas), nunca dentro de este archivo.

---

## 0. Qué es esto en una frase

Un tablero web que **reconstruye solo** las métricas de gestión de llamadas del equipo (por agente, día, media hora, país y tienda) leyendo la API interna de **Refresh**, sin llenado manual. Corre 100% en la nube (Supabase + GitHub Pages); no necesita ningún computador encendido.

La URL pública abre un login; adentro hay 4 vistas: **Resultados**, **Líder**, **Cierre** y un botón **Compacto**. El Líder incluye además el módulo **Handoff** (entrega de turno).

---

## 1. Accesos que necesita el nuevo colaborador (empezar por aquí)

Para poder **editar** hay que entrar a donde vive todo, que es un proyecto de **Supabase**. Todo el código (funciones y la plantilla HTML del tablero) y los datos están ahí.

| Qué | Dónde | Cómo dar acceso |
|---|---|---|
| **Supabase (lo principal)** | Proyecto `sbiyedqpqtiqvlgentci`, en la organización de Fénix Ventures | Karen (owner) invita al colaborador a la **organización/proyecto de Supabase** con rol Developer o Admin. Así obtiene: SQL Editor, Edge Functions, Table Editor y Logs. |
| **Claude del colaborador** | Su propia sesión de Claude | Debe **conectar el conector (MCP) de Supabase apuntando a la MISMA organización/proyecto**. Ver la advertencia de la sección 8: si se conecta a otra organización, todo da "no permission". |
| **GitHub (repositorio del proyecto)** | Repositorio `karenmalagon-star/resultados-agentes-ops` (GitHub Pages) | Agregar al colaborador como *collaborator* del repo. Contiene la **copia versionada** del proyecto: `index.html`, el código de las 7 Edge Functions, el esquema, los crons, la documentación y el script para exportar la plantilla (ver sección 2). |
| **Ver el tablero** | La URL pública de GitHub Pages | Compartir usuario y contraseña del login por canal seguro (ver sección 6). |

Con acceso a Supabase, el colaborador puede editar el 95% de la visual, porque **la plantilla del tablero vive en la base de datos** (tabla `assets`). El repositorio de GitHub es la **copia versionada** del proyecto (fuente de verdad para el código); Supabase es donde corre en vivo.

---

## 2. El repositorio versionado y cómo trabajar dos personas

El proyecto **ya está versionado** en un repositorio con esta estructura (subir el contenido del `.zip` entregado al repo de GitHub):

```
index.html                       Pagina de login (GitHub Pages).
dashboard/
  template.html                  Plantilla del tablero (se genera con pull-template.sh; vive en la BD).
  pull-template.sh               Exporta/sube la plantilla desde/hacia la tabla assets.
supabase/
  schema.sql                     Esquema de tablas + funcion check_login.
  cron.sql                       Tareas programadas (pg_cron). Reemplaza <WRITE_KEY> por el valor real.
  functions/<nombre>/index.ts    Codigo de cada Edge Function (Deno/TypeScript).
docs/                            Este handoff tecnico + la bitacora PROYECTO_memoria.txt.
README.md
```

**Detalle clave — la plantilla vive en la base de datos, no como archivo.** La visual del tablero
(HTML+CSS+JS) está en `public.assets` (`key='template'`). Para versionarla:

```bash
export SUPABASE_DB_URL='postgresql://postgres:...@db.sbiyedqpqtiqvlgentci.supabase.co:5432/postgres'
./dashboard/pull-template.sh          # baja la plantilla actual a dashboard/template.html
# editas dashboard/template.html y la subes de vuelta a la BD (ver comentario dentro del script)
```

**Cómo desplegar cambios a produccion:**
- **Edge Functions**: se editan en `supabase/functions/<nombre>/index.ts` y se despliegan a Supabase
  (Supabase CLI `supabase functions deploy <nombre>`, o pegando el codigo en el panel de Edge Functions).
- **Plantilla**: se edita `dashboard/template.html` y se sube a `assets` (script de arriba). El cambio
  se ve al recargar el tablero (no hay build).

**Para no pisarse (ambos editan el MISMO Supabase en vivo):**
- **Avisarse antes de desplegar** una función o de sobrescribir la plantilla. El último que guarda, gana.
- Antes de un cambio grande en la plantilla, **hacer un respaldo**: `select content from public.assets where key='template'` y guardarlo (o correr `pull-template.sh` y commitear).
- Mantener el repo al día: tras un cambio, **commitear** el `index.ts` o la `template.html` correspondiente para que Git refleje lo que hay en vivo.
- Cada quien trabaja desde **su propia sesión de Claude**, pero sobre el mismo Supabase. La sesión no se comparte; lo compartido es el proyecto Supabase.
- Este mismo documento y `docs/PROYECTO_memoria.txt` sirven de onboarding para la sesión de Claude del colaborador: conviene pegárselos al inicio.

---

## 3. Arquitectura general (la lógica con la que está construido)

Flujo de datos, de la fuente al navegador:

```
Refresh (API interna)  --->  Edge Functions (Supabase, Deno/TypeScript)  --->  Tablas Postgres
        ^                         (corren solas por cron cada 30 min / diario)      |
        | login + /orders/                                                          |
        |                                                                           v
   pg_cron dispara                                              panel_data / snapshot / assets
   las funciones                                                           |
                                                                           v
                              index.html (GitHub Pages)  --->  Edge Function `dashboard`
                                (login Basic Auth)              inyecta datos en la plantilla HTML
                                                                           |
                                                                           v
                                                          Navegador del líder (todo el render es JS)
```

Piezas:

1. **Refresh** es la fuente única. Es el backend que usa la propia interfaz de Refresh (no se lee de Drive ni de pantalla).
2. **Edge Functions** (TypeScript sobre Deno) hacen login a Refresh, descargan órdenes, calculan y guardan los resultados en tablas. Corren solas por **pg_cron**.
3. **Postgres** guarda: instantáneas, datos ya calculados por panel, historia permanente, y la **plantilla HTML** del tablero.
4. **`dashboard`** (Edge Function) valida el login y arma el HTML final: toma la plantilla de la tabla `assets` y le **inyecta los datos** (reemplaza los tokens `__DATA__`, `__LEADERDATA__`, `__COHORTDATA__`, `__CAPDATA__`, `__AB64__`).
5. **`index.html`** en GitHub Pages es solo la pantalla de login; al validar, hace `fetch` a `dashboard` y `document.write` del HTML recibido. Guarda la sesión 4 h en `localStorage`.
6. **Todo el render de gráficas y tablas ocurre en el navegador** (JavaScript dentro de la plantilla), usando Chart.js. El backend solo entrega datos.

Stack: Supabase (Postgres + Edge Functions Deno + pg_cron + pg_net), GitHub Pages, HTML/JavaScript, Chart.js y SheetJS (exportar a Excel). Construido con asistencia de IA.

---

## 4. Modelo de datos (tablas Postgres)

| Tabla | Para qué |
|---|---|
| `assets` | La **plantilla HTML** del tablero completo (fila `key='template'`, columna `content`). Aquí se edita casi toda la visual. |
| `snapshot` | Instantánea más reciente de Resultados (blob `data` con el modelo de eventos de ~5 días). |
| `panel_data` | Datos ya calculados por panel, una fila por `key`: `leader` (Líder), `cohort`/`cohortH` (Cierre), `histD` (Resultados con historia completa), `capacity` (Capacidad). Columna `data` (jsonb). |
| `events_history` | Historia permanente denormalizada de eventos (conf/canc/reprog) por agente/tienda/país/media hora. Se **acumula** cada 30 min. |
| `cohort_history` | Historia permanente del cierre (cohortes por día). |
| `panels_cache` | Caché de órdenes del último pull de `sync-panels` (se reemplaza en cada corrida). |
| `orders_cache` | Caché incremental de órdenes para `sync-refresh`. |
| `agent_map` | Mapa id->nombre de agentes. |
| `handoff` | Módulo de entrega de turno (pendientes). 18 columnas. |
| `handoff_ack` | Acuses de "Recibido por" del handoff. |
| `app_config` | Configuración y **secretos** (ver sección 6). Filas `key`/`value`. |
| `v_tiendas` (vista) | Lista de tiendas distintas (para el desplegable del Handoff). |

### Modelo de eventos (clave para entender los cálculos)

En `snapshot.data` y `panel_data.histD` cada **evento** es un arreglo posicional:

```
e = [ agentIdx, storeIdx, countryIdx, dateIdx, halfHour, type, reasonIdx, orderId ]
       0         1         2           3        4          5     6          7
```

- `type`: 0 = confirmada, 1 = cancelada, 2 = reprogramada.
- `halfHour`: 0..47 (media hora del día; hora = halfHour/2).
- `agents[]`, `dates[]`, `stores[]`, `countries[]`, `reasons[]` son los diccionarios; los índices del evento apuntan a esos arreglos.
- También hay `callCube[]` (llamadas por agente/día/media hora/país: `[agentIdx, dateIdx, halfHour, countryIdx, answered, duration, calls]`), `delayByAgent{}` y `delayAll[]` (delay = días entre el plazo Dropi y el 1er intento).

Regla de negocio importante: en `sync-refresh`, una cancelación con motivo **"Nueva orden"** se cuenta como **CONFIRMADA** (type 0). Se **excluyen** de canceladas los motivos "Nueva orden" y "Pedido de prueba".

---

## 5. Edge Functions y tareas programadas (la lógica que alimenta todo)

Funciones **de producción** (no tocar sin entender):

| Función | Qué hace | Cron (UTC; Colombia = UTC-5) |
|---|---|---|
| `sync-refresh` | Pull incremental de órdenes -> arma `snapshot` (Resultados). "Nueva orden" = confirmada. | `sync-refresh-30m`: cada 30 min |
| `sync-panels` | Pull para el panel **Líder**: carga por agente, alarmas de delay, sin asignar, y **reproceso** (pull amplio de 25 días). Escribe `panel_data.leader`. | `sync-panels-hourly`: cada hora al min 10 |
| `sync-cohort` | Cohorte de **Cierre** (efectividad de cierre por día). Escribe `panel_data.cohort`. | `sync-cohort-daily`: 12:00 UTC |
| `sync-capacity` | Capacidad operativa (agentes necesarios). Escribe `panel_data.capacity`. | `sync-capacity-daily`: 13:00 UTC |
| `build-history` | Une el último snapshot + toda la historia -> arma `histD` (Resultados) y `cohortH` (Cierre) con periodo completo. | `build-history-hourly`: min 10 y 40 (cada 30 min) |
| `dashboard` | Valida login (Basic Auth vía RPC `check_login`) y sirve el HTML con datos inyectados. | (a demanda, por request) |
| `handoff` | Lee/escribe el módulo de entrega de turno. Valida con el mismo login del dashboard; escribe con service role. | (a demanda) |

Además, dos crons **de SQL puro** (no funciones): `events-history-append` (cada 30 min, min 5 y 35) inserta en `events_history`; `cohort-history-append` (diario 12:30 UTC) inserta en `cohort_history`.

Cómo se disparan los crons: `pg_cron` ejecuta `net.http_post(...)` (pg_net) hacia la URL de la función, enviando el header `x-write-key` con el secreto compartido.

Funciones **de diagnóstico/pruebas** (legado, se pueden ignorar o borrar; NO son parte del pipeline): `ingest`, `probe`, `inspect`, `resumen-tiendas`, `probe-tienda`, `probe-endpoints`, `stores-list`, `sync-panels-diag`.

---

## 6. Accesos, llaves (API keys), webhooks — inventario

**No hay webhooks salientes ni integraciones externas.** Lo más parecido a un webhook son los crons internos que llaman a las Edge Functions con `x-write-key`.

Los secretos NO se listan con su valor aquí. Están en dos lugares:

**a) En la tabla `app_config`** (visible con acceso SQL al proyecto):

| `key` | Qué es | Sensible |
|---|---|---|
| `refresh_email` / `refresh_password` | Credenciales de login a la API de Refresh | Sí (alto) |
| `write_key` | Secreto compartido para disparar las funciones de sync (header `x-write-key`) | Sí (alto) |
| `auth_user` | Usuario del login del tablero | Medio |
| `auth_pw_hash` | Hash **bcrypt** de la contraseña del tablero (no reversible) | Medio |
| `calls_per_hour`, `ai_share`, `agentes_actuales`, `horas_agente` | Parámetros de la Capacidad (ajustables) | No |
| `last_sync`, `last_sync_panels`, `_resumen` | Estado interno / control | No |

**b) En las variables de entorno de las Edge Functions** (inyectadas por Supabase, se ven en Functions -> Secrets): `SUPABASE_URL` y `SUPABASE_SERVICE_ROLE_KEY` (la service role key da acceso total a la base; nunca exponerla en el navegador ni en el repo).

**Cómo cambiar la contraseña del tablero** (sin que nadie vea el texto): en el SQL Editor,
```sql
update public.app_config
set value = extensions.crypt('NUEVA_CONTRASENA', extensions.gen_salt('bf'))
where key = 'auth_pw_hash';
```

**API de Refresh** (fuente de datos):
- Base: `https://api-refresh.fenix-ventures.co/bff`
- Login: `POST /auth/sign-in` con `{email, password}` -> devuelve `token` (JWT). Se envía como `Authorization: Bearer <token>`.
- Órdenes: `POST /orders/` con filtros `{ refreshOrderStatusIds, dropiOrderStatusIds, dropiStoreIds, agentIds, startDate, endDate, startDateConfirmation, endDateConfirmation, startDateCancellation, endDateCancellation, limit, offset }`. Fechas en ISO 8601.
- Motivos de rechazo: `GET /rejection-reasons/`.
- Cada orden trae `refreshOrderStatus` (ASSIGNED/REPROGRAMMED/UNASSIGNED/CONFIRMED/CANCELLED...), `dropiOrderStatus` ("PENDIENTE CONFIRMACION", "ENTREGADO"...), `dropiStore`, `agent`, y `callHistory` = lista de `{date, callDuration, userId}`.
- Ojo de zona horaria: Refresh guarda la hora local de Colombia como si fuera UTC. Para leer la hora del día se usa `getUTCHours()` directo; para filtrar por fecha en la API se convierte UTC real -> Colombia (-5 h).

---

## 7. Qué calcula cada vista y cada gráfica

### 7.1 Resultados (pestaña principal)

Fuente: `histD` (historia completa) o, si aún no está, el `snapshot`. Se filtran los eventos con `filtEvents()` según fecha, hora, agente y país. Todo lo demás sale de `agg(eventos)`:

- `gest` = conf + canc + reprog (Total Gestiones)
- `efec` (Efectividad) = (conf + canc) / gest
- `cancPct` (% Cancelación) = canc / (conf + canc) — **excluye** "Nueva orden" y "Pedido de prueba"; se pinta en rojo desde 20 %
- `reprogPct` (% Reprogramadas) = reprog / gest

**KPIs de arriba:** Total Gest, **Gest/hora**, Efectividad, % Cancelación, % Reprogramadas, Confirmadas, Canceladas, Prom. llamada, Delay prom.

- **Gest/hora** (Opción C, decisión Karen 2026-08-27): promedio de la tasa por agente. La tasa de un agente = sus gestiones ÷ la **jornada programada** de los días en que tuvo actividad (Lun–Jue 7,5 h · Vie 6,5 h · Sáb y festivos 5,5 h · Dom 0 — configurable en `app_config.jornada` y `festivos_co`). El denominador es la jornada completa del día: los descansos no inflan el resultado y quien se ausenta sin gestionar baja su promedio. Benchmark de referencia: **38/h** (`gest_hora_meta`, configurable). Limitación conocida: asume jornada completa (no detecta ausencias de medio día).
- **Prom. llamada**: duración promedio de llamadas contestadas (del `callCube`).
- **Delay prom.** (Resultados): días **calendario** (con decimales, domingos incluidos) entre la creación de la orden (Fech. Dropi) y la gestión que la **definió** (confirmación o cancelación). ⚠️ No confundir con la **alarma de demora del Líder**, que es otra métrica: días **hábiles** (sin domingo) entre el plazo (Fech. Dropi + 1 día) y el **primer intento** de llamada.

**Tabla "Detalle por agente":** por agente muestra Total Gest, Gest/hora, Conf, Canc, Reprog, Efect, %Canc, %Reprog y Delay. La columna **Delay es ordenable** (clic en el encabezado alterna mayor->menor, menor->mayor, y vuelve al orden por Total Gest). El "ojito" abre el detalle de órdenes del agente.

**Gráficas (Chart.js):**
- `cAg` (barras): Efectividad % y % Cancelación por agente.
- `cHr` (barras): gestiones por media hora del día (suma de eventos por `halfHour`).
- `cDay` (barras apiladas): Conf / Canc / Reprog por fecha.
- `cRe` (barras horizontales): top 8 motivos de cancelación (cuenta de eventos type=1 por `reasonIdx`).

**Pestaña Tiendas:** KPIs por tienda + tabla (Tienda, Total Gest, Conf, Canc, Reprog, %Canc) con buscador, filtro por %Canc mínimo y orden. El detalle de tienda muestra motivos de cancelación y órdenes.

**Exportar a Excel** (SheetJS): botón general (hojas Agentes + Tiendas) y por detalle (agente/tienda).

### 7.2 Cierre (efectividad de cierre por día / cohorte)

Fuente: `cohortH` (o `cohort`). Para cada **día de creación** de las órdenes (cohorte) mide cuántas quedaron **definidas** (confirmadas o canceladas) frente a las que siguen **pendientes**, y cómo evoluciona por día de gestión. Una orden cuenta como **pendiente** solo si su `refreshOrderStatus` está en {ASSIGNED, REPROGRAMMED, UNASSIGNED} **y** su `dropiOrderStatus` = "pendiente confirmacion" (si cualquiera de los dos ya se resolvió —incluso por fuera de Refresh— se considera definida). Tiene filtros de fecha (inicio/fin) y de tienda.

### 7.3 Capacidad operativa

Fuente: `capacity`. Estima los agentes necesarios para hoy: `agentesNecesarios = workloadHumano / capacidadPorAgente`, donde `workloadHumano = (backlog + ingreso esperado) x (1 - ai_share)` y `capacidadPorAgente = calls_per_hour x horas_del_día`. Parámetros ajustables en `app_config`: `calls_per_hour`, `ai_share`, `agentes_actuales`; la jornada por día es **configurable** en `app_config` (clave `jornada`: Lun–Jue 7.5, Vie 6.5, Sáb 5.5, Dom 0, festivo 5.5) junto con el calendario `festivos_co` (festivos colombianos = jornada de sábado, decisión D5 2026-08-27).

### 7.4 Líder

Fuente: `panel_data.leader` (lo arma `sync-panels`, ventana de 5 días salvo el reproceso). KPIs: Pendientes por confirmar, Asignadas a agentes, Reprogramadas, Sin asignar. Sub-paneles en pestañas + filtro por Fecha Dropi (Desde/Hasta):

- **Carga por agente y tienda**: órdenes ASIGNADAS (Dropi pendiente confirmación) por agente, desglosable por tienda.
- **Órdenes con delay por tienda**: alarma; delay = días hábiles entre el plazo y el 1er intento.
- **Órdenes sin asignar por tienda**: pendientes que nunca tuvieron intento y sin agente.
- **Órdenes en reproceso**: pendientes con agente real (excluye Postfecha/Sin gestión/Reprogramadas Operación) llamadas en **2+ días distintos** y aún sin definir. Se calcula con un **segundo pull amplio de 25 días** (los reprocesos suelen tener más de 5 días, fuera de la ventana normal). Agrupadas por día de creación.

### 7.5 Handoff (entrega de turno) — dentro de Líder

Módulo de **escritura** (los líderes ingresan datos). Cada pendiente: autor, fecha, texto, categoría, tienda (desplegable), # orden, prioridad, estado (abierto/resuelto), marcas Informativa/Radar, escalado (Técnico/Tienda/Auditoría/SAC/Dropi/Otra), avances diarios y resolución (quién y en qué finalizó). Tiene: acuse "Recibido por", **alarma de 2+ días calendario** sin resolver, sección **Radar permanente** (no se cierra), **historial de resueltos** y **búsqueda por tienda**. Todo escribe vía la función `handoff` (autenticada) con service role; la **service role nunca** llega al navegador. ⚠️ Matiz de seguridad: la credencial **Basic del login** (usuario:contraseña en base64) sí se inyecta en el HTML servido (`__AB64__`) para que el Handoff pueda escribir — quien inspeccione la página estando logueado puede leerla. Como la contraseña es compartida, tratar el HTML como sensible. Mejora futura: autenticación por usuario/token.

---

## 8. Trampas conocidas y lecciones (para no repetir errores)

- **Conector de Claude en la organización correcta**: si la sesión de Claude conecta el MCP de Supabase a **otra** organización, TODAS las acciones dan "no permission" aunque el navegador funcione. Verificar que apunte a la organización de Fénix Ventures.
- **Reemplazo de tokens en `dashboard`**: nunca usar como token de reemplazo un texto que también sea el nombre de una variable en la plantilla. Pasó con `__AUTHB64__` (aparecía dos veces en la misma línea) y rompió todo el script -> Líder/Cierre/Compacto dejaron de funcionar. Por eso el token del valor se llama `__AB64__`.
- **`DELETE` en PostgREST**: rechaza un DELETE sin filtro, así que la tabla se acumulaba silenciosamente. Usar siempre un filtro (ej. `?created_date=gte.1900-01-01`).
- **Paginación de Refresh**: no cortar con `rows.length < limit` (puede devolver páginas parciales). Paginar con `limit 1000` hasta página vacía.
- **Validar el JS antes de desplegar**: como la plantilla es JS dentro de la BD, tras editarla conviene extraer la función tocada y correr `node --check`. Un error de sintaxis rompe todo el tablero.
- **Historia vs. ventana**: `histD`/`events_history` cubren todo el mes; `callCube`, `leader` y varias funciones solo cubren ~5 días. Al mezclar (dividir métricas del mes por horas de 5 días) se infla el resultado — pasó con Gest/hora.
- **Caché del navegador**: la función `dashboard` responde `cache-control: no-store`, pero conviene hacer `Ctrl+Shift+R` tras cambios; el botón "Actualizar" del Handoff solo refresca datos, no el diseño.

---

## 9. Cómo hacer un cambio típico

- **Editar la visual**: la plantilla está en `assets.content` (`key='template'`). Es HTML + CSS + JS en un solo texto. Editar con `update public.assets set content = replace(content, '<viejo>', '<nuevo>') where key='template'`, o reemplazando por posición. Validar con `node --check`. El cambio se ve al recargar (no hay build).
- **Editar un cálculo del backend**: modificar la Edge Function correspondiente (sección 5) y redesplegarla. Correr manualmente para probar: `select net.http_post(url:='https://sbiyedqpqtiqvlgentci.supabase.co/functions/v1/<funcion>?force=1', headers:=jsonb_build_object('Content-Type','application/json','x-write-key', (select value from app_config where key='write_key')), body:='{}'::jsonb);` y revisar el resultado en `net._http_response` o en la tabla destino.
- **Cambiar parámetros de Capacidad**: `update app_config set value='...' where key in ('calls_per_hour','ai_share','agentes_actuales')`.
- **Ver logs de una función**: en Supabase -> Edge Functions -> (función) -> Logs.

---

## 10. Referencias

- `PROYECTO_memoria.txt` — bitácora completa y cronológica de todo lo construido (fuente única de verdad, incluye cada decisión y corrección). Conviene leerla junto a este documento.
- Proyecto Supabase: `sbiyedqpqtiqvlgentci`.
- Repo del login: `karenmalagon-star/resultados-agentes-ops` (GitHub Pages).
