-- =====================================================================
--  ACTUALIZACIÓN v5: Código QR por cuenta (ej. Toke de Banco Popular)
--                    y todas las rifas pasan a "números al azar"
--  Ejecuta TODO este archivo en Supabase > SQL Editor > New query > Run
-- =====================================================================
alter table public.bank_accounts add column if not exists qr_url text;

update public.raffles set mode = 'random' where mode <> 'random';
alter table public.raffles alter column mode set default 'random';

notify pgrst, 'reload schema';
