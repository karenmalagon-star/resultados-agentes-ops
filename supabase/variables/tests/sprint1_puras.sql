-- Pruebas de funciones PURAS del Sprint 1 (solo lectura; se pueden correr en producción).
-- Cada fila debe dar ok = true. Ver DISENO_TECNICO_VARIABLES.md §8.
with cfg as (select public.var_config_default(date '2026-09-01') c)
select * from (values
  ('var_norm acentos/espacios',          public.var_norm('  Pendiente   Confirmación ') = 'pendiente confirmacion'),
  ('var_norm eñe',                       public.var_norm('Peña Núñez') = 'pena nunez'),
  ('excluido postfecha',                 public.var_es_excluido('Postfecha Colombia') = true),
  ('excluido sin gestion',               public.var_es_excluido('Sin Gestión') = true),
  ('no excluido agente real',            public.var_es_excluido('Agente Ficticio') = false),
  ('habil sabado',                       public.var_es_habil(date '2026-09-05') = true),
  ('no habil domingo',                   public.var_es_habil(date '2026-09-06') = false),
  ('dias habiles sep-2026 = 26',         public.var_dias_habiles(date '2026-09-01') = 26),
  ('horas M lunes 6,5',                  (select public.var_horas_efectivas(date '2026-09-07','M',c) from cfg) = 6.5),
  ('horas T viernes 6,5 (prueba 13)',    (select public.var_horas_efectivas(date '2026-09-04','T',c) from cfg) = 6.5),
  ('horas M viernes 5,5',                (select public.var_horas_efectivas(date '2026-09-04','M',c) from cfg) = 5.5),
  ('horas T sabado 5,5',                 (select public.var_horas_efectivas(date '2026-09-05','T',c) from cfg) = 5.5),
  ('horas festivo 12-oct M 4,5',         (select public.var_horas_efectivas(date '2026-10-12','M',c) from cfg) = 4.5),
  ('domingo 0 h aunque festivo (12)',    (select public.var_horas_efectivas(date '2026-09-06','M',c) from cfg) = 0),
  ('round half-up 110,05 → 110,1',       round(110.05::numeric, 1) = 110.1),
  ('una division 2201/2000 meta 100',    round(2201 * 10000::numeric / (2000 * 100), 1) = 110.1),
  ('round 89,95 → 90,0',                 round(89.95::numeric, 1) = 90.0),
  ('fin_revision = 7 del mes sig.',      (select c->>'fin_revision' from cfg) = '2026-10-07'),
  ('ritmo vivo L mañana 06:30→12:00 con break: 20 gest / 5 h = 4,0',
       public.var_ritmo_vivo(date '2026-09-07','M',13,20, timestamp '2026-09-07 12:00', (select c from cfg)) = 4.0),
  ('ritmo vivo primera hora → null',     public.var_ritmo_vivo(date '2026-09-07','M',13,5, timestamp '2026-09-07 07:15', (select c from cfg)) is null),
  ('ritmo vivo T L–J topa 21:00: 14:00→23:00 = 6,5 h',
       public.var_ritmo_vivo(date '2026-09-07','T',28,65, timestamp '2026-09-07 23:00', (select c from cfg)) = 10.0),
  ('estado mes futuro = abierto',        public.var_estado_mes(date '2026-12-01') = 'abierto'),
  ('estado mes pasado = en_revision',    public.var_estado_mes(date '2026-07-01') = 'en_revision')
) as t(prueba, ok);
