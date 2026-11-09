-- =====================================================================
--  ACTUALIZACIÓN v4: Rifas de hasta 1,000,000 de boletos
--  Ejecuta TODO este archivo UNA VEZ en Supabase > SQL Editor > New query > Run
--  (Requiere v3. No borra datos.)
-- =====================================================================

-- ---------- Nuevo límite ----------
alter table public.raffles drop constraint if exists raffles_total_tickets_check;
alter table public.raffles add constraint raffles_total_tickets_check check (total_tickets between 2 and 1000000);

-- ---------- Índices para que todo siga rápido con muchos boletos ----------
create index if not exists tickets_order_id on public.tickets (order_id) where order_id is not null;
create index if not exists tickets_reserved_until on public.tickets (reserved_until) where status = 'reserved';

-- ---------- Generar boletos ----------
-- Rifas de hasta 100,000 boletos: se generan solos al crearlas (como antes).
-- Rifas más grandes: el panel los genera por partes para no pasar el tiempo límite de Supabase.
create or replace function public.generate_tickets()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.total_tickets <= 100000 then
    insert into public.tickets (raffle_id, number)
    select new.id, g from generate_series(0, new.total_tickets - 1) g;
  end if;
  return new;
end $$;

-- Genera el siguiente bloque de boletos y devuelve cuántos hay en total
create or replace function public.admin_generate_tickets(p_raffle_id uuid, p_chunk int default 50000)
returns json language plpgsql security definer set search_path = public as $$
declare r public.raffles; v_from int; v_to int; v_count int;
begin
  if not public.is_admin() then raise exception 'No autorizado'; end if;
  select * into r from public.raffles where id = p_raffle_id;
  if r.id is null then raise exception 'Rifa no encontrada'; end if;
  select coalesce(max(number) + 1, 0) into v_from from public.tickets where raffle_id = r.id;
  v_to := least(v_from + greatest(p_chunk, 1000) - 1, r.total_tickets - 1);
  if v_from <= v_to then
    insert into public.tickets (raffle_id, number)
    select r.id, g from generate_series(v_from, v_to) g
    on conflict (raffle_id, number) do nothing;
  end if;
  v_count := least(v_to + 1, r.total_tickets);
  return json_build_object('generated', v_count, 'total', r.total_tickets, 'done', v_count >= r.total_tickets);
end $$;

-- Borra los boletos de una rifa por partes (para eliminar rifas muy grandes)
create or replace function public.admin_delete_tickets(p_raffle_id uuid, p_chunk int default 50000)
returns int language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  if not public.is_admin() then raise exception 'No autorizado'; end if;
  update public.raffles set winner_ticket_id = null where id = p_raffle_id;
  delete from public.tickets where id in (
    select id from public.tickets where raffle_id = p_raffle_id limit greatest(p_chunk, 1000));
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- ---------- Reservar boletos (azar más rápido en rifas grandes) ----------
create or replace function public.reserve_tickets(
  p_raffle_id uuid, p_numbers int[], p_quantity int,
  p_name text, p_phone text, p_email text, p_method text default 'azul'
) returns json language plpgsql security definer set search_path = public as $$
declare r public.raffles; v_order public.orders; v_qty int; v_got int := 0; v_n int; v_hold interval; v_try int := 0;
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
    raise exception 'La compra mínima es de % números', r.min_per_order; end if;
  if v_qty < 1 or v_qty > r.max_per_order then
    raise exception 'Cantidad inválida (máximo % por compra)', r.max_per_order; end if;

  insert into public.orders (raffle_id, buyer_name, buyer_phone, buyer_email, quantity, amount, payment_method)
  values (r.id, trim(p_name), trim(p_phone), nullif(trim(p_email),''), v_qty, v_qty * r.ticket_price, p_method)
  returning * into v_order;

  if p_numbers is not null and array_length(p_numbers,1) > 0 then
    with picked as (select id from public.tickets where raffle_id = r.id and number = any(p_numbers) and status = 'available' for update skip locked)
    update public.tickets t set status='reserved', order_id=v_order.id, reserved_until = now() + v_hold from picked where t.id = picked.id;
    get diagnostics v_got = row_count;
  else
    -- 1) Probar números al azar dentro del rango (rápido aunque haya un millón de boletos)
    while v_got < v_qty and v_try < 4 loop
      v_try := v_try + 1;
      with cand as (
        select distinct floor(random() * r.total_tickets)::int as n
          from generate_series(1, (v_qty - v_got) * 4 + 20)
      ), picked as (
        select t.id from public.tickets t join cand on cand.n = t.number
         where t.raffle_id = r.id and t.status = 'available'
         limit v_qty - v_got
         for update of t skip locked
      )
      update public.tickets t set status='reserved', order_id=v_order.id, reserved_until = now() + v_hold
        from picked where t.id = picked.id;
      get diagnostics v_n = row_count;
      v_got := v_got + v_n;
    end loop;
    -- 2) Si quedan pocos libres, completar con los disponibles restantes
    if v_got < v_qty then
      with picked as (select id from public.tickets where raffle_id = r.id and status = 'available'
                       order by random() limit v_qty - v_got for update skip locked)
      update public.tickets t set status='reserved', order_id=v_order.id, reserved_until = now() + v_hold
        from picked where t.id = picked.id;
      get diagnostics v_n = row_count;
      v_got := v_got + v_n;
    end if;
  end if;

  if v_got < v_qty then raise exception 'Algunos números ya no están disponibles. Actualiza la página e inténtalo de nuevo.'; end if;

  return json_build_object('order_id', v_order.id, 'order_number', v_order.order_number, 'amount', v_order.amount,
    'currency', r.currency, 'title', r.title,
    'numbers', (select json_agg(number order by number) from public.tickets where order_id = v_order.id));
end $$;
revoke execute on function public.reserve_tickets(uuid,int[],int,text,text,text,text) from public, anon, authenticated;

notify pgrst, 'reload schema';
