-- =====================================================================
--  RIFAS · Esquema de base de datos para Supabase
--  Ejecuta este archivo completo en: Supabase > SQL Editor > New query
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------- ADMINISTRADORES ----------
create table if not exists public.admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz default now()
);

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;

-- ---------- RIFAS ----------
create table if not exists public.raffles (
  id            uuid primary key default gen_random_uuid(),
  slug          text unique not null,
  title         text not null,
  description   text,
  prize         text,
  image_url     text,
  ticket_price  numeric(12,2) not null check (ticket_price > 0),
  currency      text not null default 'DOP',
  mode          text not null default 'both' check (mode in ('pick','random','both')),
  total_tickets int  not null check (total_tickets between 2 and 100000),
  max_per_order int  not null default 50,
  draw_date     timestamptz,
  status        text not null default 'draft' check (status in ('draft','active','closed','drawn')),
  winner_ticket_id uuid,
  drawn_at      timestamptz,
  created_at    timestamptz default now()
);

-- ---------- BOLETOS (se generan solos al crear la rifa) ----------
create table if not exists public.tickets (
  id             uuid primary key default gen_random_uuid(),
  raffle_id      uuid not null references public.raffles(id) on delete cascade,
  number         int  not null,
  status         text not null default 'available' check (status in ('available','reserved','sold')),
  order_id       uuid,
  reserved_until timestamptz,
  unique (raffle_id, number)
);
create index if not exists tickets_raffle_status on public.tickets (raffle_id, status);

-- ---------- ÓRDENES (datos del comprador: solo los ve el admin) ----------
create table if not exists public.orders (
  id            uuid primary key default gen_random_uuid(),
  order_number  bigint generated always as identity (start with 100001) unique,
  raffle_id     uuid not null references public.raffles(id) on delete cascade,
  buyer_name    text not null,
  buyer_phone   text not null,
  buyer_email   text,
  quantity      int  not null,
  amount        numeric(12,2) not null,
  status        text not null default 'pending' check (status in ('pending','paid','declined','cancelled','expired')),
  payment_method text default 'azul',
  auth_code     text,
  rrn           text,
  response_msg  text,
  created_at    timestamptz default now(),
  paid_at       timestamptz
);
create index if not exists orders_raffle on public.orders (raffle_id, status);

alter table public.raffles
  drop constraint if exists raffles_winner_fk,
  add constraint raffles_winner_fk foreign key (winner_ticket_id) references public.tickets(id);

-- Generar boletos 0..N-1 al crear la rifa
create or replace function public.generate_tickets()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.tickets (raffle_id, number)
  select new.id, g from generate_series(0, new.total_tickets - 1) g;
  return new;
end $$;

drop trigger if exists trg_generate_tickets on public.raffles;
create trigger trg_generate_tickets after insert on public.raffles
for each row execute function public.generate_tickets();

-- No permitir cambiar la cantidad de boletos después de creada
create or replace function public.lock_total_tickets()
returns trigger language plpgsql as $$
begin
  if new.total_tickets <> old.total_tickets then
    raise exception 'No se puede cambiar la cantidad de boletos de una rifa ya creada';
  end if;
  return new;
end $$;
drop trigger if exists trg_lock_total on public.raffles;
create trigger trg_lock_total before update on public.raffles
for each row execute function public.lock_total_tickets();

-- ---------- LIBERAR RESERVAS VENCIDAS ----------
create or replace function public.release_expired()
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.orders o set status = 'expired'
   where o.status = 'pending'
     and o.created_at < now() - interval '20 minutes'
     and o.payment_method = 'azul';
  update public.tickets t set status = 'available', order_id = null, reserved_until = null
   where t.status = 'reserved' and t.reserved_until < now();
end $$;

-- ---------- RESERVAR BOLETOS (solo la llama el servidor con service_role) ----------
-- p_numbers: números elegidos (modo pick). Si viene vacío se usan p_quantity aleatorios.
create or replace function public.reserve_tickets(
  p_raffle_id uuid, p_numbers int[], p_quantity int,
  p_name text, p_phone text, p_email text, p_method text default 'azul'
) returns json language plpgsql security definer set search_path = public as $$
declare
  r public.raffles;
  v_order public.orders;
  v_qty int;
  v_got int;
begin
  perform public.release_expired();

  select * into r from public.raffles where id = p_raffle_id;
  if r.id is null or r.status <> 'active' then
    raise exception 'La rifa no está disponible';
  end if;

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
    update public.tickets t set status='reserved', order_id=v_order.id, reserved_until = now() + interval '15 minutes'
      from picked where t.id = picked.id;
  else
    with picked as (
      select id from public.tickets
       where raffle_id = r.id and status = 'available'
       order by random() limit v_qty
       for update skip locked
    )
    update public.tickets t set status='reserved', order_id=v_order.id, reserved_until = now() + interval '15 minutes'
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

-- ---------- CONFIRMAR / RECHAZAR PAGO ----------
create or replace function public.confirm_order(p_order_id uuid, p_auth text, p_rrn text, p_msg text)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.orders set status='paid', auth_code=p_auth, rrn=p_rrn, response_msg=p_msg, paid_at=now()
   where id = p_order_id and status in ('pending','expired');
  update public.tickets set status='sold', reserved_until=null
   where order_id = p_order_id;
  -- Si la reserva venció antes de que llegara el pago, se marca para revisión manual
  if (select count(*) from public.tickets where order_id = p_order_id)
     < (select quantity from public.orders where id = p_order_id) then
    update public.orders set response_msg = 'REVISAR: pago recibido pero la reserva había vencido'
     where id = p_order_id;
  end if;
end $$;

create or replace function public.fail_order(p_order_id uuid, p_status text, p_msg text)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.orders set status=p_status, response_msg=p_msg
   where id = p_order_id and status = 'pending';
  update public.tickets set status='available', order_id=null, reserved_until=null
   where order_id = p_order_id and status = 'reserved';
end $$;

-- Admin: marcar una orden como pagada (transferencia / efectivo)
create or replace function public.admin_mark_paid(p_order_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'No autorizado'; end if;
  if exists (select 1 from public.tickets where order_id = p_order_id and status='available') then
    raise exception 'Los boletos de esta orden fueron liberados';
  end if;
  perform public.confirm_order(p_order_id, 'MANUAL', null, 'Pago confirmado por admin');
end $$;

-- Admin: venta manual (efectivo/transferencia) sin pasar por Azul
create or replace function public.admin_manual_sale(
  p_raffle_id uuid, p_numbers int[], p_quantity int, p_name text, p_phone text
) returns json language plpgsql security definer set search_path = public as $$
declare res json;
begin
  if not public.is_admin() then raise exception 'No autorizado'; end if;
  res := public.reserve_tickets(p_raffle_id, p_numbers, p_quantity, p_name, p_phone, null, 'manual');
  perform public.confirm_order((res->>'order_id')::uuid, 'MANUAL', null, 'Venta manual');
  return res;
end $$;

-- ---------- SORTEO (aleatorio en el servidor; la ruleta solo lo muestra) ----------
create or replace function public.draw_winner(p_raffle_id uuid)
returns json language plpgsql security definer set search_path = public as $$
declare
  r public.raffles;
  w public.tickets;
  o public.orders;
begin
  if not public.is_admin() then raise exception 'No autorizado'; end if;
  select * into r from public.raffles where id = p_raffle_id for update;
  if r.status = 'drawn' then raise exception 'Esta rifa ya tiene ganador'; end if;

  -- gen_random_bytes usa un generador criptográfico
  select t.* into w from public.tickets t
   where t.raffle_id = r.id and t.status = 'sold'
   order by gen_random_bytes(8) limit 1;
  if w.id is null then raise exception 'No hay boletos vendidos'; end if;

  select * into o from public.orders where id = w.order_id;
  update public.raffles set status='drawn', winner_ticket_id=w.id, drawn_at=now() where id = r.id;

  return json_build_object('ticket_id', w.id, 'number', w.number,
                           'buyer_name', o.buyer_name, 'buyer_phone', o.buyer_phone,
                           'order_number', o.order_number);
end $$;

-- Público: ganador con nombre parcialmente oculto
create or replace function public.public_winner(p_raffle_id uuid)
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'number', t.number,
    'name', split_part(o.buyer_name,' ',1) || ' ' || left(coalesce(nullif(split_part(o.buyer_name,' ',2),''),''),1) || '.',
    'drawn_at', r.drawn_at)
  from public.raffles r
  join public.tickets t on t.id = r.winner_ticket_id
  join public.orders o on o.id = t.order_id
  where r.id = p_raffle_id and r.status = 'drawn';
$$;

-- Público: consultar el estado de una orden por su id (para la página de resultado)
create or replace function public.order_status(p_order_id uuid)
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'order_number', o.order_number, 'status', o.status, 'amount', o.amount,
    'title', r.title, 'slug', r.slug, 'currency', r.currency, 'total', r.total_tickets,
    'numbers', (select json_agg(number order by number) from public.tickets where order_id = o.id))
  from public.orders o join public.raffles r on r.id = o.raffle_id
  where o.id = p_order_id;
$$;

-- ---------- SEGURIDAD (RLS) ----------
alter table public.admins  enable row level security;
alter table public.raffles enable row level security;
alter table public.tickets enable row level security;
alter table public.orders  enable row level security;

drop policy if exists "raffles public read" on public.raffles;
create policy "raffles public read" on public.raffles for select
  using (status <> 'draft' or public.is_admin());
drop policy if exists "raffles admin write" on public.raffles;
create policy "raffles admin write" on public.raffles for all
  using (public.is_admin()) with check (public.is_admin());

drop policy if exists "tickets public read" on public.tickets;
create policy "tickets public read" on public.tickets for select using (true);

drop policy if exists "orders admin" on public.orders;
create policy "orders admin" on public.orders for all
  using (public.is_admin()) with check (public.is_admin());

drop policy if exists "admins self" on public.admins;
create policy "admins self" on public.admins for select using (user_id = auth.uid());

-- La columna order_id de tickets no expone datos personales (solo un uuid).
-- Funciones que solo debe usar el servidor:
revoke execute on function public.reserve_tickets(uuid,int[],int,text,text,text,text) from public, anon, authenticated;
revoke execute on function public.confirm_order(uuid,text,text,text) from public, anon, authenticated;
revoke execute on function public.fail_order(uuid,text,text) from public, anon, authenticated;
revoke execute on function public.release_expired() from public, anon;
grant  execute on function public.release_expired() to authenticated;

-- ---------- ALMACENAMIENTO DE IMÁGENES ----------
insert into storage.buckets (id, name, public) values ('rifas','rifas', true)
on conflict (id) do nothing;

drop policy if exists "rifas img read" on storage.objects;
create policy "rifas img read" on storage.objects for select using (bucket_id = 'rifas');
drop policy if exists "rifas img admin" on storage.objects;
create policy "rifas img admin" on storage.objects for all
  using (bucket_id = 'rifas' and public.is_admin())
  with check (bucket_id = 'rifas' and public.is_admin());

-- =====================================================================
--  ÚLTIMO PASO: hazte administrador.
--  1) Crea tu usuario en Supabase > Authentication > Users > Add user
--  2) Ejecuta (cambiando el correo):
--  insert into public.admins (user_id)
--  select id from auth.users where email = 'TU_CORREO@gmail.com';
-- =====================================================================
