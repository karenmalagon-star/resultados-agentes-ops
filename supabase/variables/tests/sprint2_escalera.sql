-- Pruebas de la escalera y del prorrateo (solo lectura). Todas deben dar ok = true.
select * from (values
  ('110,1 → 150 %',              public.var_escalera(110.1) = 1.5),
  ('110,0 → 110 %',              public.var_escalera(110.0) = 1.10),
  ('105,0 → 105 %',              public.var_escalera(105.0) = 1.05),
  ('103,7 → 103 % (trunca)',     public.var_escalera(103.7) = 1.03),
  ('100,0 → 100 %',              public.var_escalera(100.0) = 1.00),
  ('99,9 → 95 %',                public.var_escalera(99.9) = 0.95),
  ('95,0 → 95 %',                public.var_escalera(95.0) = 0.95),
  ('94,9 → 80 %',                public.var_escalera(94.9) = 0.80),
  ('90,0 → 80 %',                public.var_escalera(90.0) = 0.80),
  ('89,9 → 0',                   public.var_escalera(89.9) = 0),
  ('150 (tope) → 150 %',         public.var_escalera(150.0) = 1.5),
  ('null → null',                public.var_escalera(null) is null),
  ('K1: 24 de 26 días al 100 % → 92.308', round(100000 * (24::numeric / 26) * 1.0, 0) = 92308),
  ('techo: 1,5·50 + 1,5·35 + 1·15 = 142,5 %', (1.5*50 + 1.5*35 + 1.0*15) / 100 = 1.425)
) as t(prueba, ok);
