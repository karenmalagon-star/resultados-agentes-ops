-- Módulo de Variables · 004 · search_path fijo en las funciones SQL (aviso del asesor de seguridad de Supabase).
alter function public.var_hoy_col() set search_path = public, pg_temp;
alter function public.var_ahora_col() set search_path = public, pg_temp;
alter function public.var_norm(text) set search_path = public, pg_temp;
alter function public.var_es_excluido(text) set search_path = public, pg_temp;
alter function public.var_es_festivo(date) set search_path = public, pg_temp;
alter function public.var_es_habil(date) set search_path = public, pg_temp;
alter function public.var_dias_habiles(date) set search_path = public, pg_temp;
alter function public.var_config_default(date) set search_path = public, pg_temp;
