-- Esquema de Supabase para Seblaza, reconstruido a partir del código del frontend.
-- Pegar completo en Supabase -> SQL Editor -> Run.

-- ============ Tablas ============

create table if not exists public.perfiles (
  id               uuid primary key references auth.users (id) on delete cascade,
  nombres          text,
  apellidos        text,
  dni              text,
  telefono         text,
  fecha_nacimiento date,
  direccion        text,
  rol              text not null default 'cliente'
);

create table if not exists public.productos (
  id          bigint generated always as identity primary key,
  nombre      text not null,
  descripcion text,
  categoria   text not null,
  modelo      text not null,
  marca       text not null,
  precio      numeric(10,2) not null check (precio > 0),
  stock       integer not null default 0 check (stock >= 0),
  estado      text not null default 'disponible',   -- el Home filtra estado = 'oferta'
  img_url     text
);

create table if not exists public.metodos_pago (
  id     integer primary key,
  nombre text not null
);

create table if not exists public.pedidos (
  id              bigint generated always as identity primary key,
  id_usuario      uuid not null references public.perfiles (id) on delete cascade,
  fecha_pedido    timestamptz not null default now(),
  estado_pedido   text not null default 'en proceso',  -- en proceso | enviado | entregado | cancelado
  total           numeric(10,2) not null,
  direccion_envio text                                  -- JSON serializado como texto
);

create table if not exists public.detalles_pedido (
  id              bigint generated always as identity primary key,
  id_pedido       bigint not null references public.pedidos (id) on delete cascade,
  id_producto     bigint not null references public.productos (id),
  cantidad        integer not null check (cantidad > 0),
  precio_unitario numeric(10,2) not null
);

create table if not exists public.pagos (
  id                     bigint generated always as identity primary key,
  id_pedido              bigint not null references public.pedidos (id) on delete cascade,
  id_metodo_pago         integer references public.metodos_pago (id),
  monto                  numeric(10,2) not null,
  estado_pago            text not null default 'completado',
  fecha_pago             timestamptz not null default now(),
  referencia_transaccion text
);

insert into public.metodos_pago (id, nombre) values
  (1, 'Tarjeta de crédito'),
  (2, 'Tarjeta de débito'),
  (3, 'PayPal'),
  (4, 'Yape/Plin')
on conflict (id) do nothing;

-- ============ Perfil automático al registrarse ============
-- El checkout inserta en pedidos con id_usuario -> perfiles, así que el perfil debe existir siempre.

create or replace function public.crear_perfil_nuevo_usuario()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.perfiles (id, nombres)
  values (new.id, new.raw_user_meta_data ->> 'nombre')
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.crear_perfil_nuevo_usuario();

-- Perfiles de usuarios que ya existan antes de correr este script
insert into public.perfiles (id, nombres)
select id, raw_user_meta_data ->> 'nombre' from auth.users
on conflict (id) do nothing;

-- ============ Seguridad (RLS) ============
-- Admin = rol 'perfiles.rol' = 'administrador' o email del admin que usa el frontend.
-- Para que alguien sea admin: update public.perfiles set rol = 'administrador' where id = '<uuid>';

create or replace function public.es_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select rol = 'administrador' from public.perfiles where id = auth.uid()),
    false
  ) or (auth.jwt() ->> 'email') = 'davidgarcia241296@gmail.com';
$$;

alter table public.perfiles        enable row level security;
alter table public.productos       enable row level security;
alter table public.metodos_pago    enable row level security;
alter table public.pedidos         enable row level security;
alter table public.detalles_pedido enable row level security;
alter table public.pagos           enable row level security;

-- productos: lectura pública, escritura solo admin
create policy productos_select on public.productos for select using (true);
create policy productos_admin   on public.productos for all
  using (public.es_admin()) with check (public.es_admin());

-- metodos_pago: lectura pública; el checkout intenta insertarlos si faltan, ya están sembrados
create policy metodos_select on public.metodos_pago for select using (true);

-- perfiles: cada quien el suyo; admin todos
create policy perfiles_select on public.perfiles for select
  using (id = auth.uid() or public.es_admin());
create policy perfiles_insert on public.perfiles for insert
  with check (id = auth.uid());
create policy perfiles_update on public.perfiles for update
  using (id = auth.uid() or public.es_admin())
  with check ((id = auth.uid() and rol = (select rol from public.perfiles where id = auth.uid())) or public.es_admin());

-- pedidos: cada quien los suyos; admin todos
create policy pedidos_select on public.pedidos for select
  using (id_usuario = auth.uid() or public.es_admin());
create policy pedidos_insert on public.pedidos for insert
  with check (id_usuario = auth.uid());
create policy pedidos_update on public.pedidos for update
  using (id_usuario = auth.uid() or public.es_admin());

-- detalles_pedido y pagos: a través del pedido
create policy detalles_select on public.detalles_pedido for select
  using (exists (select 1 from public.pedidos p where p.id = id_pedido and (p.id_usuario = auth.uid() or public.es_admin())));
create policy detalles_insert on public.detalles_pedido for insert
  with check (exists (select 1 from public.pedidos p where p.id = id_pedido and p.id_usuario = auth.uid()));

create policy pagos_select on public.pagos for select
  using (exists (select 1 from public.pedidos p where p.id = id_pedido and (p.id_usuario = auth.uid() or public.es_admin())));
create policy pagos_insert on public.pagos for insert
  with check (exists (select 1 from public.pedidos p where p.id = id_pedido and p.id_usuario = auth.uid()));
create policy pagos_update on public.pagos for update
  using (exists (select 1 from public.pedidos p where p.id = id_pedido and (p.id_usuario = auth.uid() or public.es_admin())));

-- ============ Storage: imágenes de productos ============

insert into storage.buckets (id, name, public)
values ('product-images', 'product-images', true)
on conflict (id) do nothing;

create policy product_images_read on storage.objects for select
  using (bucket_id = 'product-images');
create policy product_images_write on storage.objects for insert
  with check (bucket_id = 'product-images' and public.es_admin());
