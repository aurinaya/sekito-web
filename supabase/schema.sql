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
-- ORDEN DE APLICACIÓN
--   Este archivo crea la estructura base. Después hay que correr
--   migracion-bienvenida.sql, que agrega las columnas y las funciones del
--   formulario de bienvenida. Las funciones nuevas viven solo en ese archivo
--   para no tener dos copias que se desincronicen.
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
-- codigo_sektario: EN DESUSO. Era el código que el miembro compartía, con el
--   envoltorio SK·…·GDE. Se unificó en nombre_sektario, que ahora es el único
--   identificador público. La columna sigue existiendo hasta que se confirme
--   que nada la usa; después se borra.
-- pantalla: qué perfil propio le toca en el sitio (mau, naya, flor...). Separa
--   la identidad visual del código de acceso, así se puede cambiar un código o
--   un número de miembro sin romper ningún perfil. Vacío = vista genérica.
-- es_fundador: "semilla cero". Son exactamente tres: MAU, NAYA y FLOR, que
--   comparten el número de miembro ØØØ y se distinguen por las iniciales.
--   Es un campo propio y NO se deduce de invitado_por: LUCHI y MAIA tienen el
--   invitador vacío por falta de dato, no por ser fundadoras.
create table if not exists public.miembros (
  id               uuid primary key default gen_random_uuid(),
  codigo_acceso    text not null unique
                     check (codigo_acceso = upper(codigo_acceso)),
  nombre_sektario  text,                  -- se genera al registrarse, ver migracion-bienvenida.sql
  codigo_sektario  text unique,
  nombre_real      text,
  apellido         text,
  telefono         text,
  email            text,
  como_llegaste    text,
  pantalla         text,
  invitado_por     uuid references public.miembros(id) on delete set null,
  es_fundador      boolean not null default false,
  fecha_ingreso    timestamptz not null default now(),
  estado_codigo    text not null default 'activo'
                     check (estado_codigo in ('activo', 'suspendido', 'revocado', 'simbolico')),
  creado_en        timestamptz not null default now()
);

comment on column public.miembros.codigo_acceso   is 'Lo que se escribe en el portal. Siempre en mayúsculas.';
comment on column public.miembros.codigo_sektario is 'EN DESUSO: se unificó en nombre_sektario.';
comment on column public.miembros.pantalla        is 'Pantalla propia en el sitio. Vacío = vista genérica.';
comment on column public.miembros.es_fundador     is 'Semilla cero: no fue invitada por nadie.';

create index if not exists miembros_invitado_por_idx on public.miembros (invitado_por);

-- el nombre sektario identifica públicamente a cada miembro: tiene que ser único.
-- es la garantía real contra colisiones al sortear números de miembro, porque
-- aguanta dos altas simultáneas (un "fijate si existe y después insertá" no).
create unique index if not exists miembros_nombre_sektario_key
  on public.miembros (nombre_sektario);


-- ----------------------------------------------------------------------------
-- fiestas
-- ----------------------------------------------------------------------------
create table if not exists public.fiestas (
  id         uuid primary key default gen_random_uuid(),
  nombre     text not null,
  fecha      timestamptz not null,
  lugar      text,
  creado_en  timestamptz not null default now()
);

create unique index if not exists fiestas_nombre_key on public.fiestas (nombre);

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
  pantalla             text,
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
    m.pantalla,
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
-- Los miembros NO se cargan desde acá
-- ============================================================================
-- Este repo es público. Los códigos de acceso son privados, así que no se
-- versionan: se cargan aparte, con un script que no entra al repositorio.
-- Lo que queda acá es la estructura; los datos reales viven solo en la base.
--
-- La forma es esta (valores de ejemplo, no son códigos reales):
--
--   insert into public.miembros
--     (codigo_acceso, nombre_sektario, pantalla, es_fundador)
--   values
--     ('XXX000', 'CNS·000', 'unapantalla', true)
--   on conflict (codigo_acceso) do nothing;
--
-- codigo_acceso:   privado, 3 letras + 3 números al azar, sin relación con el
--                  nombre. Se sortea con un generador criptográfico, y el
--                  alfabeto excluye I y O porque se confunden con 1 y 0.
-- nombre_sektario: público, consonantes del nombre real + número de miembro.
--                  El número se sortea entre 001 y 999; el 000 está reservado
--                  a los fundadores, así nadie que entre después lo aparenta.


-- ============================================================================
-- Verificación (opcional): corré estas tres líneas después, una por una
-- ============================================================================
-- select * from public.validar_codigo('CODIGO');    -- 1 fila si el código existe
-- select * from public.validar_codigo('NOEXISTE');  -- 0 filas
-- select codigo_acceso, nombre_sektario, pantalla from public.miembros;
