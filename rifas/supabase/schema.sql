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

  -- gen_random_uuid() usa el generador aleatorio seguro de Postgres
  select t.* into w from public.tickets t
   where t.raffle_id = r.id and t.status = 'sold'
   order by gen_random_uuid() limit 1;
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

-- Refrescar la caché de la API para que vea las columnas nuevas
notify pgrst, 'reload schema';


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


-- =====================================================================
--  ACTUALIZACIÓN v5: Código QR por cuenta (ej. Toke de Banco Popular)
--                    y todas las rifas pasan a "números al azar"
--  Ejecuta TODO este archivo en Supabase > SQL Editor > New query > Run
-- =====================================================================
alter table public.bank_accounts add column if not exists qr_url text;

update public.raffles set mode = 'random' where mode <> 'random';
alter table public.raffles alter column mode set default 'random';

notify pgrst, 'reload schema';
