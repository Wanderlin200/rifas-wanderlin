-- =====================================================================
--  ACTUALIZACIÓN: Pago electrónico y/o transferencia bancaria por rifa
--  Ejecuta este archivo UNA VEZ en Supabase > SQL Editor > New query > Run
--  (Es seguro ejecutarlo de nuevo: no borra datos.)
-- =====================================================================

-- ---------- Nuevas columnas ----------
alter table public.raffles add column if not exists pay_online   boolean not null default true;
alter table public.raffles add column if not exists pay_transfer boolean not null default false;
alter table public.raffles add column if not exists bank_info    text;

alter table public.orders add column if not exists receipt_path text;

alter table public.raffles drop constraint if exists raffles_pay_method_chk;
alter table public.raffles add constraint raffles_pay_method_chk check (pay_online or pay_transfer);

-- ---------- Liberar reservas vencidas ----------
-- Azul: 15 min · Transferencia sin comprobante: 2 horas · Transferencia con comprobante: 72 horas
create or replace function public.release_expired()
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.tickets t set status = 'available', order_id = null, reserved_until = null
   where t.status = 'reserved' and t.reserved_until < now();

  update public.orders o set status = 'expired'
   where o.status = 'pending' and o.payment_method in ('azul','transfer')
     and not exists (select 1 from public.tickets t where t.order_id = o.id);
end $$;

-- ---------- Reservar boletos ----------
create or replace function public.reserve_tickets(
  p_raffle_id uuid, p_numbers int[], p_quantity int,
  p_name text, p_phone text, p_email text, p_method text default 'azul'
) returns json language plpgsql security definer set search_path = public as $$
declare
  r public.raffles;
  v_order public.orders;
  v_qty int;
  v_got int;
  v_hold interval;
begin
  perform public.release_expired();

  select * into r from public.raffles where id = p_raffle_id;
  if r.id is null or r.status <> 'active' then
    raise exception 'La rifa no está disponible';
  end if;
  if p_method = 'azul' and not r.pay_online then
    raise exception 'Esta rifa no acepta pago electrónico';
  end if;
  if p_method = 'transfer' and not r.pay_transfer then
    raise exception 'Esta rifa no acepta transferencias';
  end if;

  v_hold := case p_method when 'transfer' then interval '2 hours' else interval '15 minutes' end;

  if p_numbers is not null and array_length(p_numbers,1) > 0 then
    if r.mode = 'random' then raise exception 'Esta rifa solo asigna números al azar'; end if;
    v_qty := array_length(p_numbers,1);
  else
    if r.mode = 'pick' then raise exception 'Debes elegir tus números'; end if;
    v_qty := coalesce(p_quantity,0);
  end if;

  if v_qty < 1 or v_qty > r.max_per_order then
    raise exception 'Cantidad inválida (máximo % por compra)', r.max_per_order;
  end if;

  insert into public.orders (raffle_id, buyer_name, buyer_phone, buyer_email, quantity, amount, payment_method)
  values (r.id, trim(p_name), trim(p_phone), nullif(trim(p_email),''), v_qty, v_qty * r.ticket_price, p_method)
  returning * into v_order;

  if p_numbers is not null and array_length(p_numbers,1) > 0 then
    with picked as (
      select id from public.tickets
       where raffle_id = r.id and number = any(p_numbers) and status = 'available'
       for update skip locked
    )
    update public.tickets t set status='reserved', order_id=v_order.id, reserved_until = now() + v_hold
      from picked where t.id = picked.id;
  else
    with picked as (
      select id from public.tickets
       where raffle_id = r.id and status = 'available'
       order by random() limit v_qty
       for update skip locked
    )
    update public.tickets t set status='reserved', order_id=v_order.id, reserved_until = now() + v_hold
      from picked where t.id = picked.id;
  end if;

  get diagnostics v_got = row_count;
  if v_got < v_qty then
    raise exception 'Algunos números ya no están disponibles. Actualiza la página e inténtalo de nuevo.';
  end if;

  return json_build_object(
    'order_id', v_order.id,
    'order_number', v_order.order_number,
    'amount', v_order.amount,
    'currency', r.currency,
    'title', r.title,
    'numbers', (select json_agg(number order by number) from public.tickets where order_id = v_order.id)
  );
end $$;

-- ---------- Guardar comprobante (lo llama el servidor) ----------
create or replace function public.attach_receipt(p_order_id uuid, p_path text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.orders where id = p_order_id and status = 'pending' and payment_method = 'transfer') then
    raise exception 'Esta orden ya no acepta comprobantes';
  end if;
  if not exists (select 1 from public.tickets where order_id = p_order_id) then
    raise exception 'La reserva de esta orden venció. Escríbenos por WhatsApp.';
  end if;
  update public.orders set receipt_path = p_path where id = p_order_id;
  -- con comprobante, los números quedan apartados 72 horas mientras se verifica
  update public.tickets set reserved_until = now() + interval '72 hours'
   where order_id = p_order_id and status = 'reserved';
end $$;

-- ---------- Admin: aprobar / rechazar ----------
create or replace function public.admin_mark_paid(p_order_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'No autorizado'; end if;
  if not exists (select 1 from public.tickets where order_id = p_order_id) then
    raise exception 'Los números de esta orden ya fueron liberados. Regístrala como venta manual.';
  end if;
  perform public.confirm_order(p_order_id, 'MANUAL', null, 'Pago verificado por admin');
end $$;

create or replace function public.admin_reject_order(p_order_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'No autorizado'; end if;
  perform public.fail_order(p_order_id, 'declined', 'Comprobante rechazado');
end $$;

-- ---------- Estado público de una orden (página de resultado) ----------
create or replace function public.order_status(p_order_id uuid)
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'order_number', o.order_number, 'status', o.status, 'amount', o.amount,
    'method', o.payment_method, 'has_receipt', o.receipt_path is not null,
    'title', r.title, 'slug', r.slug, 'currency', r.currency, 'total', r.total_tickets,
    'bank_info', case when o.payment_method = 'transfer' then r.bank_info end,
    'reserved_until', (select min(reserved_until) from public.tickets where order_id = o.id),
    'numbers', (select json_agg(number order by number) from public.tickets where order_id = o.id))
  from public.orders o join public.raffles r on r.id = o.raffle_id
  where o.id = p_order_id;
$$;

revoke execute on function public.reserve_tickets(uuid,int[],int,text,text,text,text) from public, anon, authenticated;
revoke execute on function public.attach_receipt(uuid,text) from public, anon, authenticated;
revoke execute on function public.release_expired() from public, anon;
grant  execute on function public.release_expired() to authenticated;

-- ---------- Comprobantes: almacenamiento PRIVADO (solo el admin los ve) ----------
insert into storage.buckets (id, name, public) values ('comprobantes','comprobantes', false)
on conflict (id) do update set public = false;

drop policy if exists "comprobantes admin" on storage.objects;
create policy "comprobantes admin" on storage.objects for all
  using (bucket_id = 'comprobantes' and public.is_admin())
  with check (bucket_id = 'comprobantes' and public.is_admin());
