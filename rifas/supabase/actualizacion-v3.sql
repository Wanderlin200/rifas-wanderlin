-- =====================================================================
--  ACTUALIZACIÓN v3: Números premiados · Paquetes y compra mínima ·
--                    Varias cuentas bancarias · Verificador de boletos
--  Ejecuta TODO este archivo UNA VEZ en Supabase > SQL Editor > New query > Run
--  (Requiere haber ejecutado antes actualizacion-transferencias.sql. No borra datos.)
-- =====================================================================

-- ---------- Rifas: compra mínima, paquetes y números premiados ----------
alter table public.raffles add column if not exists min_per_order int not null default 1;
alter table public.raffles add column if not exists packages      int[] not null default '{2,5,10,25,50,100}';
alter table public.raffles add column if not exists bonus_prize   text;          -- ej. "RD$5,000"
alter table public.raffles add column if not exists bonus_numbers int[] not null default '{}';

-- ---------- Órdenes: a qué cuenta transfirió el cliente ----------
alter table public.orders add column if not exists bank_account text;

-- ---------- Cuentas bancarias (se usan en todas las rifas con transferencia) ----------
create table if not exists public.bank_accounts (
  id         uuid primary key default gen_random_uuid(),
  bank       text not null,
  acc_type   text,
  number     text,
  holder     text,
  id_doc     text,
  active     boolean not null default true,
  sort       int not null default 0,
  created_at timestamptz default now()
);
alter table public.bank_accounts enable row level security;
drop policy if exists "bank public read" on public.bank_accounts;
create policy "bank public read" on public.bank_accounts for select using (active or public.is_admin());
drop policy if exists "bank admin write" on public.bank_accounts;
create policy "bank admin write" on public.bank_accounts for all
  using (public.is_admin()) with check (public.is_admin());
grant select on public.bank_accounts to anon, authenticated;
grant insert, update, delete on public.bank_accounts to authenticated;

-- Pasar la cuenta que ya tenías escrita en una rifa a la nueva lista (solo si la lista está vacía)
insert into public.bank_accounts (bank, acc_type, number, holder, id_doc)
select coalesce(nullif(trim(substring(bank_info from 'Banco: ([^\n]*)')), ''), 'Banco'),
       nullif(trim(substring(bank_info from 'Tipo de cuenta: ([^\n]*)')), ''),
       nullif(trim(substring(bank_info from 'Número de cuenta: ([^\n]*)')), ''),
       nullif(trim(substring(bank_info from 'A nombre de: ([^\n]*)')), ''),
       nullif(trim(substring(bank_info from 'Cédula / RNC: ([^\n]*)')), '')
from (select bank_info from public.raffles where coalesce(bank_info,'') <> '' order by created_at desc limit 1) x
where not exists (select 1 from public.bank_accounts);

-- ---------- Reservar boletos (ahora con compra mínima) ----------
create or replace function public.reserve_tickets(
  p_raffle_id uuid, p_numbers int[], p_quantity int,
  p_name text, p_phone text, p_email text, p_method text default 'azul'
) returns json language plpgsql security definer set search_path = public as $$
declare
  r public.raffles; v_order public.orders; v_qty int; v_got int; v_hold interval;
begin
  perform public.release_expired();
  select * into r from public.raffles where id = p_raffle_id;
  if r.id is null or r.status <> 'active' then raise exception 'La rifa no está disponible'; end if;
  if p_method = 'azul' and not r.pay_online then raise exception 'Esta rifa no acepta pago electrónico'; end if;
  if p_method = 'transfer' and not r.pay_transfer then raise exception 'Esta rifa no acepta transferencias'; end if;
  v_hold := case p_method when 'transfer' then interval '2 hours' else interval '15 minutes' end;

  if p_numbers is not null and array_length(p_numbers,1) > 0 then
    if r.mode = 'random' then raise exception 'Esta rifa solo asigna números al azar'; end if;
    v_qty := array_length(p_numbers,1);
  else
    if r.mode = 'pick' then raise exception 'Debes elegir tus números'; end if;
    v_qty := coalesce(p_quantity,0);
  end if;
  if p_method <> 'manual' and v_qty < coalesce(r.min_per_order,1) then
    raise exception 'La compra mínima es de % números', r.min_per_order;
  end if;
  if v_qty < 1 or v_qty > r.max_per_order then
    raise exception 'Cantidad inválida (máximo % por compra)', r.max_per_order;
  end if;

  insert into public.orders (raffle_id, buyer_name, buyer_phone, buyer_email, quantity, amount, payment_method)
  values (r.id, trim(p_name), trim(p_phone), nullif(trim(p_email),''), v_qty, v_qty * r.ticket_price, p_method)
  returning * into v_order;

  if p_numbers is not null and array_length(p_numbers,1) > 0 then
    with picked as (select id from public.tickets where raffle_id = r.id and number = any(p_numbers) and status = 'available' for update skip locked)
    update public.tickets t set status='reserved', order_id=v_order.id, reserved_until = now() + v_hold from picked where t.id = picked.id;
  else
    with picked as (select id from public.tickets where raffle_id = r.id and status = 'available' order by random() limit v_qty for update skip locked)
    update public.tickets t set status='reserved', order_id=v_order.id, reserved_until = now() + v_hold from picked where t.id = picked.id;
  end if;

  get diagnostics v_got = row_count;
  if v_got < v_qty then raise exception 'Algunos números ya no están disponibles. Actualiza la página e inténtalo de nuevo.'; end if;

  return json_build_object('order_id', v_order.id, 'order_number', v_order.order_number, 'amount', v_order.amount,
    'currency', r.currency, 'title', r.title,
    'numbers', (select json_agg(number order by number) from public.tickets where order_id = v_order.id));
end $$;

-- ---------- Guardar comprobante + cuenta a la que transfirió ----------
drop function if exists public.attach_receipt(uuid, text);
create or replace function public.attach_receipt(p_order_id uuid, p_path text, p_bank text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.orders where id = p_order_id and status = 'pending' and payment_method = 'transfer') then
    raise exception 'Esta orden ya no acepta comprobantes'; end if;
  if not exists (select 1 from public.tickets where order_id = p_order_id) then
    raise exception 'La reserva de esta orden venció. Escríbenos por WhatsApp.'; end if;
  update public.orders set receipt_path = p_path, bank_account = left(p_bank, 120) where id = p_order_id;
  update public.tickets set reserved_until = now() + interval '72 hours' where order_id = p_order_id and status = 'reserved';
end $$;
revoke execute on function public.attach_receipt(uuid,text,text) from public, anon, authenticated;
revoke execute on function public.reserve_tickets(uuid,int[],int,text,text,text,text) from public, anon, authenticated;

-- ---------- Verificador: buscar compras por teléfono ----------
-- Devuelve solo rifa, estado y números (nunca nombres ni otros datos del comprador)
create or replace function public.lookup_tickets(p_phone text)
returns json language plpgsql stable security definer set search_path = public as $$
declare v_digits text := right(regexp_replace(coalesce(p_phone,''), '\D', '', 'g'), 10);
begin
  if length(v_digits) < 10 then raise exception 'Escribe los 10 dígitos de tu teléfono'; end if;
  return coalesce((
    select json_agg(x order by x.created_at desc) from (
      select o.id, o.order_number, o.status, o.amount, o.created_at, o.payment_method as method,
             o.receipt_path is not null as has_receipt,
             r.title, r.slug, r.currency, r.total_tickets as total, r.status as raffle_status,
             r.bonus_prize, r.bonus_numbers,
             (select json_agg(t.number order by t.number) from public.tickets t where t.order_id = o.id) as numbers,
             (select t.number from public.tickets t where t.id = r.winner_ticket_id and t.order_id = o.id) as won_number
        from public.orders o join public.raffles r on r.id = o.raffle_id
       where right(regexp_replace(o.buyer_phone, '\D', '', 'g'), 10) = v_digits
         and o.status in ('paid','pending')
       order by o.created_at desc limit 50
    ) x), '[]'::json);
end $$;
grant execute on function public.lookup_tickets(text) to anon, authenticated;

notify pgrst, 'reload schema';
