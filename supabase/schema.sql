-- ============================================================================
-- SÉKITO — esquema inicial de la base
-- ============================================================================
-- CÓMO CORRERLO
--   1. Entrá a supabase.com/dashboard y elegí el proyecto
--   2. En el menú de la izquierda: SQL Editor
--   3. New query, pegá este archivo completo, Run
--
-- Se puede correr más de una vez sin romper nada (todo es "if not exists" /
-- "on conflict do nothing"). No hace falta ninguna clave secreta: el SQL
-- Editor ya corre con permisos de administrador.
--
-- IMPORTANTE — seguridad
--   Todas las tablas quedan con RLS activo y SIN políticas de acceso, o sea
--   que la clave pública del sitio (anon / publishable) NO puede leer ni
--   escribir nada directamente. Lo único que el sitio puede llamar es la
--   función validar_codigo() del final, que devuelve solo los datos del
--   miembro de ese código y nunca teléfonos ni mails.
--   El panel de Supabase y la clave service_role no pasan por RLS, así que
--   vos seguís viendo y editando todo con normalidad.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- miembros
-- ----------------------------------------------------------------------------
-- codigo_acceso: lo que se escribe en el portal. Se guarda siempre en
--   mayúsculas para que no puedan existir 'mau' y 'MAU' como dos miembros.
-- codigo_sektario: el código que el miembro comparte (SK·MAU·ØØØ·GDE). Hoy en
--   el sitio es fijo y uno por persona, por eso vive acá y no en invitaciones.
-- es_fundador: "semilla cero". Son exactamente tres: MAU, NAYA y FLOR, que
--   comparten el número de miembro ØØØ y se distinguen por las iniciales.
--   Es un campo propio y NO se deduce de invitado_por: LUCHI y MAIA tienen el
--   invitador vacío por falta de dato, no por ser fundadoras.
create table if not exists public.miembros (
  id               uuid primary key default gen_random_uuid(),
  codigo_acceso    text not null unique
                     check (codigo_acceso = upper(codigo_acceso)),
  nombre_sektario  text not null,
  codigo_sektario  text unique,
  nombre_real      text,
  telefono         text,
  email            text,
  invitado_por     uuid references public.miembros(id) on delete set null,
  es_fundador      boolean not null default false,
  fecha_ingreso    timestamptz not null default now(),
  estado_codigo    text not null default 'activo'
                     check (estado_codigo in ('activo', 'suspendido', 'revocado')),
  creado_en        timestamptz not null default now()
);

comment on column public.miembros.codigo_acceso   is 'Lo que se escribe en el portal. Siempre en mayúsculas.';
comment on column public.miembros.codigo_sektario is 'El código que la persona comparte para invitar (SK·XXX·GDE).';
comment on column public.miembros.es_fundador     is 'Semilla cero: no fue invitada por nadie.';

create index if not exists miembros_invitado_por_idx on public.miembros (invitado_por);


-- ----------------------------------------------------------------------------
-- fiestas
-- ----------------------------------------------------------------------------
create table if not exists public.fiestas (
  id         uuid primary key default gen_random_uuid(),
  nombre     text not null,
  fecha      timestamptz not null,
  creado_en  timestamptz not null default now()
);

create index if not exists fiestas_fecha_idx on public.fiestas (fecha desc);


-- ----------------------------------------------------------------------------
-- asistencias
-- ----------------------------------------------------------------------------
-- Una sola fila por miembro y fiesta (por eso el unique).
create table if not exists public.asistencias (
  id          uuid primary key default gen_random_uuid(),
  miembro_id  uuid not null references public.miembros(id) on delete cascade,
  fiesta_id   uuid not null references public.fiestas(id)  on delete cascade,
  estado      text not null default 'pendiente'
                check (estado in ('pendiente', 'confirmada')),
  creado_en   timestamptz not null default now(),
  unique (miembro_id, fiesta_id)
);

create index if not exists asistencias_fiesta_idx  on public.asistencias (fiesta_id);
create index if not exists asistencias_miembro_idx on public.asistencias (miembro_id);


-- ----------------------------------------------------------------------------
-- validaciones
-- ----------------------------------------------------------------------------
-- Registro de cada vez que se valida una asistencia (en la puerta, por
-- ejemplo). A propósito NO es única por asistencia: queda como historial, así
-- se puede ver si alguien la validó dos veces. Si preferís que solo se pueda
-- validar una vez, agregá: unique (asistencia_id)
create table if not exists public.validaciones (
  id             uuid primary key default gen_random_uuid(),
  asistencia_id  uuid not null references public.asistencias(id) on delete cascade,
  validado_por   uuid references public.miembros(id) on delete set null,
  validado_en    timestamptz not null default now()
);

create index if not exists validaciones_asistencia_idx on public.validaciones (asistencia_id);


-- ----------------------------------------------------------------------------
-- invitaciones
-- ----------------------------------------------------------------------------
-- Códigos de un solo uso generados por un miembro, con vencimiento.
-- usada_por / usada_en no estaban en tu lista pero sin eso no se puede
-- reconstruir el linaje (quién entró con qué invitación).
create table if not exists public.invitaciones (
  id            uuid primary key default gen_random_uuid(),
  generada_por  uuid not null references public.miembros(id) on delete cascade,
  codigo        text not null unique,
  vence_en      timestamptz,
  usada         boolean not null default false,
  usada_por     uuid references public.miembros(id) on delete set null,
  usada_en      timestamptz,
  creado_en     timestamptz not null default now()
);

create index if not exists invitaciones_generada_por_idx on public.invitaciones (generada_por);


-- ----------------------------------------------------------------------------
-- entradas
-- ----------------------------------------------------------------------------
-- comprobante: guardá acá la URL del archivo (Supabase Storage), no el archivo.
create table if not exists public.entradas (
  id             uuid primary key default gen_random_uuid(),
  miembro_id     uuid not null references public.miembros(id) on delete cascade,
  fiesta_id      uuid not null references public.fiestas(id)  on delete cascade,
  cantidad       integer not null default 1 check (cantidad > 0),
  monto          numeric(12,2) check (monto >= 0),
  estado_pago    text not null default 'pendiente'
                   check (estado_pago in ('pendiente', 'pagado', 'cancelado')),
  comprobante    text,
  link_passline  text,
  creado_en      timestamptz not null default now()
);

create index if not exists entradas_miembro_idx on public.entradas (miembro_id);
create index if not exists entradas_fiesta_idx  on public.entradas (fiesta_id);


-- ============================================================================
-- SEGURIDAD: RLS activo y sin políticas = nada accesible con la clave pública
-- ============================================================================
alter table public.miembros     enable row level security;
alter table public.fiestas      enable row level security;
alter table public.asistencias  enable row level security;
alter table public.validaciones enable row level security;
alter table public.invitaciones enable row level security;
alter table public.entradas     enable row level security;


-- ============================================================================
-- validar_codigo(): lo único que el sitio puede llamar
-- ============================================================================
-- Devuelve una fila si el código existe y está activo, y ninguna si no.
-- Nunca devuelve teléfono, mail ni el id interno: si esta función se filtra,
-- lo máximo que se puede averiguar es el nombre sektario de un código que ya
-- se conocía.
create or replace function public.validar_codigo(p_codigo text)
returns table (
  nombre_sektario      text,
  codigo_sektario      text,
  fecha_ingreso        timestamptz,
  es_fundador          boolean,
  invitado_por_nombre  text
)
language sql
security definer
set search_path = public
as $$
  select
    m.nombre_sektario,
    m.codigo_sektario,
    m.fecha_ingreso,
    m.es_fundador,
    quien.nombre_sektario as invitado_por_nombre
  from public.miembros m
  left join public.miembros quien on quien.id = m.invitado_por
  where m.codigo_acceso = upper(btrim(p_codigo))
    and m.estado_codigo = 'activo'
  limit 1;
$$;

revoke all on function public.validar_codigo(text) from public;
grant execute on function public.validar_codigo(text) to anon, authenticated;


-- ============================================================================
-- Los miembros que ya existen en el sitio
-- ============================================================================
-- Los tres fundadores (MAU, NAYA, FLOR) comparten el número ØØØ, como ya lo
-- reflejaban sus códigos sektarios.
insert into public.miembros
  (codigo_acceso, nombre_sektario, codigo_sektario, es_fundador)
values
  ('MAU',   'mau',   'SK·MAU·ØØØ·GDE', true),
  ('NAYA',  'naya',  'SK·NYA·ØØØ·GDE', true),
  ('FLOR',  'flor',  'SK·FLR·ØØØ·GDE', true),
  ('LUCHI', 'luchi', 'SK·LUP·XXV·GDE', false),
  ('MAIA',  'maia',  'SK·MAI·XVI·GDE', false)
on conflict (codigo_acceso) do nothing;

-- AURINAYA era un código de prueba: fuera.
delete from public.miembros where codigo_acceso = 'AURINAYA';


-- ============================================================================
-- Verificación (opcional): corré estas tres líneas después, una por una
-- ============================================================================
-- select * from public.validar_codigo('mau');       -- 1 fila, es_fundador = true
-- select * from public.validar_codigo('NOEXISTE');  -- 0 filas
-- select count(*) from public.miembros;             -- 5
